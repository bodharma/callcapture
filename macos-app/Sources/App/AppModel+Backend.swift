import AppKit
import Foundation
import os

/// The web API's view of `AppModel`.
///
/// Database reads go straight to GRDB (thread-safe) and file reads use the
/// shared defaults in `AppBackend`. Recording state, settings, the live
/// meeting, the observed session list and AppKit calls hop to the main actor.
/// The guards mirror what the SwiftUI detail view disables, because the API
/// has to enforce them itself.
@available(macOS 14.2, *)
final class AppModelBackend: AppBackend {
    private struct Reference { weak var model: AppModel? }
    private let reference = OSAllocatedUnfairLock(uncheckedState: Reference())
    /// One re-process at a time from the API: `transcribeSession` awaits before it
    /// marks the app busy, so the state check alone could let two through.
    private let reprocessing = OSAllocatedUnfairLock(initialState: false)

    static let processableStatuses: Set<String> = ["completed", "transcribed", "error", "failed", "interrupted"]

    /// Called once from `AppModel.init`; the backend never keeps the model alive.
    func attach(_ model: AppModel) {
        reference.withLockUnchecked { $0.model = model }
    }

    private var model: AppModel? { reference.withLockUnchecked { $0.model } }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func sessions() async -> [Session] {
        model?.sessionManager.allSessions() ?? []
    }

    func session(id: String) async -> Session? {
        model?.sessionManager.session(id: id)
    }

    func delete(id: String) async throws {
        guard let model else { throw BackendError.notFound }
        try await MainActor.run {
            guard let session = model.sessionManager.session(id: id) else { throw BackendError.notFound }
            guard session.status != "recording", model.state != .transcribing else {
                throw BackendError.busy("Wait until recording and processing finish before deleting.")
            }
            model.sessionManager.deleteSession(id: id)
        }
    }

    func reprocess(id: String) async -> String? {
        guard let model else { return "CallCapture is not ready yet." }
        guard reprocessing.withLock({ busy in defer { busy = true }; return !busy }) else {
            return "Another session is being processed."
        }
        defer { reprocessing.withLock { $0 = false } }
        // Unstructured on purpose: a dropped HTTP connection must not cancel processing.
        return await Task { @MainActor in
            guard let session = model.sessionManager.session(id: id) else { return "This session no longer exists." }
            if let problem = Self.reprocessProblem(session, model: model) { return problem }
            await model.transcribeSession(session)
            return model.state == .error ? (model.lastError ?? "Processing failed.") : nil
        }.value
    }

    @MainActor
    private static func reprocessProblem(_ session: Session, model: AppModel) -> String? {
        guard processableStatuses.contains(session.status) else {
            return "This session can't be processed while it is \(session.status)."
        }
        guard model.state != .transcribing, model.state != .recording, !model.playbackBlocked else {
            return "Wait until the current recording or processing finishes."
        }
        let engine = JobRequest.transcribe(session: session, settings: model.settingsManager).engine
        if let reason = NetworkPolicy.blockReason(engine: engine, isOnline: model.connectivity.isOnline) {
            return "\(reason) This session uses cloud transcription."
        }
        return nil
    }

    func saveToVault(id: String) async throws -> URL {
        guard let model else { throw BackendError.notFound }
        let session = try await requireSession(id)
        guard let markdownPath = session.transcriptMarkdownPath, SessionFiles.exists(markdownPath)
        else { throw BackendError.nothingToSave }
        let directory = await MainActor.run {
            let settings = model.settingsManager
            return SessionExport.vaultDirectory(
                startedAt: session.startedAt, vault: settings.obsidianExportDirectory,
                folderPattern: settings.obsidianFolderPattern, outputDirectory: settings.outputDirectory)
        }
        let names = try SpeakerNames.load(audioPath: session.audioPath)
        return try SessionExport.saveNote(
            markdownPath: markdownPath, names: names, directory: directory,
            title: session.title, sessionID: session.id)
    }

    /// While the session is still recording, the in-memory live map is newer than its file.
    func liveDocument(id: String) async throws -> ConversationDocument? {
        let session = try await requireSession(id)
        if let model {
            let active = await MainActor.run { () -> ConversationDocument? in
                let document = model.liveMeeting.model.document
                return document.sessionID == id ? document : nil
            }
            if let active { return active }
        }
        return try SavedLiveMap.load(audioPath: session.audioPath)
    }

    func revealInFinder(id: String) async throws {
        let path = try await requireSession(id).audioPath
        await MainActor.run {
            _ = NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }

    func systemStatus() async -> SystemStatus {
        guard let model else { return SystemStatus(online: false, recording: false, version: Self.version) }
        return await MainActor.run {
            SystemStatus(
                online: model.connectivity.isOnline,
                recording: model.state == .recording || model.playbackBlocked,
                version: Self.version)
        }
    }
}
