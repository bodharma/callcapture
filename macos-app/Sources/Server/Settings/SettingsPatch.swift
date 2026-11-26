import Foundation

/// A checked `PATCH /api/settings` body: nil means "leave as is". Built only by
/// `SettingsValidation`, so every value here is already of the right type and range.
struct SettingsPatch: Equatable, Sendable {
    var autoProcessOnStop: Bool?
    var outputDirectory: String?
    var keepSeparateMicTrack: Bool?
    var engine: TranscriptionEngine?
    var whisperModel: WhisperModel?
    var remoteProvider: RemoteProvider?
    var provider: LLMProvider?
    var finalModel: String?
    var liveModel: String?
    var localModel: String?
    var localBaseURL: String?
    var obsidianVault: String?
    var folderPattern: String?
    var markdownProfile: MarkdownProfile?
    var assemblyAIPerMin: Double?
    var deepgramPerMin: Double?
    var openAIPerMin: Double?
    var groqPerMin: Double?
    var llmFallbackPer1M: Double?
}

extension SettingsManager {
    /// Applies through the ordinary property setters, so their `didSet` persistence
    /// (including the per-role model upgrade copies) runs exactly as for a SwiftUI edit.
    /// Unchanged values are not reassigned, like a SwiftUI control that was not moved.
    func apply(_ patch: SettingsPatch) {
        // Provider first: its setter stores the upgrade copies before any model edit.
        assign(\.llmProvider, patch.provider)
        assign(\.llmModel, patch.finalModel)
        assign(\.liveLLMModel, patch.liveModel)
        assign(\.localLLMModel, patch.localModel)
        assign(\.localLLMBaseURL, patch.localBaseURL)
        assign(\.autoProcessOnStop, patch.autoProcessOnStop)
        assign(\.outputDirectory, patch.outputDirectory)
        assign(\.keepSeparateMicTrack, patch.keepSeparateMicTrack)
        assign(\.defaultEngine, patch.engine)
        assign(\.whisperModel, patch.whisperModel)
        assign(\.remoteProvider, patch.remoteProvider)
        assign(\.obsidianExportDirectory, patch.obsidianVault)
        assign(\.obsidianFolderPattern, patch.folderPattern)
        assign(\.markdownProfile, patch.markdownProfile)
        assign(\.sttRateAssemblyAI, patch.assemblyAIPerMin)
        assign(\.sttRateDeepgram, patch.deepgramPerMin)
        assign(\.sttRateOpenAI, patch.openAIPerMin)
        assign(\.sttRateGroq, patch.groqPerMin)
        assign(\.llmFallbackRatePer1M, patch.llmFallbackPer1M)
    }

    /// Stores the secret in the credential store (an empty value removes it).
    func setSecret(_ key: SecretKey, to value: String) {
        switch key {
        case .openrouter: openRouterApiKey = value
        case .assemblyai: assemblyAIApiKey = value
        case .deepgram: deepgramApiKey = value
        case .remote: remoteApiKey = value
        }
    }

    func hasSecret(_ key: SecretKey) -> Bool {
        switch key {
        case .openrouter: !openRouterApiKey.isEmpty
        case .assemblyai: !assemblyAIApiKey.isEmpty
        case .deepgram: !deepgramApiKey.isEmpty
        case .remote: !remoteApiKey.isEmpty
        }
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SettingsManager, Value>, _ value: Value?) {
        guard let value, self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }
}
