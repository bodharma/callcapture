import Foundation

/// The live model list comes from OpenRouter (`ModelCatalogService`). What remains here
/// is the first-launch default and the migration for slugs OpenRouter retired.
enum LLMModelCatalog {
    /// Default slug on first launch. Matches the worker's default.
    static let defaultSlug = "google/gemini-2.5-flash"

    /// Slugs OpenRouter stopped serving (requests return HTTP 404), mapped to a current
    /// successor. A persisted retired slug is migrated when settings load.
    static let retired: [String: String] = [
        "anthropic/claude-sonnet-4": "anthropic/claude-sonnet-5.5",
        "anthropic/claude-opus-4": "anthropic/claude-opus-5.5",
        "anthropic/claude-3.5-sonnet": "anthropic/claude-sonnet-4.6",
        "anthropic/claude-3.5-haiku": "anthropic/claude-haiku-5.5",
    ]

    /// `slug`, or its successor when OpenRouter retired it.
    static func current(_ slug: String) -> String { retired[slug] ?? slug }
}
