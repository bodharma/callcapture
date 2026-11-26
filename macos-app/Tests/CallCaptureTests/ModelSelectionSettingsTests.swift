import Foundation
import Testing
@testable import CallCapture

@Suite("Model selection settings")
struct ModelSelectionSettingsTests {
    private func database() throws -> (AppDatabase, String) {
        let path = NSTemporaryDirectory() + "cc-models-\(UUID().uuidString).db"
        return (try AppDatabase(path: path), path)
    }

    private func load(_ db: AppDatabase) -> SettingsManager {
        SettingsManager(database: db, credentialStore: InMemoryCredentialStore())
    }

    /// Simulates a settings row written by an older app version.
    private func seed(_ db: AppDatabase, _ key: String, _ value: String) throws {
        try db.dbPool.write { try $0.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                                             arguments: [key, value]) }
    }

    @Test("on upgrade the live model is copied once from the final model, then stays independent")
    func liveCopiedOnce() throws {
        let (db, path) = try database()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seed(db, "llm_model", "google/gemini-2.5-flash")
        let first = load(db)
        #expect(first.liveLLMModel == "google/gemini-2.5-flash")
        first.llmModel = "anthropic/claude-opus-5.5"
        let second = load(db)
        #expect(second.llmModel == "anthropic/claude-opus-5.5")
        #expect(second.liveLLMModel == "google/gemini-2.5-flash")
    }

    @Test("a local-provider user's model name is copied once into the local field")
    func localCopiedOnce() throws {
        let (db, path) = try database()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seed(db, "llm_provider", "local")
        try seed(db, "llm_model", "llama3.1:8b")
        #expect(load(db).localLLMModel == "llama3.1:8b")

        let (other, otherPath) = try database()
        defer { try? FileManager.default.removeItem(atPath: otherPath) }
        try seed(other, "llm_model", "google/gemini-2.5-flash")
        #expect(load(other).localLLMModel == "")
    }

    @Test("a copied local name survives switching to OpenRouter before it was ever edited")
    func copiedLocalSurvivesProviderSwitch() throws {
        let (db, path) = try database()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seed(db, "llm_provider", "local")
        try seed(db, "llm_model", "llama3.1:8b")
        load(db).llmProvider = .openrouter
        #expect(load(db).localLLMModel == "llama3.1:8b")
    }

    @Test("switching provider never overwrites any of the three selections")
    func providerSwitchKeepsSelections() throws {
        let (db, path) = try database()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let settings = load(db)
        settings.llmModel = "anthropic/claude-sonnet-5.5"
        settings.liveLLMModel = "anthropic/claude-haiku-5.5"
        settings.localLLMModel = "qwen2.5:14b"
        settings.llmProvider = .local
        settings.llmProvider = .openrouter
        let reloaded = load(db)
        #expect(reloaded.llmModel == "anthropic/claude-sonnet-5.5")
        #expect(reloaded.liveLLMModel == "anthropic/claude-haiku-5.5")
        #expect(reloaded.localLLMModel == "qwen2.5:14b")
    }

    @Test("model(for:) picks per provider and role")
    func modelForRole() throws {
        let (db, path) = try database()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let settings = load(db)
        settings.llmModel = "final-model"
        settings.liveLLMModel = "live-model"
        settings.localLLMModel = "local-model"
        #expect(settings.model(for: .final) == "final-model")
        #expect(settings.model(for: .live) == "live-model")
        settings.llmProvider = .local
        #expect(settings.model(for: .final) == "local-model")
        #expect(settings.model(for: .live) == "local-model")
    }

    @Test("a retired persisted live model is migrated to its successor")
    func retiredLiveMigrated() throws {
        let (db, path) = try database()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seed(db, "live_llm_model", "anthropic/claude-sonnet-4")
        #expect(load(db).liveLLMModel == "anthropic/claude-sonnet-5.5")
    }
}
