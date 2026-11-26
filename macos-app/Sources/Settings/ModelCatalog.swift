import Foundation

/// Independent scores published by Artificial Analysis, relayed by OpenRouter.
struct ModelScores: Codable, Equatable, Sendable {
    let intelligence: Double?      // 0–100
    let multilingual: Double?      // 0–1
    let strategyAndOps: Double?    // 0–100
}

/// One model OpenRouter currently serves, with per-token USD prices.
struct CatalogModel: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let canonicalSlug: String?
    let name: String
    let promptPricePerToken: Double
    let completionPricePerToken: Double
    let contextLength: Int
    /// Accepts `response_format` / `structured_outputs`; automatic live notes need it.
    let supportsJSON: Bool
    var scores: ModelScores?
}

struct ModelCatalogSnapshot: Codable, Equatable, Sendable {
    var models: [CatalogModel]
    var modelsFetchedAt: Date
    var scoresFetchedAt: Date?
    var scoresCitation: String?
    /// Why scores are missing or stale; nil when the last score fetch succeeded.
    var scoresProblem: String?

    func model(id: String) -> CatalogModel? { models.first { $0.id == id } }

    /// Required wording when Artificial Analysis scores are republished (CC BY 4.0).
    static let attributionFallback = "Source: Artificial Analysis (artificialanalysis.ai) via OpenRouter (openrouter.ai/rankings)."

    /// The attribution to show whenever any score is shown; nil when there are none.
    var attribution: String? {
        models.contains { $0.scores != nil } ? (scoresCitation ?? Self.attributionFallback) : nil
    }
}

enum ModelCatalogError: LocalizedError, Equatable {
    case offline, http(Int), invalidResponse

    var errorDescription: String? {
        switch self {
        case .offline: "Offline — the model list needs an internet connection."
        case .http(let code): "OpenRouter returned HTTP \(code) for the model list."
        case .invalidResponse: "OpenRouter returned a model list this app could not read."
        }
    }
}

