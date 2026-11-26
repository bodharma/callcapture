import Foundation

@testable import CallCapture

/// The settings side of `FakeBackend`. Settings go through a real `SettingsManager`
/// over a throwaway database and `InMemoryCredentialStore`, so the API tests exercise
/// the production DTO and apply code and never touch the user's Keychain. Only
/// app-level effects (catalog refresh, folder panel, key test, downloads) are faked.
final class FakeSettings: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let manager: SettingsManager
    private let store: InMemoryCredentialStore
    private var catalogState = CatalogState(snapshot: nil, problem: nil, refreshing: false)
    private var nextRefresh: CatalogState?
    private var refreshes: [Bool] = []
    private var pickAnswer: Result<String?, BackendError> = .success(nil)
    private var picks: [FolderSetting] = []
    private var keyTest = KeyTestResult(ok: true, message: "The key works.")
    private var keyTests = 0
    private var downloadStarts: [ModelDownloadKind] = []
    let downloads = ModelDownloads()

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cc-settings-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try! AppDatabase(path: directory.appendingPathComponent("settings.db").path)
        store = InMemoryCredentialStore()
        manager = SettingsManager(database: database, credentialStore: store)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    // MARK: Test controls

    /// Reads or changes the manager directly, as the SwiftUI window would.
    func withManager<T>(_ body: (SettingsManager) throws -> T) rethrows -> T { try lock.withLock { try body(manager) } }
    /// What the credential store holds (the stand-in for the Keychain).
    var storedSecrets: [String: String] { lock.withLock { store.values } }
    func setCatalog(_ state: CatalogState) { lock.withLock { catalogState = state } }
    /// What the next refresh leaves behind (default: the catalog unchanged).
    func refreshWillProduce(_ state: CatalogState) { lock.withLock { nextRefresh = state } }
    var refreshCalls: [Bool] { lock.withLock { refreshes } }
    func pickWillReturn(_ answer: Result<String?, BackendError>) { lock.withLock { pickAnswer = answer } }
    var pickRequests: [FolderSetting] { lock.withLock { picks } }
    func keyTestWillReturn(_ result: KeyTestResult) { lock.withLock { keyTest = result } }
    var keyTestCalls: Int { lock.withLock { keyTests } }
    var downloadRequests: [ModelDownloadKind] { lock.withLock { downloadStarts } }

    // MARK: Backend side

    func snapshot(isOnline: Bool) -> SettingsDTO {
        lock.withLock { dto(isOnline: isOnline) }
    }

    func update(_ patch: SettingsPatch, isOnline: Bool) -> SettingsDTO {
        lock.withLock {
            manager.apply(patch)
            return dto(isOnline: isOnline)
        }
    }

    func resetCosts(isOnline: Bool) -> SettingsDTO {
        lock.withLock {
            manager.resetPricingToDefaults()
            return dto(isOnline: isOnline)
        }
    }

    func setSecret(_ key: SecretKey, value: String) { lock.withLock { manager.setSecret(key, to: value) } }

    func testKey() -> KeyTestResult {
        lock.withLock {
            keyTests += 1
            return manager.hasSecret(.openrouter) ? keyTest : .missingKey
        }
    }

    func catalog() -> CatalogState { lock.withLock { catalogState } }

    func refresh(force: Bool) {
        lock.withLock {
            refreshes.append(force)
            if let nextRefresh { catalogState = nextRefresh }
        }
    }

    func pick(_ setting: FolderSetting) throws -> String? {
        try lock.withLock {
            picks.append(setting)
            return try pickAnswer.get()
        }
    }

    func startDownload(_ kind: ModelDownloadKind) throws {
        try lock.withLock {
            let ready = kind == .diarization ? manager.diarizationModelsReady : manager.emotionModelsReady
            guard !ready else { throw BackendError.busy("Already downloaded.") }
            try downloads.begin(kind)
            downloadStarts.append(kind)
        }
    }

    /// Call with the lock held.
    private func dto(isOnline: Bool) -> SettingsDTO {
        SettingsDTO(
            settings: manager, catalog: catalogState.snapshot, isOnline: isOnline, downloads: downloads.statuses())
    }
}
