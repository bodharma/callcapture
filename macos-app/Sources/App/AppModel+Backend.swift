import AppKit
import Foundation
import os

/// The web API's view of `AppModel`.
///
/// Database reads go straight to GRDB (thread-safe) and file reads use the
/// shared defaults in `AppBackend`. Recording state, settings, the live
/// meeting, the observed session list and AppKit calls hop to the main actor.
/// The guards are the pure policies in `SessionGuards.swift` over `AppModel.activity`;
/// the test fake applies the same functions.
@available(macOS 14.2, *)
final class AppModelBackend: AppBackend {
    private struct Reference { weak var model: AppModel? }
    private let reference = OSAllocatedUnfairLock(uncheckedState: Reference())

    /// Called once from `AppModel.init`; the backend never keeps the model alive.
    func attach(_ model: AppModel) {
        reference.withLockUnchecked { $0.model = model }
    }

    /// Model downloads started from the web UI (see `AppModelBackend+Settings`).
    let modelDownloads = ModelDownloads()

    /// Server-sent events for every open page (see `AppModel+Events`).
    let events = EventHub()

    var model: AppModel? { reference.withLockUnchecked { $0.model } }

    func requireModel() throws -> AppModel {
        guard let model else { throw BackendError.unavailable }
        return model
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func sessions() async -> [Session] {
        model?.sessionManager.allSessions() ?? []
    }

    func session(id: String) async -> Session? {
        model?.sessionManager.session(id: id)
    }

    /// Checks and deletes in one main-actor step (`DeletePolicy`).
    func delete(id: String) async throws {
        guard let model else { throw BackendError.notFound }
        try await MainActor.run {
            guard let session = model.sessionManager.session(id: id) else { throw BackendError.notFound }
            if let problem = DeletePolicy.problem(for: session, activity: model.activity) {
                throw BackendError.busy(problem)
            }
            model.sessionManager.deleteSession(id: id)
        }
    }

    /// Checks (`ReprocessPolicy`) and starts in one main-actor step: `startTranscription`
    /// marks the app busy before returning, so a second request (API or menu) is refused.
    func reprocess(id: String) async throws {
        guard let model else { throw BackendError.notFound }
        try await MainActor.run {
            guard let session = model.sessionManager.session(id: id) else { throw BackendError.notFound }
            if let problem = ReprocessPolicy.problem(for: session, activity: model.activity) {
                throw BackendError.busy(problem)
            }
            model.startTranscription(session)
        }
    }

    /// Checks (`RegenerateNotesPolicy`) and starts in one main-actor step, like `reprocess`.
    func regenerateNotes(id: String) async throws {
        guard let model else { throw BackendError.notFound }
        try await MainActor.run {
            guard let session = model.sessionManager.session(id: id) else { throw BackendError.notFound }
            if let problem = RegenerateNotesPolicy.problem(for: session, activity: model.activity) {
                throw BackendError.refused(code: problem.code, message: problem.message)
            }
            model.startRegeneratingNotes(session)
        }
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
        return try SessionExport.saveNote(
            markdownPath: markdownPath, names: SessionFiles.speakerNames(of: session), directory: directory,
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
            SystemStatus(online: model.connectivity.isOnline, version: Self.version, recordingStatus: model.recordingStatus)
        }
    }

    func updateDetails(id: String, _ change: SessionDetailsChange) async throws {
        guard let model else { throw BackendError.notFound }
        try await MainActor.run {
            let sessions = model.sessionManager
            guard sessions.session(id: id) != nil else { throw BackendError.notFound }
            // Each writer reports `sessionChanged` through `onSessionChange`.
            if let value = change.recordingType { sessions.updateRecordingType(id: id, recordingType: value) }
            if let value = change.language { sessions.updateLanguage(id: id, language: value) }
            if let value = change.notesLanguage { sessions.updateNotesLanguage(id: id, language: value) }
        }
    }

    /// The path comes from the session record only.
    func openNote(id: String) async throws {
        let path = try await requireSession(id).transcriptMarkdownPath
        guard SessionFiles.exists(path), let path else { throw BackendError.notFound }
        await MainActor.run {
            _ = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    func activity() async -> AppActivity {
        guard let model else { return AppActivity() }
        return await MainActor.run { model.activity }
    }
}

@available(macOS 14.2, *)
extension AppModel {
    /// What the session guards decide from, read in one main-actor step.
    @MainActor var activity: AppActivity {
        AppActivity(
            state: state, transition: recordingTransition, playbackBlocked: playbackBlocked,
            isOnline: connectivity.isOnline, recordingSessionID: sessionManager.currentSession?.id,
            defaultEngine: settingsManager.defaultEngine.rawValue, processingProgress: pythonBridge.progress,
            notesProvider: settingsManager.llmProvider, processingStage: processingStage)
    }
}
