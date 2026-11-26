import Foundation
import Testing
@testable import CallCapture

@Suite("Conversation topic provider boundary")
@MainActor
struct ConversationTopicServiceTests {
    @Test("timing testing timing reuses one topic with two visits and preserves manual corrections")
    func recurringTopicAndManualEdits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = TopicTransport(responses: [response(topics: [topic("timing", "Timing", ["one", "three"]), topic("testing", "Testing", ["two"])], current: "timing"), response(topics: [topic("timing", "Rewritten", ["four"], memoText: "Overwrite attempt")], current: "timing")])
        let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .milliseconds(5))
        try start(model, directory: directory)
        model.ingest(turn("one", 1, "Timing first"))
        model.ingest(turn("two", 4, "Testing"))
        model.ingest(turn("three", 8, "Timing again"))
        try await eventually { model.document.topics.contains { $0.id == "timing" } }
        #expect(model.document.topics.filter { $0.id == "timing" }.count == 1)
        #expect(model.document.topics.first { $0.id == "timing" }?.visits.map(\.turnIDs) == [["one"], ["three"]])
        model.selectTopic("testing")
        model.renameTopic("timing", title: "My timing")
        model.selectTopic("timing")
        model.addManualNote("Мій власний текст", kind: .note)
        model.editMemo(topicID: "timing", memoID: "timing-memo", text: "Edited decision")
        model.pinMemo(topicID: "timing", memoID: "timing-memo")
        model.pinTopic("timing")
        model.selectTopic("testing")
        model.ingest(turn("four", 12, "More timing"))
        try await eventually { model.document.topics.first { $0.id == "timing" }?.turnIDs.contains("four") == true }
        let timing = try #require(model.document.topics.first { $0.id == "timing" })
        #expect(timing.title == "My timing")
        #expect(timing.memos.contains { $0.text == "Мій власний текст" && $0.manual })
        #expect(timing.memos.first { $0.id == "timing-memo" }?.text == "Edited decision")
        #expect(timing.memos.first { $0.id == "timing-memo" }?.turnIDs == ["one", "three"])
        #expect(timing.memos.contains { !$0.manual && !$0.pinned && $0.text == "Overwrite attempt" && $0.turnIDs == ["four"] })
        #expect(model.selectedTopicID == "testing")
        #expect(model.document.currentTopicID == "timing")
        #expect(!model.followsLive)
        model.end()
    }

    @Test("invalid source references and parent cycles reject the entire provider update")
    func invalidProviderUpdates() async throws {
        for invalid in [response(topics: [topic("x", "Invented", ["unknown"])], current: "x"), response(topics: [topic("x", "Cycle", ["one"], parent: "y"), topic("y", "Cycle", ["one"], parent: "x")], current: "x")] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = TopicTransport(responses: [invalid])
            let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .zero)
            try start(model, directory: directory)
            model.ingest(turn("one", 1, "Real evidence"))
            try await eventually { model.error != nil }
            #expect(model.document.topics.allSatisfy { $0.id != "x" && $0.id != "y" })
            #expect(model.document.turns.first?.text == "Real evidence")
            model.addManualNote("Still usable", kind: .note)
            #expect(model.document.topics.contains { $0.memos.contains { $0.text == "Still usable" } })
            model.end()
        }
    }

    @Test("manual moves prevent cycles and merges preserve all notes and source evidence")
    func movesAndMerges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = TopicTransport(responses: [response(topics: [topic("timing", "Timing", ["one"]), topic("testing", "Testing", ["two"])], current: "testing")])
        let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .zero)
        try start(model, directory: directory)
        model.ingest(turn("one", 1, "Timing"))
        model.ingest(turn("two", 4, "Testing"))
        try await eventually { model.document.topics.contains { $0.id == "testing" } }
        model.moveTopic("testing", parentID: "timing")
        model.moveTopic("timing", parentID: "testing")
        #expect(model.error != nil)
        #expect(model.document.topics.first { $0.id == "timing" }?.parentID == nil)
        model.selectTopic("testing")
        model.addManualNote("Keep merged note", kind: .question)
        model.mergeTopic("timing", into: "testing")
        #expect(model.error != nil) // A parent cannot be merged into its descendant.
        #expect(model.document.topics.contains { $0.id == "timing" })
        model.moveTopic("testing", parentID: nil)
        model.mergeTopic("testing", into: "timing")
        #expect(!model.document.topics.contains { $0.id == "testing" })
        let timing = try #require(model.document.topics.first { $0.id == "timing" })
        #expect(Set(timing.turnIDs) == ["one", "two"])
        #expect(timing.memos.contains { $0.text == "Keep merged note" })
        #expect(model.document.turns.count == 2)
        #expect(model.selectedTopicID == "timing")
        model.end()
    }

    @Test("automatic notes coalesce queued turns without concurrent requests")
    func coalescing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = TopicTransport(responses: [response(topics: [topic("work", "Work", ["one", "two", "three"])], current: "work")], delay: .milliseconds(20))
        let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .milliseconds(15))
        try start(model, directory: directory)
        model.ingest(turn("one", 1, "First"))
        model.ingest(turn("two", 2, "Second"))
        model.ingest(turn("three", 3, "Third"))
        try await eventually { model.document.topics.contains { $0.id == "work" } }
        #expect(await fixture.requestCount == 1)
        #expect(await fixture.maximumConcurrent == 1)
        let request = try #require(await fixture.requests.first)
        let body = try #require(request.httpBody)
        #expect(String(decoding: body, as: UTF8.self).contains("uk"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ephemeral-key")
        model.end()
    }

    @Test("Auto waits for detected language then holds it across mixed speech")
    func notesLanguage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = TopicTransport(responses: [response(topics: [topic("work", "Робота", ["unknown", "uk", "en"])], current: "work")])
        let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .milliseconds(10))
        try start(model, directory: directory, speech: "auto", notes: "auto")
        model.ingest(turn("unknown", 0, "Unknown", language: nil))
        #expect(model.document.resolvedNotesLanguage == nil)
        #expect(model.status.contains("language"))
        model.ingest(turn("uk", 1, "Українська", language: "uk"))
        model.ingest(turn("en", 2, "English", language: "en"))
        try await eventually { model.document.topics.contains { $0.id == "work" } }
        #expect(model.document.resolvedNotesLanguage == "uk")
        #expect(model.document.turns.map(\.text) == ["Unknown", "Українська", "English"])
        model.end()
    }

    @Test("provider failures and missing configuration leave evidence and manual notes usable")
    func failClosed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = TopicTransport(responses: [Data("not JSON".utf8)])
        let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .zero)
        try start(model, directory: directory)
        model.ingest(turn("one", 1, "Keep original"))
        try await eventually { model.error != nil }
        model.addManualNote("Keep manual", kind: .note)
        #expect(model.document.turns.first?.text == "Keep original")
        #expect(model.document.topics.contains { $0.memos.contains { $0.text == "Keep manual" } })
        model.end()
        let missing = LiveMeetingModel()
        try missing.begin(sessionID: "missing", title: "No model", audioPath: directory.appendingPathComponent("missing.wav").path, speechLanguage: "en", notesLanguage: "en", configuration: .init(enabled: true, baseURL: URL(string: "https://example.invalid")!, apiKey: "", model: ""))
        #expect(missing.error != nil)
        missing.ingest(turn("two", 2, "Still recording"))
        #expect(missing.document.turns.count == 1)
        missing.end()
    }

    @Test("new arrivals during inference retain their own watermark and are processed next")
    func inFlightWatermark() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = TopicTransport(responses: [response(topics: [topic("first", "Перша", ["one"])], current: "first"), response(topics: [topic("second", "Друга", ["two"])], current: "second")], delay: .milliseconds(50))
        let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .zero)
        try start(model, directory: directory)
        model.ingest(turn("one", 1, "First"))
        try await eventually { await fixture.requestCount == 1 }
        model.ingest(turn("two", 10, "Second"))
        try await eventually { model.document.topics.contains { $0.id == "first" } }
        #expect(model.mappedThroughSeconds == 2)
        #expect(model.document.currentTopicID != "first")
        try await eventually { model.document.topics.contains { $0.id == "second" } }
        #expect(model.mappedThroughSeconds == 11)
        #expect(await fixture.requestCount == 2)
        #expect(await fixture.maximumConcurrent == 1)
        model.end()
    }

    @Test("wrong output language and omitted pending evidence fail without false mapping progress")
    func schemaAndCoverage() async throws {
        for invalid in [response(topics: [], current: "unknown"), response(topics: [topic("topic", "Wrong language", ["one"])], current: "topic", language: "en")] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = TopicTransport(responses: [invalid])
            let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .zero)
            try start(model, directory: directory)
            model.ingest(turn("one", 1, "Original"))
            try await eventually { model.error != nil }
            #expect(model.mappedThroughSeconds == nil)
            #expect(model.document.turns.first?.text == "Original")
            #expect(await fixture.requestCount == 1)
            model.end()
        }
    }

    @Test("catch-up uses requested evidence and chosen notes language without editing source speech")
    func generatedCatchUp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = TopicTransport(responses: [response(topics: [topic("first", "Перша", ["one"])], current: "first"), response(topics: [topic("next", "Наступна", ["two"])], current: "next", catchUp: ["text": "Обговорили наступне питання.", "turn_ids": ["two"]])])
        let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .milliseconds(15))
        try start(model, directory: directory)
        model.ingest(turn("one", 1, "First original"))
        try await eventually { model.document.topics.contains { $0.id == "first" } }
        model.selectTopic("first")
        model.ingest(turn("two", 3, "Second original"))
        model.catchUp()
        try await eventually { model.catchUpText == "Обговорили наступне питання." }
        #expect(model.selectedTopicID == "first")
        #expect(model.document.turns.last?.text == "Second original")
        model.end()
    }

    @Test("each request asks for usage accounting and records tokens and reported cost")
    func usageRecorded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = TopicTransport(responses: [response(topics: [topic("work", "Робота", ["one"])], current: "work",
                                                          usage: ["prompt_tokens": 1200, "completion_tokens": 300, "cost": 0.0042])])
        let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .milliseconds(5))
        try start(model, directory: directory)
        model.ingest(turn("one", 1, "Перше"))
        try await eventually { model.document.liveNotesUsage != nil }
        #expect(model.document.liveNotesUsage == LiveNotesUsage(requests: 1, promptTokens: 1200, completionTokens: 300,
                                                                reportedCostUSD: 0.0042, unpricedRequests: 0))
        let body = try #require(await fixture.requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["usage"] as? [String: Any])?["include"] as? Bool == true)
        model.end()
    }

    @Test("a response without a reported cost counts as an unpriced request")
    func unpricedCounted() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = TopicTransport(responses: [response(topics: [topic("work", "Робота", ["one"])], current: "work",
                                                          usage: ["prompt_tokens": 900, "completion_tokens": 100])])
        let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .milliseconds(5))
        try start(model, directory: directory)
        model.ingest(turn("one", 1, "Перше"))
        try await eventually { model.document.liveNotesUsage != nil }
        #expect(model.document.liveNotesUsage?.unpricedRequests == 1)
        #expect(model.document.liveNotesUsage?.reportedCostUSD == 0)
        model.end()
    }

    @Test("live maps saved before usage tracking still load")
    func oldDocumentLoads() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConversationDocument())) as? [String: Any])
        json.removeValue(forKey: "liveNotesUsage")
        let decoded = try JSONDecoder().decode(ConversationDocument.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.liveNotesUsage == nil)
    }

    @Test("going offline pauses automatic notes with a clear message and no retry loop")
    func offlinePausesWithoutRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = TopicTransport(responses: [], failure: URLError(.notConnectedToInternet))
        let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .milliseconds(5))
        try start(model, directory: directory)
        model.ingest(turn("one", 1, "Перше"))
        try await eventually { model.error != nil }
        #expect(model.error == "Automatic notes paused: offline. Transcript and manual notes continue.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fixture.requestCount == 1)
        #expect(model.document.turns.count == 1)
        model.end()
    }

    @Test("a live model OpenRouter no longer lists is refused before any request")
    func unlistedModelRefused() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = TopicTransport(responses: [])
        let model = LiveMeetingModel(topicService: .init(transport: { try await fixture.send($0) }), coalescingDelay: .milliseconds(5))
        try start(model, directory: directory, listedModelIDs: ["anthropic/claude-haiku-5.5"])
        #expect(model.error == "gone/model is no longer offered by OpenRouter. Choose another live notes model in Settings.")
        model.ingest(turn("one", 1, "Перше"))
        try await Task.sleep(for: .milliseconds(60))
        #expect(await fixture.requestCount == 0)
        model.end()
    }

    private func start(_ model: LiveMeetingModel, directory: URL, speech: String = "en", notes: String = "uk",
                       listedModelIDs: Set<String>? = nil) throws {
        if let listedModelIDs {
            try model.begin(sessionID: "synthetic", title: "Synthetic", audioPath: directory.appendingPathComponent("meeting.wav").path,
                            speechLanguage: speech, notesLanguage: notes,
                            configuration: .init(enabled: true, baseURL: URL(string: "https://llm.invalid/v1")!, apiKey: "test-key",
                                                 model: "gone/model", listedModelIDs: listedModelIDs))
            return
        }
        try model.begin(sessionID: "synthetic", title: "Synthetic", audioPath: directory.appendingPathComponent("meeting.wav").path, speechLanguage: speech, notesLanguage: notes, configuration: .init(enabled: true, baseURL: URL(string: "https://example.invalid/v1")!, apiKey: "ephemeral-key", model: "fixture-model"))
    }
}

