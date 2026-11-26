import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

enum CatalogFixtures {
    static let fetchedAt = Date(timeIntervalSince1970: 1_795_000_000)
    static let citation = "Scores: Artificial Analysis (artificialanalysis.ai), CC BY 4.0."

    static func model(
        _ id: String, _ name: String, prompt: Double, completion: Double, context: Int = 128_000,
        json: Bool = true, scores: ModelScores? = nil
    ) -> CatalogModel {
        CatalogModel(
            id: id, canonicalSlug: id + "-2026", name: name, promptPricePerToken: prompt,
            completionPricePerToken: completion, contextLength: context, supportsJSON: json, scores: scores)
    }

    static let models: [CatalogModel] = [
        model("smart/json", "Smart JSON", prompt: 3e-6, completion: 1.5e-5, context: 200_000,
              scores: ModelScores(intelligence: 70, multilingual: 0.9, strategyAndOps: 65)),
        model("cheap/json", "Cheap JSON", prompt: 1e-7, completion: 4e-7,
              scores: ModelScores(intelligence: 40, multilingual: 0.6, strategyAndOps: 30)),
        model("text/only", "Text Only", prompt: 5e-8, completion: 1e-7, context: 32_000, json: false),
        model("mid/json", "Mid JSON", prompt: 5e-7, completion: 2e-6, context: 1_000_000,
              scores: ModelScores(intelligence: 55, multilingual: 0.8, strategyAndOps: 50)),
        model("free/json", "Free JSON", prompt: 0, completion: 0, context: 8_000,
              scores: ModelScores(intelligence: 20, multilingual: 0.3, strategyAndOps: nil)),
    ]

    static func snapshot(models: [CatalogModel] = models, citation: String? = citation, problem: String? = nil)
        -> ModelCatalogSnapshot
    {
        ModelCatalogSnapshot(
            models: models, modelsFetchedAt: fetchedAt, scoresFetchedAt: fetchedAt, scoresCitation: citation,
            scoresProblem: problem)
    }
}

@Suite("Catalog API")
struct CatalogAPITests {
    @Test("the catalog is served as the app holds it, with per-hour costs and tags computed in Swift")
    func catalogServed() async throws {
        let api = SignedInAPI()
        api.settings.setCatalog(CatalogState(snapshot: CatalogFixtures.snapshot(), problem: nil, refreshing: false))
        try await api.run { client in
            let response = try await api.request(client, "/api/catalog")
            #expect(response.status == .ok)
            let body = try jsonObject(response)
            let models = try #require(body["models"] as? [[String: Any]])
            #expect(models.map { $0["id"] as? String } == CatalogFixtures.models.map(\.id))
            for (dto, model) in zip(models, CatalogFixtures.models) {
                #expect(dto["name"] as? String == model.name)
                #expect(dto["contextLength"] as? Int == model.contextLength)
                #expect(dto["supportsJSON"] as? Bool == model.supportsJSON)
                #expect(dto["promptPricePerToken"] as? Double == model.promptPricePerToken)
                #expect(dto["completionPricePerToken"] as? Double == model.completionPricePerToken)
                let hourly = try #require(dto["hourlyUSD"] as? [String: Double])
                // JSONSerialization may round the last digit when it parses the answer.
                #expect(abs((hourly["live"] ?? -1) - ModelCostEstimate.hourlyUSD(model, role: .live)) < 1e-12)
                #expect(abs((hourly["final"] ?? -1) - ModelCostEstimate.hourlyUSD(model, role: .final)) < 1e-12)
                #expect(dto["tags"] as? [String] == ModelTags.tags(for: model, among: CatalogFixtures.models))
            }
            let smart = try #require(models.first)
            #expect(smart["scores"] as? [String: Double] == ["intelligence": 70, "multilingual": 0.9, "strategyAndOps": 65])
            #expect(models[2]["scores"] == nil)
            #expect((smart["tags"] as? [String])?.contains("Highest quality") == true)
            #expect(body["attribution"] as? String == CatalogFixtures.citation)
            #expect(body["fetchedAt"] as? String == ISO8601DateFormatter().string(from: CatalogFixtures.fetchedAt))
            #expect(body["refreshing"] as? Bool == false)
            #expect(body["costExplanation"] as? String == ModelCostEstimate.explanation)
            #expect(body["tagRules"] as? String == ModelTags.rules)
        }
    }

