import Foundation
import Testing
@testable import CallCapture

private let modelsJSON = """
{"data": [
 {"id": "anthropic/claude-haiku-5.5", "canonical_slug": "anthropic/claude-haiku-5.5-20261001",
  "name": "Anthropic: Claude Haiku 5.5", "context_length": 1000000,
  "pricing": {"prompt": "0.0000001", "completion": "0.0000005"},
  "supported_parameters": ["temperature", "response_format"]},
 {"id": "google/gemini-2.5-flash", "canonical_slug": "google/gemini-2.5-flash",
  "name": "Google: Gemini 2.5 Flash", "context_length": 1048576,
  "pricing": {"prompt": "0.0000003", "completion": "0.0000025"},
  "supported_parameters": ["structured_outputs"]},
 {"id": "meta/llama-free:free", "name": "Meta: Llama (free)", "context_length": 8192,
  "pricing": {"prompt": "0", "completion": "0"}, "supported_parameters": ["temperature"]},
 {"id": "openrouter/auto", "name": "Auto Router", "context_length": 2000000,
  "pricing": {"prompt": "-1", "completion": "-1"}, "supported_parameters": ["response_format"]},
 {"id": "broken/no-pricing", "name": "No pricing", "context_length": 4096}
]}
"""

/// The documented OpenRouter Data API sample shape (source=artificial-analysis).
private let benchmarksJSON = """
{"data": [
 {"source": "artificial-analysis", "model_permaslug": "anthropic/claude-haiku-5.5-20261001",
  "display_name": "Claude Haiku 5.5", "intelligence_index": 54.2, "multilingual_index": 0.81,
  "strategy_and_ops_index": 48.0, "coding_index": null},
 {"source": "artificial-analysis", "model_permaslug": "google/gemini-2.5-flash",
  "display_name": "Gemini 2.5 Flash", "intelligence_index": 51.0, "multilingual_index": 0.84,
  "strategy_and_ops_index": null},
 {"source": "artificial-analysis", "model_permaslug": "unknown/model",
  "display_name": "Unlisted", "intelligence_index": 70.0, "multilingual_index": 0.9,
  "strategy_and_ops_index": 60.0}
],
"meta": {"as_of": "2026-11-20T12:00:00.000Z", "source": "artificial-analysis",
 "citation": "Source: Artificial Analysis (artificialanalysis.ai) via OpenRouter (openrouter.ai/rankings)."}}
"""

/// Fake OpenRouter: answers by path, records every request.
private final class FakeOpenRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var modelsResponse: Result<(Int, String), Error> = .success((200, modelsJSON))
    var benchmarksResponse: Result<(Int, String), Error> = .success((200, benchmarksJSON))

    var requests: [URLRequest] { lock.withLock { recorded } }

    var transport: ModelCatalogService.Transport {
        { [self] request in
            lock.withLock { recorded.append(request) }
            let result = request.url?.path.hasSuffix("/benchmarks") == true ? benchmarksResponse : modelsResponse
            let (status, body) = try result.get()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_795_000_000)
}

@Suite("Model catalog")
struct ModelCatalogTests {
    private func setup() -> (ModelCatalogService, FakeOpenRouter, Clock, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-catalog-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = dir.appendingPathComponent("model-catalog.json")
        let fake = FakeOpenRouter()
        let clock = Clock()
        let service = ModelCatalogService(cacheURL: cache, transport: fake.transport, now: { clock.now })
        return (service, fake, clock, cache)
    }

    @Test("decodes prices and JSON support; drops routers and unpriced models; keeps free ones")
    func decodesModels() async throws {
        let (service, _, _, _) = setup()
        let snapshot = try await service.refresh(apiKey: "key", force: true)
        #expect(snapshot.models.map(\.id) == ["anthropic/claude-haiku-5.5", "google/gemini-2.5-flash", "meta/llama-free:free"])
        let haiku = try #require(snapshot.model(id: "anthropic/claude-haiku-5.5"))
        #expect(haiku.promptPricePerToken == 0.0000001)
        #expect(haiku.completionPricePerToken == 0.0000005)
        #expect(haiku.contextLength == 1_000_000)
        #expect(haiku.supportsJSON)
        #expect(haiku.name == "Anthropic: Claude Haiku 5.5")
        #expect(snapshot.model(id: "google/gemini-2.5-flash")?.supportsJSON == true)
        let free = try #require(snapshot.model(id: "meta/llama-free:free"))
        #expect(free.promptPricePerToken == 0 && !free.supportsJSON)
    }