private actor TopicTransport {
    var responses: [Data]
    var requests: [URLRequest] = []
    var active = 0
    var maximumConcurrent = 0
    let delay: Duration
    let failure: URLError?
    var requestCount: Int { requests.count }
    init(responses: [Data], delay: Duration = .zero, failure: URLError? = nil) {
        self.responses = responses; self.delay = delay; self.failure = failure
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        let data = responses.isEmpty ? Data("unexpected request".utf8) : responses.removeFirst()
        try await Task.sleep(for: delay)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func topic(_ id: String, _ title: String, _ turns: [String], parent: String? = nil, memoText: String = "Підтверджена думка") -> [String: Any] {
    ["id": id, "title": title, "parent_id": parent as Any? ?? NSNull(), "summary": "Коротко", "turn_ids": turns, "memos": [["id": "\(id)-memo", "kind": "idea", "text": memoText, "turn_ids": turns]]]
}

private func response(topics: [[String: Any]], current: String, language: String = "uk", catchUp: [String: Any]? = nil,
                      usage: [String: Any]? = nil) -> Data {
    let content: [String: Any] = ["schema_version": 1, "notes_language": language, "topics": topics, "current_topic_id": current, "catch_up": catchUp as Any? ?? NSNull()]
    let text = String(decoding: try! JSONSerialization.data(withJSONObject: content), as: UTF8.self)
    var envelope: [String: Any] = ["choices": [["message": ["content": text]]]]
    if let usage { envelope["usage"] = usage }
    return try! JSONSerialization.data(withJSONObject: envelope)
}

@MainActor private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await condition())
}
