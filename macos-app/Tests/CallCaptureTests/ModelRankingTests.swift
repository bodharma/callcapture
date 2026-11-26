import Foundation
import Testing
@testable import CallCapture

private func model(_ id: String, input: Double, output: Double, json: Bool = true,
                   intelligence: Double? = nil, multilingual: Double? = nil) -> CatalogModel {
    CatalogModel(id: id, canonicalSlug: nil, name: id, promptPricePerToken: input / 1_000_000,
                 completionPricePerToken: output / 1_000_000, contextLength: 100_000, supportsJSON: json,
                 scores: intelligence == nil && multilingual == nil ? nil
                     : ModelScores(intelligence: intelligence, multilingual: multilingual, strategyAndOps: nil))
}

@Suite("Model ranking")
struct ModelRankingTests {
    @Test("hourly cost follows the token model for each role")
    func hourlyCost() {
        let m = model("m", input: 2, output: 10)
        let e = ModelCostEstimate.self
        let final = e.finalInputTokensPerHour * 2e-6 + e.finalOutputTokensPerHour * 10e-6
        let live = e.liveRequestsPerHour * (e.liveInputTokensPerRequest * 2e-6 + e.liveOutputTokensPerRequest * 10e-6)
        #expect(abs(e.hourlyUSD(m, role: .final) - final) < 1e-12)
        #expect(abs(e.hourlyUSD(m, role: .live) - live) < 1e-12)
        #expect(e.hourlyUSD(model("free", input: 0, output: 0), role: .live) == 0)
        #expect(!e.explanation.isEmpty)
    }

    @Test("score tags mark the top quartile; budget marks the cheapest JSON-capable quartile")
    func quartileTags() {
        let models = [
            model("a", input: 0.1, output: 0.5, intelligence: 40, multilingual: 0.60),
            model("b", input: 0.2, output: 1.0, intelligence: 45, multilingual: 0.70),
            model("c", input: 0.5, output: 2.0, intelligence: 50, multilingual: 0.75),
            model("d", input: 1.0, output: 4.0, intelligence: 55, multilingual: 0.80),
            model("e", input: 2.0, output: 8.0, intelligence: 60, multilingual: 0.82),
            model("f", input: 3.0, output: 12.0, intelligence: 65, multilingual: 0.85),
            model("g", input: 4.0, output: 16.0, intelligence: 70, multilingual: 0.88),
            model("h", input: 0.05, output: 0.1, json: false, intelligence: 30, multilingual: 0.90),
        ]
        func tags(_ id: String) -> [String] { ModelTags.tags(for: models.first { $0.id == id }!, among: models) }
        #expect(tags("g").contains("Highest quality"))
        #expect(tags("f").contains("Highest quality"))
        #expect(!tags("e").contains("Highest quality"))
        #expect(tags("h").contains("Strong multilingual"))
        #expect(tags("g").contains("Strong multilingual"))
        #expect(!tags("d").contains("Strong multilingual"))
        #expect(tags("a").contains("Budget"))
        #expect(tags("b").contains("Budget"))
        #expect(!tags("h").contains("Budget"))   // cheapest overall, but no JSON support
        #expect(!tags("c").contains("Budget"))
        #expect(!ModelTags.rules.isEmpty)
    }

    @Test("unscored models get no score tags; fewer than four scores give no quartile tags")
    func sparseScores() {
        let unscored = model("u", input: 1, output: 1)
        let few = [model("x", input: 1, output: 1, intelligence: 90, multilingual: 0.99),
                   model("y", input: 1, output: 1, intelligence: 10, multilingual: 0.1), unscored]
        #expect(ModelTags.tags(for: unscored, among: few).filter { $0 != "Budget" }.isEmpty)
        #expect(!ModelTags.tags(for: few[0], among: few).contains("Highest quality"))
        #expect(!ModelTags.tags(for: few[0], among: few).contains("Strong multilingual"))
    }
}
