import Foundation

/// `GET /api/catalog`: OpenRouter's models as the app holds them, with the per-hour
/// cost estimates and "best for" tags computed here so the web UI never re-derives them.
/// `attribution` is present exactly when any model carries Artificial Analysis scores
/// and must be shown wherever those scores are.
struct CatalogDTO: Encodable, Sendable {
    struct Hourly: Encodable, Sendable {
        let live: Double
        let final: Double
    }

    struct Model: Encodable, Sendable {
        let id: String
        let name: String
        let canonicalSlug: String?
        let promptPricePerToken: Double
        let completionPricePerToken: Double
        let contextLength: Int
        let supportsJSON: Bool
        let scores: ModelScores?
        let hourlyUSD: Hourly
        let tags: [String]
    }

    let models: [Model]
    let fetchedAt: Date?
    let scoresFetchedAt: Date?
    let attribution: String?
    let scoresProblem: String?
    /// Why the last refresh failed; the cached models are still listed.
    let problem: String?
    let refreshing: Bool
    let costExplanation: String
    let tagRules: String

    init(_ state: CatalogState) {
        let catalog = state.snapshot?.models ?? []
        models = catalog.map { model in
            Model(
                id: model.id, name: model.name, canonicalSlug: model.canonicalSlug,
                promptPricePerToken: model.promptPricePerToken,
                completionPricePerToken: model.completionPricePerToken, contextLength: model.contextLength,
                supportsJSON: model.supportsJSON, scores: model.scores,
                hourlyUSD: Hourly(
                    live: ModelCostEstimate.hourlyUSD(model, role: .live),
                    final: ModelCostEstimate.hourlyUSD(model, role: .final)),
                tags: ModelTags.tags(for: model, among: catalog))
        }
        fetchedAt = state.snapshot?.modelsFetchedAt
        scoresFetchedAt = state.snapshot?.scoresFetchedAt
        attribution = state.snapshot?.attribution
        scoresProblem = state.snapshot?.scoresProblem
        problem = state.problem
        refreshing = state.refreshing
        costExplanation = ModelCostEstimate.explanation
        tagRules = ModelTags.rules
    }
}
