import Foundation
import os

private let settingsLogger = Logger(subsystem: "com.callcapture.app", category: "SettingsAPI")

/// Settings, secrets, the model catalog, folder choosing and model downloads for the
/// web API. Settings live on the main actor (the SwiftUI window edits the same
/// `SettingsManager`), so every read and write hops there; apply and snapshot happen in
/// one main-actor step so the answer shows exactly what was applied.
@available(macOS 14.2, *)
extension AppModelBackend {
    func settingsSnapshot() async throws -> SettingsDTO {
        let model = try requireModel()
        let downloads = modelDownloads.statuses()
        return await MainActor.run { Self.snapshot(model, downloads: downloads) }
    }

    func updateSettings(_ patch: SettingsPatch) async throws -> SettingsDTO {
        let model = try requireModel()
        let downloads = modelDownloads.statuses()
        return await MainActor.run {
            model.settingsManager.apply(patch)
            return Self.snapshot(model, downloads: downloads)
        }
    }

    func resetCosts() async throws -> SettingsDTO {
        let model = try requireModel()
        let downloads = modelDownloads.statuses()
        return await MainActor.run {
            model.settingsManager.resetPricingToDefaults()
            return Self.snapshot(model, downloads: downloads)
        }
    }

    func setSecret(_ key: SecretKey, value: String) async throws {
        let model = try requireModel()
        await MainActor.run { model.settingsManager.setSecret(key, to: value) }
    }

    func testOpenRouterKey() async throws -> KeyTestResult {
        let model = try requireModel()
        let key = await MainActor.run { model.settingsManager.openRouterApiKey }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .missingKey }
        do {
            return .works(try await OpenRouterClient().validate(apiKey: key))
        } catch {
            return KeyTestResult(
                ok: false, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func catalog() async -> CatalogState {
        guard let model else { return CatalogState(snapshot: nil, problem: nil, refreshing: false) }
        return await MainActor.run {
            CatalogState(snapshot: model.catalogSnapshot, problem: model.catalogProblem, refreshing: model.catalogRefreshing)
        }
    }

    func refreshCatalog(force: Bool) async {
        guard let model else { return }
        await Task { @MainActor in await model.refreshModelCatalog(force: force) }.value
    }

    func pickFolder(for setting: FolderSetting) async throws -> String? {
        let model = try requireModel()
        return try await Task { @MainActor in
            let settings = model.settingsManager
            let current = setting == .outputDirectory ? settings.outputDirectory : settings.obsidianExportDirectory
            return try await FolderPicker.shared.choose(message: setting.panelMessage, startingAt: current)
        }.value
    }

    func startModelDownload(_ kind: ModelDownloadKind) async throws {
        let model = try requireModel()
        let ready = await MainActor.run {
            kind == .diarization ? model.settingsManager.diarizationModelsReady : model.settingsManager.emotionModelsReady
        }
        guard !ready else { throw BackendError.busy("Already downloaded.") }
        try modelDownloads.begin(kind)
        let downloads = modelDownloads
        let hub = events
        Task { @MainActor in
            let failure = await Self.download(kind, model: model)
            downloads.finish(kind, error: failure)
            hub.post(.settings)
        }
    }

    /// Runs the same work as the SwiftUI download rows; returns why it failed, or nil.
    @MainActor
    private static func download(_ kind: ModelDownloadKind, model: AppModel) async -> String? {
        do {
            switch kind {
            case .diarization:
                try await model.diarizationService.prepareModels()
                model.settingsManager.diarizationModelsReady = true
            case .emotion:
                let result = try await model.pythonBridge.runJob(request: .prepareEmotion())
                guard result.status == "completed" else { return result.errorMessage ?? "Download failed." }
                model.settingsManager.emotionModelsReady = true
            }
            return nil
        } catch {
            settingsLogger.error("Model download \(kind.rawValue) failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    @MainActor
    private static func snapshot(_ model: AppModel, downloads: [ModelDownloadKind: ModelDownloadStatus]) -> SettingsDTO {
        SettingsDTO(
            settings: model.settingsManager, catalog: model.catalogSnapshot,
            isOnline: model.connectivity.isOnline, downloads: downloads)
    }
}
