import Foundation

@testable import CallCapture

/// In-memory app side for API tests. Only app-level effects are faked (the
/// session list, delete/reprocess/vault/reveal, system status); transcripts,
/// names, notes, analysis and live maps go through the shared production
/// defaults over files the test writes into a temp directory.
final class FakeBackend: AppBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [Session] = []
    private var deleted: [String] = []
    private var revealed: [String] = []
    private var reprocessed: [String] = []
    private var reprocessResult: String?
    private var deleteFailure: BackendError?
    private var vaultDirectory: URL?
    private var status = SystemStatus(online: true, recording: false, version: "test")

    init(sessions: [Session] = []) {
        store = sessions
    }

    // MARK: Test controls

    func add(_ session: Session) { lock.withLock { store.append(session) } }
    var deletedIDs: [String] { lock.withLock { deleted } }
    var revealedIDs: [String] { lock.withLock { revealed } }
    var reprocessedIDs: [String] { lock.withLock { reprocessed } }
    func failReprocess(with message: String?) { lock.withLock { reprocessResult = message } }
    func failDelete(with error: BackendError?) { lock.withLock { deleteFailure = error } }
    func saveVault(into directory: URL?) { lock.withLock { vaultDirectory = directory } }
    func setStatus(_ value: SystemStatus) { lock.withLock { status = value } }

    // MARK: AppBackend

    func sessions() async -> [Session] {
        lock.withLock { store.sorted { $0.startedAt > $1.startedAt } }
    }

    func session(id: String) async -> Session? {
        lock.withLock { store.first { $0.id == id } }
    }

    func delete(id: String) async throws {
        _ = try await requireSession(id)
        try lock.withLock {
            if let deleteFailure { throw deleteFailure }
            deleted.append(id)
            store.removeAll { $0.id == id }
        }
    }

    func reprocess(id: String) async -> String? {
        lock.withLock {
            reprocessed.append(id)
            return reprocessResult
        }
    }

    func saveToVault(id: String) async throws -> URL {
        let session = try await requireSession(id)
        guard let directory = lock.withLock({ vaultDirectory }),
            let markdownPath = session.transcriptMarkdownPath,
            FileManager.default.fileExists(atPath: markdownPath)
        else { throw BackendError.nothingToSave }
        return try SessionExport.saveNote(
            markdownPath: markdownPath, names: try SpeakerNames.load(audioPath: session.audioPath),
            directory: directory, title: session.title, sessionID: session.id)
    }

    func revealInFinder(id: String) async throws {
        _ = try await requireSession(id)
        lock.withLock { revealed.append(id) }
    }

    func systemStatus() async -> SystemStatus { lock.withLock { status } }
}