    @Test("joins scores by canonical slug, then id; unmatched permaslugs set nothing")
    func joinsScores() async throws {
        let (service, fake, _, _) = setup()
        let snapshot = try await service.refresh(apiKey: "key", force: true)
        #expect(snapshot.model(id: "anthropic/claude-haiku-5.5")?.scores
                == ModelScores(intelligence: 54.2, multilingual: 0.81, strategyAndOps: 48.0))
        #expect(snapshot.model(id: "google/gemini-2.5-flash")?.scores
                == ModelScores(intelligence: 51.0, multilingual: 0.84, strategyAndOps: nil))
        #expect(snapshot.model(id: "meta/llama-free:free")?.scores == nil)
        #expect(snapshot.scoresCitation?.hasPrefix("Source: Artificial Analysis") == true)
        #expect(snapshot.scoresProblem == nil)
        let benchmarks = try #require(fake.requests.first { $0.url?.path.hasSuffix("/benchmarks") == true })
        #expect(benchmarks.value(forHTTPHeaderField: "Authorization") == "Bearer key")
        let models = try #require(fake.requests.first { $0.url?.path.hasSuffix("/models") == true })
        #expect(models.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("a fresh cache makes no requests unless forced")
    func freshCacheSkipsNetwork() async throws {
        let (service, fake, clock, _) = setup()
        _ = try await service.refresh(apiKey: "key", force: true)
        #expect(fake.requests.count == 2)
        clock.now += 3600
        _ = try await service.refresh(apiKey: "key", force: false)
        #expect(fake.requests.count == 2)
        _ = try await service.refresh(apiKey: "key", force: true)
        #expect(fake.requests.count == 4)
        clock.now += ModelCatalogService.maxAge + 1
        _ = try await service.refresh(apiKey: "key", force: false)
        #expect(fake.requests.count == 6)
    }

    @Test("score failures keep the model list and the previous scores, with one reason")
    func scoresFailureKeepsModels() async throws {
        let (service, fake, _, _) = setup()
        fake.benchmarksResponse = .success((401, "{}"))
        var snapshot = try await service.refresh(apiKey: "bad", force: true)
        #expect(snapshot.models.count == 3)
        #expect(snapshot.model(id: "anthropic/claude-haiku-5.5")?.scores == nil)
        #expect(snapshot.scoresProblem == "Scores need a valid OpenRouter key.")

        fake.benchmarksResponse = .success((200, benchmarksJSON))
        _ = try await service.refresh(apiKey: "key", force: true)
        fake.benchmarksResponse = .success((429, "{}"))
        snapshot = try await service.refresh(apiKey: "key", force: true)
        #expect(snapshot.model(id: "anthropic/claude-haiku-5.5")?.scores?.intelligence == 54.2)
        #expect(snapshot.scoresProblem == "Scores are rate-limited; try later.")

        snapshot = try await service.refresh(apiKey: "", force: true)
        #expect(snapshot.scoresProblem == "Scores need an OpenRouter key.")
        #expect(snapshot.model(id: "anthropic/claude-haiku-5.5")?.scores?.intelligence == 54.2)
    }

    @Test("an offline model fetch throws .offline and leaves the cache untouched")
    func modelsFailureThrows() async throws {
        let (service, fake, _, cache) = setup()
        _ = try await service.refresh(apiKey: "key", force: true)
        let before = try Data(contentsOf: cache)
        fake.modelsResponse = .failure(URLError(.notConnectedToInternet))
        await #expect(throws: ModelCatalogError.offline) { try await service.refresh(apiKey: "key", force: true) }
        fake.modelsResponse = .success((503, "busy"))
        await #expect(throws: ModelCatalogError.http(503)) { try await service.refresh(apiKey: "key", force: true) }
        #expect(try Data(contentsOf: cache) == before)
        #expect(service.cached()?.models.count == 3)
    }

    @Test("a corrupt cache file is ignored")
    func corruptCacheIsIgnored() throws {
        let (service, _, _, cache) = setup()
        try Data("not json".utf8).write(to: cache)
        #expect(service.cached() == nil)
    }
}
