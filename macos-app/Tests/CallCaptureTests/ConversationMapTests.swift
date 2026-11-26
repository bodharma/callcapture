import Foundation
import Testing
@testable import CallCapture

@Suite("Conversation map evidence and editing")
@MainActor
struct ConversationMapTests {
    private func begin(_ model: LiveMeetingModel, directory: URL, notes: String = "en") throws {
        try model.begin(sessionID: "synthetic", title: "Synthetic meeting", audioPath: directory.appendingPathComponent("meeting.wav").path, speechLanguage: "en", notesLanguage: notes, configuration: .init(enabled: false, baseURL: URL(string: "https://example.invalid/v1")!, apiKey: "never-save-this", model: "synthetic"))
    }

    @Test("late turns remain ordered and duplicate IDs cannot replace original evidence")
    func dedupAndOrdering() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LiveMeetingModel()
        try begin(model, directory: directory)
        model.ingest(turn("later", 8, "Later", source: .system))
        model.ingest(turn("early", 1, "Earlier"))
        model.ingest(turn("later", 8, "Replacement", source: .system))
        #expect(model.document.turns.map(\.id) == ["early", "later"])
        #expect(model.document.turns.last?.text == "Later")
        #expect(model.document.topics.count == 1)
        #expect(Set(model.document.topics[0].turnIDs) == ["early", "later"])
    }

    @Test("browsing holds selection and catch-up uses arrival cursor including late evidence")
    func browsingAndCatchUp() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LiveMeetingModel()
        try begin(model, directory: directory)
        model.ingest(turn("one", 10, "First context"))
        let selected = try #require(model.document.currentTopicID)
        model.selectTopic(selected)
        model.ingest(turn("two", 20, "New test evidence"))
        model.ingest(turn("late", 2, "Arrived late"))
        model.catchUp()
        #expect(!model.followsLive)
        #expect(model.selectedTopicID == selected)
        #expect(model.catchUpText.contains("New test evidence"))
        #expect(model.catchUpText.contains("Arrived late"))
        #expect(!model.catchUpText.contains("First context"))
        model.backToLive()
        #expect(model.followsLive)
        #expect(model.selectedTopicID == model.document.currentTopicID)
    }

    @Test("manual text and pinned memo survive save/load and export never overwrites")
    func persistenceAndExport() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LiveMeetingModel()
        try begin(model, directory: directory)
        model.ingest(turn("one", 1, "Evidence with [link](https://example.invalid)"))
        model.addManualNote("  Моя думка\nKeep exact spaces  ", kind: .question)
        let topicID = try #require(model.selectedTopicID)
        let memoID = try #require(model.document.topics.first?.memos.first?.id)
        model.pinMemo(topicID: topicID, memoID: memoID)
        model.renameTopic(topicID, title: "../../Outside")
        model.end()
        let saved = directory.appendingPathComponent("meeting_live.json")
        let data = try Data(contentsOf: saved)
        #expect(!String(decoding: data, as: UTF8.self).contains("never-save-this"))
        let loaded = LiveMeetingModel()
        try loaded.load(audioPath: directory.appendingPathComponent("meeting.wav").path)
        #expect(loaded.document.turns.map(\.id) == ["one"])
        #expect(loaded.document.topics.first?.memos.first?.text == "  Моя думка\nKeep exact spaces  ")
        #expect(loaded.document.topics.first?.memos.first?.pinned == true)
        #expect(!loaded.document.isRecording)
        let first = try loaded.exportMarkdown(to: directory)
        let original = try Data(contentsOf: first)
        let second = try loaded.exportMarkdown(to: directory)
        #expect(first != second)
        #expect(first.deletingLastPathComponent().path == directory.path)
        #expect(try Data(contentsOf: first) == original)
        #expect(String(decoding: original, as: UTF8.self).contains("00:01"))
        #expect(String(decoding: original, as: UTF8.self).contains("Моя думка"))
    }

    @Test("adding a manual branch preserves the live context and rejects missing parents")
    func manualTopic() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LiveMeetingModel()
        try begin(model, directory: directory)
        model.ingest(turn("one", 1, "Current speech"))
        let liveID = model.document.currentTopicID
        model.addTopic(title: "My later question")
        let manualID = try #require(model.selectedTopicID)
        #expect(manualID != liveID)
        #expect(model.document.currentTopicID == liveID)
        #expect(!model.followsLive)
        model.addManualNote("Exact manual thought", kind: .question)
        #expect(model.document.topics.first { $0.id == manualID }?.memos.first?.text == "Exact manual thought")
        let count = model.document.topics.count
        model.addTopic(title: "Missing parent", parentID: "unknown")
        #expect(model.document.topics.count == count)
        #expect(model.error != nil)
        model.end()
        let loaded = LiveMeetingModel()
        try loaded.load(audioPath: directory.appendingPathComponent("meeting.wav").path)
        #expect(loaded.document.topics.contains { $0.id == manualID && $0.manualTitle && $0.manualParent })
    }

    @Test("starting an existing map never overwrites its saved evidence")
    func beginCollision() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = LiveMeetingModel()
        try begin(original, directory: directory)
        original.ingest(turn("one", 1, "Do not overwrite"))
        original.end()
        let path = directory.appendingPathComponent("meeting_live.json")
        let before = try Data(contentsOf: path)
        let another = LiveMeetingModel()
        #expect(throws: (any Error).self) { try begin(another, directory: directory) }
        #expect(try Data(contentsOf: path) == before)
    }

    @Test("unsupported or damaged saves leave the current map intact")
    func invalidSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LiveMeetingModel()
        try begin(model, directory: directory)
        model.ingest(turn("one", 1, "Keep me"))
        model.end()
        let path = directory.appendingPathComponent("meeting_live.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        #expect(throws: (any Error).self) { try model.load(audioPath: directory.appendingPathComponent("meeting.wav").path) }
        #expect(model.document.turns.first?.text == "Keep me")
    }
}

