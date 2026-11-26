import Foundation
import Testing
@testable import CallCapture

@Suite("LLMModelCatalog")
struct LLMModelCatalogTests {
    @Test("catalog contains the worker's default slug")
    func defaultPresent() {
        let opt = LLMModelCatalog.option(for: LLMModelCatalog.defaultSlug)
        #expect(opt.isCustom == false)
        #expect(opt.slug == LLMModelCatalog.defaultSlug)
    }

    @Test("slugs are unique within the curated list")
    func uniqueSlugs() {
        let slugs = LLMModelCatalog.curated.filter { !$0.isCustom }.map(\.slug)
        #expect(slugs.count == Set(slugs).count)
    }

    @Test("custom sentinel is last and round-trips an unknown slug")
    func customFallback() {
        #expect(LLMModelCatalog.curated.last?.isCustom == true)
        let opt = LLMModelCatalog.option(for: "experimental/never-shipped-model")
        #expect(opt.isCustom == true)
    }

    @Test("display names are non-empty")
    func displayNames() {
        for opt in LLMModelCatalog.curated {
            #expect(!opt.displayName.isEmpty)
        }
    }

    @Test("slugs OpenRouter retired map to their successors; current slugs pass through")
    func retiredSlugs() {
        #expect(LLMModelCatalog.current("anthropic/claude-sonnet-4") == "anthropic/claude-sonnet-5.5")
        #expect(LLMModelCatalog.current("anthropic/claude-3.5-haiku") == "anthropic/claude-haiku-5.5")
        #expect(LLMModelCatalog.current("google/gemini-2.5-flash") == "google/gemini-2.5-flash")
        #expect(LLMModelCatalog.current("experimental/custom") == "experimental/custom")
    }

    @Test("no retired slug is offered in the picker")
    func noRetiredInCatalog() {
        let offered = Set(LLMModelCatalog.curated.map(\.slug))
        #expect(offered.isDisjoint(with: LLMModelCatalog.retired.keys))
        #expect(LLMModelCatalog.retired.values.allSatisfy { offered.contains($0) })
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