    @Test("scores without a citation carry the required fallback attribution; no scores, no attribution")
    func attribution() async throws {
        let api = SignedInAPI()
        api.settings.setCatalog(CatalogState(snapshot: CatalogFixtures.snapshot(citation: nil), problem: nil, refreshing: false))
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/catalog"))
            #expect(body["attribution"] as? String == ModelCatalogSnapshot.attributionFallback)

            let unscored = CatalogFixtures.models.map { model -> CatalogModel in
                var copy = model
                copy.scores = nil
                return copy
            }
            api.settings.setCatalog(CatalogState(
                snapshot: CatalogFixtures.snapshot(models: unscored, problem: "Scores need an OpenRouter key."),
                problem: nil, refreshing: false))
            let plain = try jsonObject(try await api.request(client, "/api/catalog"))
            #expect(plain["attribution"] == nil)
            #expect(plain["scoresProblem"] as? String == "Scores need an OpenRouter key.")
        }
    }

    @Test("before the first fetch the catalog is empty, not an error")
    func catalogNotLoaded() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let response = try await api.request(client, "/api/catalog")
            #expect(response.status == .ok)
            let body = try jsonObject(response)
            #expect((body["models"] as? [Any])?.isEmpty == true)
            #expect(body["fetchedAt"] == nil)
            #expect(body["attribution"] == nil)
        }
    }

    @Test("refresh is refused offline with the app's wording and never reaches the network")
    func refreshOffline() async throws {
        let api = SignedInAPI()
        api.backend.setOnline(false)
        try await api.run { client in
            let response = try await api.request(client, "/api/catalog/refresh", method: .post)
            #expect(response.status == .conflict)
            // JSONEncoder doesn't promise key order, so compare fields.
            let body = try jsonObject(response)
            #expect(body.count == 2)
            #expect(body["error"] as? String == "offline")
            #expect(body["message"] as? String == "Offline — refreshing needs an internet connection.")
        }
        #expect(api.settings.refreshCalls.isEmpty)
    }

    @Test("refresh online answers with the new snapshot; force defaults to true")
    func refreshOnline() async throws {
        let api = SignedInAPI()
        let fresh = CatalogFixtures.snapshot(models: Array(CatalogFixtures.models.prefix(2)))
        api.settings.refreshWillProduce(CatalogState(snapshot: fresh, problem: nil, refreshing: false))
        try await api.run { client in
            let response = try await api.request(client, "/api/catalog/refresh", method: .post)
            #expect(response.status == .ok)
            #expect((try jsonObject(response)["models"] as? [Any])?.count == 2)
            let lazy = try await api.request(client, "/api/catalog/refresh", method: .post, json: #"{"force":false}"#)
            #expect(lazy.status == .ok)
            let bad = try await api.request(client, "/api/catalog/refresh", method: .post, json: #"{"force":"yes"}"#)
            #expect(bad.status == .badRequest)
        }
        #expect(api.settings.refreshCalls == [true, false])
    }

    @Test("a failed refresh keeps the cached list and reports why")
    func refreshFailure() async throws {
        let api = SignedInAPI()
        let cached = CatalogFixtures.snapshot()
        api.settings.setCatalog(CatalogState(snapshot: cached, problem: nil, refreshing: false))
        api.settings.refreshWillProduce(CatalogState(
            snapshot: cached, problem: "OpenRouter returned HTTP 503 for the model list.", refreshing: false))
        try await api.run { client in
            let response = try await api.request(client, "/api/catalog/refresh", method: .post)
            #expect(response.status == .ok)
            let body = try jsonObject(response)
            #expect(body["problem"] as? String == "OpenRouter returned HTTP 503 for the model list.")
            #expect((body["models"] as? [Any])?.count == CatalogFixtures.models.count)
        }
    }
}

@Suite("System API: folder picker")
struct PickFolderAPITests {
    @Test("cancelling the chooser answers path null")
    func pickFolderCancel() async throws {
        let api = SignedInAPI()
        api.settings.pickWillReturn(.success(nil))
        try await api.run { client in
            let response = try await api.request(
                client, "/api/system/pick-folder", method: .post, json: #"{"setting":"obsidianVault"}"#)
            #expect(response.status == .ok)
            #expect(bodyText(response) == #"{"path":null}"#)
        }
        #expect(api.settings.pickRequests == [.obsidianVault])
    }

    @Test("a chosen folder comes back as its path and is not saved by the pick itself")
    func pickFolderChosen() async throws {
        let api = SignedInAPI()
        api.settings.pickWillReturn(.success("/Users/test/Recordings"))
        try await api.run { client in
            let response = try await api.request(
                client, "/api/system/pick-folder", method: .post, json: #"{"setting":"outputDirectory"}"#)
            #expect(response.status == .ok)
            #expect(bodyText(response) == #"{"path":"/Users/test/Recordings"}"#)
        }
        #expect(api.settings.pickRequests == [.outputDirectory])
        api.settings.withManager { #expect($0.outputDirectory != "/Users/test/Recordings") }
    }

    @Test("an unknown setting is 400 and shows no panel; a second chooser is 409")
    func pickFolderRefusals() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let unknown = try await api.request(
                client, "/api/system/pick-folder", method: .post, json: #"{"setting":"home"}"#)
            try expectInvalid(unknown, mentioning: "outputDirectory, obsidianVault")
            let missing = try await api.request(client, "/api/system/pick-folder", method: .post)
            #expect(missing.status == .badRequest)
            #expect(api.settings.pickRequests.isEmpty)

            api.settings.pickWillReturn(.failure(.busy("A folder chooser is already open.")))
            let busy = try await api.request(
                client, "/api/system/pick-folder", method: .post, json: #"{"setting":"outputDirectory"}"#)
            #expect(busy.status == .conflict)
        }
    }
}