@MainActor
struct ConversationMapOwnershipTests {
    @Test("history sheet and original workspace share one writer; delayed analysis cannot overwrite edits")
    func singleWriterWithDelayedAnalysis() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = AsyncGate()
        let service = ConversationTopicService(transport: { request in
            await gate.wait()
            let body = """
            {"choices":[{"message":{"content":"{\\"schema_version\\":1,\\"notes_language\\":\\"en\\",\\"topics\\":[{\\"id\\":\\"discussion\\",\\"parent_id\\":null,\\"title\\":\\"Auto\\",\\"summary\\":\\"S\\",\\"turn_ids\\":[\\"one\\"],\\"memos\\":[]}],\\"current_topic_id\\":\\"discussion\\",\\"catch_up\\":null}"}}]}
            """
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let original = LiveMeetingModel(topicService: service, coalescingDelay: .milliseconds(1))
        let audio = directory.appendingPathComponent("meeting.wav").path
        try original.begin(sessionID: "s", title: "T", audioPath: audio, speechLanguage: "en", notesLanguage: "en",
                           configuration: .init(enabled: true, baseURL: URL(string: "https://example.invalid/v1")!, apiKey: "k", model: "m"))
        original.ingest(turn("one", 1, "Evidence"))
        original.end()
        let history = try LiveMeetingModel.opened(audioPath: audio)
        #expect(history === original)
        history.addManualNote("History edit", kind: .note)
        await gate.open()
        try await Task.sleep(for: .milliseconds(300))
        let reloaded = LiveMeetingModel()
        try reloaded.load(audioPath: audio)
        #expect(reloaded.document.topics.flatMap(\.memos).contains { $0.text == "History edit" })
        #expect(reloaded.document.turns.map(\.id) == ["one"])
    }

    @Test("one loaded instance is shared by independent openers of a stopped map")
    func sharedLoad() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("meeting.wav").path
        weak var released: LiveMeetingModel?
        do {
            let writer = LiveMeetingModel()
            released = writer
            try writer.begin(sessionID: "s", title: "T", audioPath: audio, speechLanguage: "en", notesLanguage: "en", configuration: .init(enabled: false, baseURL: URL(string: "https://example.invalid/v1")!, apiKey: "", model: ""))
            writer.ingest(turn("one", 1, "x")); writer.end()
        }
        #expect(released == nil, "writer must be released so opened() exercises load()")
        let a = try LiveMeetingModel.opened(audioPath: audio)
        let b = try LiveMeetingModel.opened(audioPath: audio)
        #expect(a === b)
        #expect(a.document.turns.map(\.id) == ["one"])
    }

