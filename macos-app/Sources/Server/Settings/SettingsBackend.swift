import Foundation

/// What the local web UI may ask of the app's settings. Validation happens in the
/// HTTP layer (`SettingsValidation`) before anything reaches these requirements,
/// so `updateSettings` only ever sees a fully checked patch.
protocol SettingsBackend: Sendable {
    /// Every user-editable setting; secrets only as set / not set.
    func settingsSnapshot() async throws -> SettingsDTO
    /// Applies a validated patch and returns the settings as they now are.
    func updateSettings(_ patch: SettingsPatch) async throws -> SettingsDTO
    /// The pricing defaults the SwiftUI "Reset to defaults" button restores.
    func resetCosts() async throws -> SettingsDTO
    /// A non-empty value replaces the secret; an empty one removes it, as clearing
    /// the SwiftUI key field does.
    func setSecret(_ key: SecretKey, value: String) async throws
    /// Calls OpenRouter with the stored key; never returns the key or its label.
    func testOpenRouterKey() async throws -> KeyTestResult
    func catalog() async -> CatalogState
    /// Refreshes the OpenRouter catalog (at most daily unless forced). A failure keeps
    /// the cached snapshot and is reported as `CatalogState.problem`.
    func refreshCatalog(force: Bool) async
    /// Shows a folder chooser; nil when cancelled. Throws `.busy` while one is already open.
    func pickFolder(for setting: FolderSetting) async throws -> String?
    /// Starts a model download in the background; `settingsSnapshot` reports progress.
    /// Throws `.busy` when it is already running or the models are already there.
    func startModelDownload(_ kind: ModelDownloadKind) async throws
}

/// The secrets the SwiftUI settings have a field for. Each maps to one Keychain account.
enum SecretKey: String, CaseIterable, Sendable {
    case openrouter
    case assemblyai
    case deepgram
    /// The Groq / OpenAI Whisper key (`remote_api_key`).
    case remote
}

/// Settings that hold a folder and can be chosen with `NSOpenPanel`.
enum FolderSetting: String, CaseIterable, Sendable {
    case outputDirectory
    case obsidianVault

    var panelMessage: String {
        switch self {
        case .outputDirectory: "Choose where CallCapture saves recordings."
        case .obsidianVault: "Choose your Obsidian vault."
        }
    }
}

enum ModelDownloadKind: String, CaseIterable, Sendable {
    case diarization
    case emotion
}

struct ModelDownloadStatus: Equatable, Sendable {
    var downloading = false
    /// Why the last download failed; cleared when a new one starts.
    var error: String?
}

/// The catalog as the app holds it, plus the last refresh problem.
struct CatalogState: Sendable {
    let snapshot: ModelCatalogSnapshot?
    let problem: String?
    let refreshing: Bool
}

struct KeyTestResult: Encodable, Equatable, Sendable {
    let ok: Bool
    let message: String

    static let missingKey = KeyTestResult(ok: false, message: "Save an OpenRouter key first.")

    /// The summary without `label`: OpenRouter fills it with a masked fragment of the key.
    static func works(_ info: OpenRouterClient.KeyInfo) -> KeyTestResult {
        var parts = ["The key works."]
        if info.isFreeTier == true { parts.append("Free tier.") }
        if let usage = info.usage, let limit = info.limit {
            parts.append(String(format: "$%.2f of $%.2f used.", usage, limit))
        } else if let usage = info.usage {
            parts.append(String(format: "$%.2f used.", usage))
        }
        return KeyTestResult(ok: true, message: parts.joined(separator: " "))
    }
}

/// Download state the backend owns (the SwiftUI rows keep their own view state).
final class ModelDownloads: Sendable {
    private let state = NSLockedValue<[ModelDownloadKind: ModelDownloadStatus]>([:])

    func statuses() -> [ModelDownloadKind: ModelDownloadStatus] { state.get() }

    /// Marks `kind` as downloading; throws `.busy` when it already is.
    func begin(_ kind: ModelDownloadKind) throws {
        try state.mutate { statuses in
            if statuses[kind]?.downloading == true {
                throw BackendError.busy("That download is already running.")
            }
            statuses[kind] = ModelDownloadStatus(downloading: true, error: nil)
        }
    }

    func finish(_ kind: ModelDownloadKind, error: String?) {
        state.mutate { $0[kind] = ModelDownloadStatus(downloading: false, error: error) }
    }
}

/// A value behind an `NSLock`, for small shared state in `Sendable` classes.
final class NSLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }

    func mutate<T>(_ change: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try change(&value) }
    }
}
