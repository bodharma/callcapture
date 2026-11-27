import Foundation

@testable import CallCapture

/// In-memory app side for API tests. Only app-level effects are faked (the
/// session list, delete/reprocess/regenerate/vault/reveal, system status); transcripts,
/// names, notes, analysis and live maps go through the shared production
/// defaults over files the test writes into a temp directory. Refusals and
/// progress come from the production guards (`DeletePolicy`, `ReprocessPolicy`,
/// `RegenerateNotesPolicy`, `ProcessingProgress`) over the fake's `AppActivity` (`setActivity`).
final class FakeBackend: AppBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [Session] = []
    private var deleted: [String] = []
    private var revealed: [String] = []
    private var reprocessed: [String] = []
    private var regenerated: [String] = []
    private var reprocessOutcome: (status: String, error: String?) = ("transcribed", nil)
    private var reprocessGate: AsyncStream<Void>.Continuation?
    private var reprocessRun: Task<Void, Never>?
    private var opened: [String] = []
    private var playbackBlocked = false
    private var recordingSessionID: String?
    private var processingProgress: Double = 0
    private var processingStage: String?
    private var notesProvider = LLMProvider.openrouter
    private var vaultDirectory: URL?
    private var status = SystemStatus(online: true, recording: false, version: "test")
    private var defaultEngine = "local_whisper"
    private var settingsSide: FakeSettings?
    /// The hub the API routes publish to; tests subscribe to it directly.
    let events = EventHub()
    /// Recording control and the live map (see `FakeLive`).
    let live = FakeLive()

    init(sessions: [Session] = []) {
        store = sessions
    }

    // MARK: Test controls

    func add(_ session: Session) { lock.withLock { store.append(session) } }
    var deletedIDs: [String] { lock.withLock { deleted } }
    var revealedIDs: [String] { lock.withLock { revealed } }
    var reprocessedIDs: [String] { lock.withLock { reprocessed } }
    var regeneratedIDs: [String] { lock.withLock { regenerated } }
    var openedNoteIDs: [String] { lock.withLock { opened } }
    /// What the app is doing, for the guards; the state and transition also drive `FakeLive`.
    func setActivity(
        state: AppState, transition: RecordingTransition? = nil, playbackBlocked: Bool = false,
        recordingSessionID: String? = nil, progress: Double = 0, stage: String? = nil
    ) {
        live.setRecording(state: state, transition: transition)
        lock.withLock {
            self.playbackBlocked = playbackBlocked
            self.recordingSessionID = recordingSessionID
            processingProgress = progress
            processingStage = stage
        }
    }
    /// Where the final notes are made (Settings → AI notes); a cloud provider needs the network.
    func setNotesProvider(_ provider: LLMProvider) { lock.withLock { notesProvider = provider } }
    /// What a released run (re-process or regenerate) writes into the session record.
    func finishReprocess(status: String, error: String?) { lock.withLock { reprocessOutcome = (status, error) } }

    /// Lets the background run (re-process or regenerate) finish and waits until it has
    /// updated the session.
    func releaseReprocess() async {
        let (gate, run) = lock.withLock { (reprocessGate, reprocessRun) }
        gate?.yield()
        gate?.finish()
        await run?.value
    }
    func saveVault(into directory: URL?) { lock.withLock { vaultDirectory = directory } }
    func setStatus(_ value: SystemStatus) { lock.withLock { status = value } }
    /// The engine a session without `engineUsed` would be processed with.
    func setDefaultEngine(_ engine: String) { lock.withLock { defaultEngine = engine } }
    func setOnline(_ online: Bool) {
        lock.withLock { status = SystemStatus(online: online, recording: status.recording, version: status.version) }
    }
    /// Created on first use, so tests that never touch settings never open a database.
    var settings: FakeSettings {
        lock.withLock {
            if let settingsSide { return settingsSide }
            let created = FakeSettings()
            settingsSide = created
            return created
        }
    }

    // MARK: AppBackend

    func sessions() async -> [Session] {
        lock.withLock { store.sorted { $0.startedAt > $1.startedAt } }
    }

    func session(id: String) async -> Session? {
        lock.withLock { store.first { $0.id == id } }
    }

    func delete(id: String) async throws {
        let session = try await requireSession(id)
        if let problem = DeletePolicy.problem(for: session, activity: await activity()) {
            throw BackendError.busy(problem)
        }
        lock.withLock {
            deleted.append(id)
            store.removeAll { $0.id == id }
        }
    }

    /// Like production: marks the session as processing and returns at once; the run
    /// itself waits for `releaseReprocess()`, then records the configured outcome.
    func reprocess(id: String) async throws {
        let session = try await requireSession(id)
        if let problem = ReprocessPolicy.problem(for: session, activity: await activity()) {
            throw BackendError.busy(problem)
        }
        lock.withLock {
            reprocessed.append(id)
            startRun(id)
        }
    }

    /// Like production: checked by the same policy, then the same background run as `reprocess`.
    func regenerateNotes(id: String) async throws {
        let session = try await requireSession(id)
        if let problem = RegenerateNotesPolicy.problem(for: session, activity: await activity()) {
            throw BackendError.refused(code: problem.code, message: problem.message)
        }
        lock.withLock {
            regenerated.append(id)
            startRun(id)
        }
    }

    /// Call with the lock held.
    private func startRun(_ id: String) {
        let (released, gate) = AsyncStream<Void>.makeStream()
        updateSession(id) { $0.status = "transcribing"; $0.errorMessage = nil }
        reprocessGate = gate
        reprocessRun = Task { [weak self] in
            for await _ in released { break }
            self?.completeReprocess(id)
        }
    }

    private func completeReprocess(_ id: String) {
        lock.withLock {
            let outcome = reprocessOutcome
            updateSession(id) { $0.status = outcome.status; $0.errorMessage = outcome.error }
        }
    }

    /// Call with the lock held.
    private func updateSession(_ id: String, _ change: (inout Session) -> Void) {
        guard let index = store.firstIndex(where: { $0.id == id }) else { return }
        change(&store[index])
    }

    func saveToVault(id: String) async throws -> URL {
        let session = try await requireSession(id)
        guard let directory = lock.withLock({ vaultDirectory }),
            let markdownPath = session.transcriptMarkdownPath,
            FileManager.default.fileExists(atPath: markdownPath)
        else { throw BackendError.nothingToSave }
        return try SessionExport.saveNote(
            markdownPath: markdownPath, names: SessionFiles.speakerNames(of: session),
            directory: directory, title: session.title, sessionID: session.id)
    }

    func revealInFinder(id: String) async throws {
        _ = try await requireSession(id)
        lock.withLock { revealed.append(id) }
    }

    func systemStatus() async -> SystemStatus { lock.withLock { status } }

    func updateDetails(id: String, _ change: SessionDetailsChange) async throws {
        _ = try await requireSession(id)
        lock.withLock {
            updateSession(id) {
                if let value = change.recordingType { $0.recordingType = value }
                if let value = change.language { $0.language = value }
                if let value = change.notesLanguage { $0.notesLanguage = value }
            }
        }
    }

    func openNote(id: String) async throws {
        _ = try await requireSession(id)
        lock.withLock { opened.append(id) }
    }

    func activity() async -> AppActivity {
        let recording = live.recording
        return lock.withLock {
            AppActivity(
                state: recording.state, transition: recording.transition, playbackBlocked: playbackBlocked,
                isOnline: status.online, recordingSessionID: recordingSessionID, defaultEngine: defaultEngine,
                processingProgress: processingProgress, notesProvider: notesProvider,
                processingStage: processingStage)
        }
    }

    // MARK: SettingsBackend

    func settingsSnapshot() async throws -> SettingsDTO { settings.snapshot(isOnline: await isOnline()) }

    func updateSettings(_ patch: SettingsPatch) async throws -> SettingsDTO {
        settings.update(patch, isOnline: await isOnline())
    }

    func resetCosts() async throws -> SettingsDTO { settings.resetCosts(isOnline: await isOnline()) }
    func setSecret(_ key: SecretKey, value: String) async throws { settings.setSecret(key, value: value) }
    func testOpenRouterKey() async throws -> KeyTestResult { settings.testKey() }
    func catalog() async -> CatalogState { settings.catalog() }
    func refreshCatalog(force: Bool) async { settings.refresh(force: force) }
    func pickFolder(for setting: FolderSetting) async throws -> String? { try settings.pick(setting) }
    func startModelDownload(_ kind: ModelDownloadKind) async throws { try settings.startDownload(kind) }
}
