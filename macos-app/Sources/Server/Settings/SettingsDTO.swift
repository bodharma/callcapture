import Foundation

/// `GET /api/settings`: every user-editable setting, grouped by the web UI's panes.
/// Secrets appear only as `{"set": Bool}`. `transcription.models`, `aiNotes.warnings`
/// and `offlineReasons` are read-only reports from the app.
struct SettingsDTO: Encodable, Equatable, Sendable {
    struct General: Encodable, Equatable, Sendable {
        let autoProcessOnStop: Bool
    }

    struct Recording: Encodable, Equatable, Sendable {
        let outputDirectory: String
        let keepSeparateMicTrack: Bool
    }

    struct ModelState: Encodable, Equatable, Sendable {
        let ready: Bool
        let downloading: Bool
        let error: String?
    }

    struct Models: Encodable, Equatable, Sendable {
        let diarization: ModelState
        let emotion: ModelState
    }

    struct Transcription: Encodable, Equatable, Sendable {
        let engine: String
        let whisperModel: String
        let remoteProvider: String
        let models: Models
    }

    /// Why a role's OpenRouter model may not work (`ModelSelectionWarning`).
    struct Warnings: Encodable, Equatable, Sendable {
        let final: String?
        let live: String?
    }

    struct AINotes: Encodable, Equatable, Sendable {
        let provider: String
        let finalModel: String
        let liveModel: String
        let localModel: String
        let localBaseURL: String
        let warnings: Warnings
    }

    struct Vault: Encodable, Equatable, Sendable {
        let obsidianVault: String
        let folderPattern: String
        let markdownProfile: String
    }

    struct Costs: Encodable, Equatable, Sendable {
        let assemblyAIPerMin: Double
        let deepgramPerMin: Double
        let openAIPerMin: Double
        let groqPerMin: Double
        let llmFallbackPer1M: Double
    }

    struct Secret: Encodable, Equatable, Sendable {
        let set: Bool
    }

    struct Secrets: Encodable, Equatable, Sendable {
        let openrouter: Secret
        let assemblyai: Secret
        let deepgram: Secret
        let remote: Secret
    }

    /// The app's wording for controls that are disabled while offline.
    struct OfflineReasons: Encodable, Equatable, Sendable {
        let refreshCatalog: String
        let testKey: String
        let download: String
    }

    let general: General
    let recording: Recording
    let transcription: Transcription
    let aiNotes: AINotes
    let vault: Vault
    let costs: Costs
    let secrets: Secrets
    let offlineReasons: OfflineReasons
}

extension SettingsDTO {
    init(
        settings: SettingsManager, catalog: ModelCatalogSnapshot?, isOnline: Bool,
        downloads: [ModelDownloadKind: ModelDownloadStatus]
    ) {
        func model(_ kind: ModelDownloadKind, ready: Bool) -> ModelState {
            let status = downloads[kind] ?? ModelDownloadStatus()
            return ModelState(ready: ready, downloading: status.downloading, error: status.error)
        }
        func warning(_ role: LLMRole, _ selection: String) -> String? {
            guard settings.llmProvider == .openrouter else { return nil }
            return ModelSelectionWarning.text(role: role, selection: selection, snapshot: catalog, isOnline: isOnline)
        }
        general = General(autoProcessOnStop: settings.autoProcessOnStop)
        recording = Recording(
            outputDirectory: settings.outputDirectory, keepSeparateMicTrack: settings.keepSeparateMicTrack)
        transcription = Transcription(
            engine: settings.defaultEngine.rawValue, whisperModel: settings.whisperModel.rawValue,
            remoteProvider: settings.remoteProvider.rawValue,
            models: Models(
                diarization: model(.diarization, ready: settings.diarizationModelsReady),
                emotion: model(.emotion, ready: settings.emotionModelsReady)))
        aiNotes = AINotes(
            provider: settings.llmProvider.rawValue, finalModel: settings.llmModel,
            liveModel: settings.liveLLMModel, localModel: settings.localLLMModel,
            localBaseURL: settings.localLLMBaseURL,
            warnings: Warnings(final: warning(.final, settings.llmModel), live: warning(.live, settings.liveLLMModel)))
        vault = Vault(
            obsidianVault: settings.obsidianExportDirectory, folderPattern: settings.obsidianFolderPattern,
            markdownProfile: settings.markdownProfile.rawValue)
        costs = Costs(
            assemblyAIPerMin: settings.sttRateAssemblyAI, deepgramPerMin: settings.sttRateDeepgram,
            openAIPerMin: settings.sttRateOpenAI, groqPerMin: settings.sttRateGroq,
            llmFallbackPer1M: settings.llmFallbackRatePer1M)
        secrets = Secrets(
            openrouter: Secret(set: settings.hasSecret(.openrouter)),
            assemblyai: Secret(set: settings.hasSecret(.assemblyai)),
            deepgram: Secret(set: settings.hasSecret(.deepgram)),
            remote: Secret(set: settings.hasSecret(.remote)))
        offlineReasons = OfflineReasons(
            refreshCatalog: NetworkPolicy.catalogRefreshOfflineReason,
            testKey: NetworkPolicy.keyTestOfflineReason,
            download: NetworkPolicy.downloadBlockReason(isOnline: false) ?? ConnectivityMonitor.offlineReason)
    }
}