/// Fetches OpenRouter's live model list and Artificial Analysis scores, joins them
/// and caches the result. Refetches at most once per `maxAge` unless forced, which
/// keeps well inside the Data API quota (500 requests/day).
struct ModelCatalogService: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let maxAge: TimeInterval = 86_400
    static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    static let benchmarksURL = URL(string: "https://openrouter.ai/api/v1/benchmarks?source=artificial-analysis&max_results=100")!
    static let urlSession: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelCatalogError.invalidResponse }
        return (data, http)
    }

    let cacheURL: URL
    private let transport: Transport
    private let now: @Sendable () -> Date

    init(cacheURL: URL, transport: @escaping Transport = ModelCatalogService.urlSession,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.cacheURL = cacheURL
        self.transport = transport
        self.now = now
    }

    func cached() -> ModelCatalogSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? Self.decoder.decode(ModelCatalogSnapshot.self, from: data)
    }

    func refresh(apiKey: String, force: Bool) async throws -> ModelCatalogSnapshot {
        let previous = cached()
        if !force, let previous, now().timeIntervalSince(previous.modelsFetchedAt) < Self.maxAge {
            return previous
        }
        var models = try await fetchModels()
        let fetchedAt = now()
        var snapshot = ModelCatalogSnapshot(models: [], modelsFetchedAt: fetchedAt,
                                            scoresFetchedAt: previous?.scoresFetchedAt,
                                            scoresCitation: previous?.scoresCitation)
        let previousScores = Dictionary(previous?.models.compactMap { m in m.scores.map { (m.id, $0) } } ?? [],
                                        uniquingKeysWith: { first, _ in first })
        switch await fetchScores(apiKey: apiKey) {
        case .success(let (byPermaslug, citation)):
            for index in models.indices {
                let model = models[index]
                models[index].scores = model.canonicalSlug.flatMap { byPermaslug[$0] } ?? byPermaslug[model.id]
            }
            snapshot.scoresFetchedAt = fetchedAt
            snapshot.scoresCitation = citation ?? snapshot.scoresCitation
        case .failure(let problem):
            for index in models.indices { models[index].scores = previousScores[models[index].id] }
            snapshot.scoresProblem = problem.message
        }
        snapshot.models = models
        try Self.encoder.encode(snapshot).write(to: cacheURL, options: .atomic)
        return snapshot
    }

    // MARK: - Fetching

    private func fetchModels() async throws -> [CatalogModel] {
        let data = try await send(URLRequest(url: Self.modelsURL))
        guard let list = try? JSONDecoder().decode(ModelList.self, from: data) else {
            throw ModelCatalogError.invalidResponse
        }
        return list.data.compactMap(\.catalogModel)
    }

    private struct ScoreProblem: Error { let message: String }

    private func fetchScores(apiKey: String) async -> Result<([String: ModelScores], String?), ScoreProblem> {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(ScoreProblem(message: "Scores need an OpenRouter key."))
        }
        var request = URLRequest(url: Self.benchmarksURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let data = try await send(request)
            let list = try JSONDecoder().decode(BenchmarkList.self, from: data)
            let scores = Dictionary(list.data.map { ($0.modelPermaslug, $0.scores) }, uniquingKeysWith: { first, _ in first })
            return .success((scores, list.meta?.citation))
        } catch ModelCatalogError.http(let code) where code == 401 || code == 403 {
            return .failure(ScoreProblem(message: "Scores need a valid OpenRouter key."))
        } catch ModelCatalogError.http(429) {
            return .failure(ScoreProblem(message: "Scores are rate-limited; try later."))
        } catch ModelCatalogError.offline {
            return .failure(ScoreProblem(message: "Scores need an internet connection."))
        } catch {
            return .failure(ScoreProblem(message: "Scores could not be loaded."))
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 20
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            throw ModelCatalogError.offline
        }
        guard (200..<300).contains(response.statusCode) else { throw ModelCatalogError.http(response.statusCode) }
        return data
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
        .cannotConnectToHost, .timedOut, .dnsLookupFailed, .dataNotAllowed,
    ]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Wire formats

private struct ModelList: Decodable {
    struct Entry: Decodable {
        struct Pricing: Decodable { let prompt: String?; let completion: String? }
        let id: String
        let canonical_slug: String?
        let name: String?
        let context_length: Int?
        let pricing: Pricing?
        let supported_parameters: [String]?

        /// Nil for routers (negative "variable" prices) and entries without usable prices.
        var catalogModel: CatalogModel? {
            guard let prompt = pricing?.prompt.flatMap(Double.init), prompt.isFinite, prompt >= 0,
                  let completion = pricing?.completion.flatMap(Double.init), completion.isFinite, completion >= 0
            else { return nil }
            let parameters = Set(supported_parameters ?? [])
            return CatalogModel(id: id, canonicalSlug: canonical_slug, name: name ?? id,
                                promptPricePerToken: prompt, completionPricePerToken: completion,
                                contextLength: context_length ?? 0,
                                supportsJSON: parameters.contains("response_format") || parameters.contains("structured_outputs"),
                                scores: nil)
        }
    }
    let data: [Entry]
}

private struct BenchmarkList: Decodable {
    struct Entry: Decodable {
        let modelPermaslug: String
        let intelligence: Double?
        let multilingual: Double?
        let strategyAndOps: Double?
        var scores: ModelScores { ModelScores(intelligence: intelligence, multilingual: multilingual, strategyAndOps: strategyAndOps) }

        enum CodingKeys: String, CodingKey {
            case modelPermaslug = "model_permaslug"
            case intelligence = "intelligence_index"
            case multilingual = "multilingual_index"
            case strategyAndOps = "strategy_and_ops_index"
        }
    }
    struct Meta: Decodable { let citation: String? }
    let data: [Entry]
    let meta: Meta?
}
