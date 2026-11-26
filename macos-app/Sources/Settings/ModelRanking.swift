import Foundation

/// The two LLM jobs in the app: automatic live notes (many requests per meeting)
/// and final notes after a recording (insights + sentiment, once per recording).
enum LLMRole: String, CaseIterable, Sendable {
    case live, final
}

/// Hourly cost estimate from live prices and a token model. Tune the constants here.
enum ModelCostEstimate {
    // Final notes: insights and sentiment each send the full transcript. A meeting hour
    // is ~9,000 spoken words, ~15k tokens with speaker labels and Cyrillic, so two calls
    // ≈ 30k input; insights JSON + sentiment ≈ 2k output. (Measured 2026-11-26: insights
    // prompt ≈ 90 tokens + transcript; the spec's 13k omitted the sentiment call.)
    static let finalInputTokensPerHour = 30_000.0
    static let finalOutputTokensPerHour = 2_000.0
    // Live notes: one request per coalesced batch of committed turns (400 ms coalescing,
    // one in flight). Instructions ≈ 340 tokens + topic tree + new turns; 3k input is the
    // late-meeting size, so early requests cost less (estimate errs high).
    static let liveRequestsPerHour = 450.0
    static let liveInputTokensPerRequest = 3_000.0
    static let liveOutputTokensPerRequest = 800.0

    static func hourlyUSD(_ model: CatalogModel, role: LLMRole) -> Double {
        switch role {
        case .final:
            finalInputTokensPerHour * model.promptPricePerToken
                + finalOutputTokensPerHour * model.completionPricePerToken
        case .live:
            liveRequestsPerHour * (liveInputTokensPerRequest * model.promptPricePerToken
                + liveOutputTokensPerRequest * model.completionPricePerToken)
        }
    }

    static let explanation = """
    ≈ Estimate from OpenRouter's current prices and a token model: live notes ≈ 450 requests \
    per meeting hour × (3,000 input + 800 output tokens); final notes ≈ 30,000 input + 2,000 \
    output tokens per meeting hour (insights and sentiment over the full transcript). \
    Live notes spend is recorded per meeting.
    """
}

/// "Best for" labels derived from Artificial Analysis scores and live prices, never opinions.
enum ModelTags {
    static let highestQuality = "Highest quality"
    static let strongMultilingual = "Strong multilingual"
    static let budget = "Budget"
    /// Quartile tags need at least this many values to mean anything.
    static let minimumPopulation = 4

    static let rules = """
    Highest quality / Strong multilingual: top quarter of models by Artificial Analysis \
    Intelligence / Multilingual score. Budget: cheapest quarter of JSON-capable models for \
    live notes. Models without a score get no score tag.
    """

    static func tags(for model: CatalogModel, among models: [CatalogModel]) -> [String] {
        var tags: [String] = []
        if inTopQuarter(model.scores?.intelligence, models.compactMap { $0.scores?.intelligence }) {
            tags.append(highestQuality)
        }
        if inTopQuarter(model.scores?.multilingual, models.compactMap { $0.scores?.multilingual }) {
            tags.append(strongMultilingual)
        }
        if model.supportsJSON {
            let costs = models.filter(\.supportsJSON).map { -ModelCostEstimate.hourlyUSD($0, role: .live) }
            if inTopQuarter(-ModelCostEstimate.hourlyUSD(model, role: .live), costs) { tags.append(budget) }
        }
        return tags
    }

    /// True when `value` is among the top ⌈n/4⌉ values (ties included).
    private static func inTopQuarter(_ value: Double?, _ population: [Double]) -> Bool {
        guard let value, population.count >= minimumPopulation else { return false }
        let sorted = population.sorted(by: >)
        let threshold = sorted[Int((Double(sorted.count) / 4).rounded(.up)) - 1]
        return value >= threshold
    }
}