    @Test("oversized finite offsets are rejected on load and format safely")
    func hugeOffsets() throws {
        #expect(LiveMeetingModel.timestamp(1e300) == LiveMeetingModel.timestamp(LiveMeetingModel.maxOffsetSeconds))
        #expect(LiveMeetingModel.timestamp(.infinity) == "00:00")
        #expect(LiveMeetingModel.timestamp(.nan) == "00:00")
        #expect(LiveMeetingModel.timestamp(-5) == "00:00")
        #expect(LiveMeetingModel.timestamp(3725) == "01:02:05")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("meeting.wav").path
        let model = LiveMeetingModel()
        try model.begin(sessionID: "s", title: "T", audioPath: audio, speechLanguage: "en", notesLanguage: "en", configuration: .init(enabled: false, baseURL: URL(string: "https://example.invalid/v1")!, apiKey: "", model: ""))
        model.ingest(LiveTurn(id: "huge", source: .mic, start: 1e300, end: 1e300, text: "x", language: nil))
        #expect(model.document.turns.isEmpty)
        model.ingest(turn("ok", 604_799, "edge"))
        #expect(model.document.turns.count == 1)
        model.end()
        let path = directory.appendingPathComponent("meeting_live.json")
        var text = try String(contentsOf: path, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"end\":604800", with: "\"end\":1e300")
        try text.write(to: path, atomically: true, encoding: .utf8)
        let loaded = LiveMeetingModel()
        #expect(throws: (any Error).self) { try loaded.load(audioPath: audio) }
        #expect(throws: (any Error).self) { try LiveWorkerEvent.parse(Data(#"{"type":"turn","id":"x","source":"mic","start":0,"end":1e300,"text":"x","final":true}"#.utf8)) }
        #expect(!LivePCMBuffer().offer(samples: [0], source: .mic, start: 1e300))
    }

    @Test("unresolved Auto notes language can be chosen once and manual notes are untouched")
    func notesLanguage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LiveMeetingModel()
        try model.begin(sessionID: "s", title: "T", audioPath: directory.appendingPathComponent("m.wav").path, speechLanguage: "auto", notesLanguage: "auto", configuration: .init(enabled: false, baseURL: URL(string: "https://example.invalid/v1")!, apiKey: "", model: ""))
        model.addManualNote("Keep", kind: .note)
        #expect(model.document.resolvedNotesLanguage == nil)
        model.setNotesLanguage("klingon")
        #expect(model.document.resolvedNotesLanguage == nil)
        model.setNotesLanguage("uk")
        #expect(model.document.resolvedNotesLanguage == "uk")
        model.setNotesLanguage("en")
        #expect(model.document.resolvedNotesLanguage == "uk")
        #expect(model.document.topics.flatMap(\.memos).map(\.text) == ["Keep"])
    }
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if isOpen { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}

func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-map-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func turn(_ id: String, _ start: Double, _ text: String, source: LiveAudioSource = .mic, language: String? = "en") -> LiveTurn {
    LiveTurn(id: id, source: source, start: start, end: start + 1, text: text, language: language)
}
