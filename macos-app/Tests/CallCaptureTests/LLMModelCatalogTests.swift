import Foundation
import Testing
@testable import CallCapture

@Suite("LLMModelCatalog")
struct LLMModelCatalogTests {




    @Test("retired slugs never map to another retired slug")
    func successorsAreCurrent() {
        #expect(Set(LLMModelCatalog.retired.values).isDisjoint(with: LLMModelCatalog.retired.keys))
    }

    @Test("slugs OpenRouter retired map to their successors; current slugs pass through")
    func retiredSlugs() {
        #expect(LLMModelCatalog.current("anthropic/claude-sonnet-4") == "anthropic/claude-sonnet-5.5")
        #expect(LLMModelCatalog.current("anthropic/claude-3.5-haiku") == "anthropic/claude-haiku-5.5")
        #expect(LLMModelCatalog.current("google/gemini-2.5-flash") == "google/gemini-2.5-flash")
        #expect(LLMModelCatalog.current("experimental/custom") == "experimental/custom")
    }


    @Test("a persisted retired model is migrated when settings load")
    func settingsMigrateRetiredModel() throws {
        let path = NSTemporaryDirectory() + "cc-llm-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try AppDatabase(path: path)
        SettingsManager(database: db, credentialStore: InMemoryCredentialStore()).llmModel = "anthropic/claude-sonnet-4"
        let reloaded = SettingsManager(database: db, credentialStore: InMemoryCredentialStore())
        #expect(reloaded.llmModel == "anthropic/claude-sonnet-5.5")
    }
}
