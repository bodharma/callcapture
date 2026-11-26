import Foundation
import Testing

@testable import CallCapture

/// `LiveAction.apply` calls the matching `LiveMeetingModel` method on a real model.
@MainActor
@Suite struct LiveActionTests {
    private let dir: URL
    private let model = LiveMeetingModel()
    private let releaseID: String
    private let discussionID: String

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-live-action-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try model.begin(
            sessionID: "S1", title: "Weekly sync", audioPath: dir.appendingPathComponent("S1.wav").path,
            speechLanguage: "en", notesLanguage: "auto",
            configuration: LiveNotesConfiguration(
                enabled: false, baseURL: URL(string: "http://127.0.0.1:1")!, apiKey: "", model: ""))
        model.ingest(LiveTurn(id: "t1", source: .system, start: 1, end: 2, text: "Can we ship?", language: "en"))
        model.addTopic(title: "Release")
        releaseID = try #require(model.document.topics.first { $0.title == "Release" }).id
        discussionID = try #require(model.document.topics.first { $0.isUnassigned }).id
        model.backToLive()
    }

    private var release: ConversationTopic { model.document.topics.first { $0.id == releaseID }! }
    private var discussion: ConversationTopic { model.document.topics.first { $0.id == discussionID }! }

    private func run(_ action: LiveAction) throws {
        if let problem = action.problem(in: model.document) { throw problem }
        try action.apply(to: model)
    }

    @Test func noteGoesToTheChosenTopic() throws {
        try run(.addNote(text: "Ask about rollback", kind: .question, topicID: release.id))
        #expect(release.memos.map(\.text) == ["Ask about rollback"])
        #expect(release.memos.first?.manual == true)
        #expect(release.memos.first?.kind == .question)
    }

    @Test func topicEdits() throws {
        try run(.renameTopic(release.id, title: "Release plan"))
        #expect(release.title == "Release plan")
        try run(.moveTopic(release.id, parentID: discussion.id))
        #expect(release.parentID == discussion.id)
        try run(.pinTopic(release.id, pinned: true))
        #expect(release.pinned)
        try run(.pinTopic(release.id, pinned: true))
        #expect(release.pinned, "pinning a pinned topic leaves it pinned")
        try run(.pinTopic(release.id, pinned: false))
        #expect(!release.pinned)
    }

    @Test func mergeFoldsOneTopicIntoAnother() throws {
        let source = release.id
        try run(.mergeTopic(source, into: discussion.id))
        #expect(!model.document.topics.contains { $0.id == source })
        #expect(model.document.mergedTopicIDs[source] == discussion.id)
    }

    @Test func addAndSelectTopics() throws {
        try run(.addTopic(title: "Risks", parentID: release.id))
        let risks = try #require(model.document.topics.first { $0.title == "Risks" })
        #expect(risks.parentID == release.id)
        try run(.backToLive)
        #expect(model.followsLive)
        try run(.selectTopic(release.id))
        #expect(model.selectedTopicID == release.id)
        #expect(!model.followsLive)
        try run(.catchUp)
        #expect(model.catchUpText == "No new committed speech.")
    }

    @Test func memoEdits() throws {
        try run(.addNote(text: "Draft", kind: .note, topicID: release.id))
        let memo = try #require(release.memos.first)
        try run(.editMemo(topicID: release.id, memoID: memo.id, text: "Final"))
        #expect(release.memos.first?.text == "Final")
        try run(.pinMemo(topicID: release.id, memoID: memo.id, pinned: true))
        #expect(release.memos.first?.pinned == true)
    }

    @Test func notesLanguageOnlyWhileUnresolved() throws {
        // The fixture speaks English with Auto notes, so the language is already resolved.
        #expect(LiveAction.setNotesLanguage("uk").problem(in: model.document) != nil)
        var unresolved = model.document
        unresolved.resolvedNotesLanguage = nil
        #expect(LiveAction.setNotesLanguage("uk").problem(in: unresolved) == nil)
        #expect(LiveAction.setNotesLanguage("xx").problem(in: unresolved) != nil)
    }

    @Test func cyclesAndSelfMergesAreRefused() {
        let document = LiveFixture.document()
        if case .refused = LiveAction.moveTopic("release", parentID: "timing").problem(in: document) {} else {
            Issue.record("moving a parent under its child must be refused")
        }
        if case .refused = LiveAction.moveTopic("release", parentID: "release").problem(in: document) {} else {
            Issue.record("a topic can't be its own parent")
        }
        if case .refused = LiveAction.mergeTopic("release", into: "timing").problem(in: document) {} else {
            Issue.record("merging a parent into its child must be refused")
        }
        if case .refused = LiveAction.mergeTopic("timing", into: "timing").problem(in: document) {} else {
            Issue.record("merging a topic into itself must be refused")
        }
        #expect(LiveAction.mergeTopic("timing", into: "release").problem(in: document) == nil)
        #expect(LiveAction.moveTopic("timing", parentID: nil).problem(in: document) == nil)
    }

    @Test func unknownIDsAreNotFound() {
        let document = LiveFixture.document()
        #expect(LiveAction.renameTopic("nope", title: "X").problem(in: document) == .notFound)
        #expect(LiveAction.editMemo(topicID: "release", memoID: "nope", text: "X").problem(in: document) == .notFound)
        #expect(LiveAction.addTopic(title: "X", parentID: "nope").problem(in: document) == .notFound)
        #expect(LiveAction.addNote(text: "X", kind: .note, topicID: "nope").problem(in: document) == .notFound)
    }

    @Test func modelRefusalIsReported() throws {
        // Bypass validation: the model's own check still refuses, and that must surface.
        let child = try #require(model.document.topics.first { $0.id != release.id })
        try LiveAction.moveTopic(child.id, parentID: release.id).apply(to: model)
        #expect(throws: LiveActionError.self) {
            try LiveAction.moveTopic(release.id, parentID: child.id).apply(to: model)
        }
    }
}
