import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

/// A live map with two topics (one nested), memos and turns, as the live meeting holds it.
enum LiveFixture {
    static func document(sessionID: String = "S1", audioPath: String = "/tmp/S1.wav", recording: Bool = true)
        -> ConversationDocument
    {
        var document = ConversationDocument()
        document.sessionID = sessionID
        document.title = "Weekly sync"
        document.audioPath = audioPath
        document.isRecording = recording
        document.turns = [
            LiveTurn(id: "t1", source: .system, start: 1, end: 2, text: "Can we ship Friday?", language: "en"),
            LiveTurn(id: "t2", source: .mic, start: 3, end: 4, text: "If staging is green.", language: "en"),
        ]
        document.arrivalTurnIDs = ["t1", "t2"]
        document.topics = [
            ConversationTopic(
                id: "release", title: "Release plan",
                memos: [LiveMemo(id: "m1", kind: .decision, text: "Ship Friday", turnIDs: ["t2"])],
                turnIDs: ["t1"]),
            ConversationTopic(id: "timing", parentID: "release", title: "Timing", turnIDs: ["t2"]),
        ]
        document.currentTopicID = "timing"
        document.liveNotesUsage = LiveNotesUsage(requests: 3, reportedCostUSD: 0.012)
        return document
    }

    /// A finished session whose `_live.json` sits beside its (absent) audio.
    static func savedSession(in dir: URL) throws -> Session {
        let audio = dir.appendingPathComponent("S2.wav").path
        try JSONEncoder().encode(document(sessionID: "S2", audioPath: audio, recording: false))
            .write(to: dir.appendingPathComponent("S2_live.json"))
        return Session(
            id: "S2", title: "Past sync", sourceApp: "Zoom", startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            audioPath: audio, status: "transcribed")
    }
}

@Suite struct LiveAPITests {
    private static func liveAPI() -> SignedInAPI {
        let api = SignedInAPI()
        api.backend.setLive(LiveFixture.document())
        return api
    }

    /// Every live POST, the body it sends and the one backend action it must cause.
    static let routes: [(String, String?, LiveAction)] = [
        ("/api/live/note", #"{"text":"Ask about rollback","kind":"question"}"#,
         .addNote(text: "Ask about rollback", kind: .question, topicID: nil)),
        ("/api/live/catch-up", nil, .catchUp),
        ("/api/live/back-to-live", nil, .backToLive),
        ("/api/live/notes-language", #"{"code":"uk"}"#, .setNotesLanguage("uk")),
        ("/api/live/topics", #"{"title":"Risks"}"#, .addTopic(title: "Risks", parentID: nil)),
        ("/api/live/topics/timing/select", nil, .selectTopic("timing")),
        ("/api/live/topics/timing/rename", #"{"title":"Schedule"}"#, .renameTopic("timing", title: "Schedule")),
        ("/api/live/topics/timing/move", #"{"parentID":null}"#, .moveTopic("timing", parentID: nil)),
        ("/api/live/topics/timing/merge", #"{"targetID":"release"}"#, .mergeTopic("timing", into: "release")),
        ("/api/live/topics/release/pin", #"{"pinned":true}"#, .pinTopic("release", pinned: true)),
        ("/api/live/memos/release/m1/edit", #"{"text":"Ship Monday"}"#,
         .editMemo(topicID: "release", memoID: "m1", text: "Ship Monday")),
        ("/api/live/memos/release/m1/pin", #"{"pinned":true}"#, .pinMemo(topicID: "release", memoID: "m1", pinned: true)),
        ("/api/live/export", nil, .export),
    ]

    @Test(arguments: routes)
    func liveActionsMap(path: String, json: String?, expected: LiveAction) async throws {
        let api = Self.liveAPI()
        try await api.run { client in
            let response = try await api.request(client, path, method: .post, json: json)
            #expect((200..<300).contains(response.status.code), "\(path): \(bodyText(response))")
        }
        let performed = api.backend.liveActions
        #expect(performed.count == 1, "\(path)")
        #expect(performed.first?.action == expected)
        #expect(performed.first?.target == .current)
    }

    @Test(arguments: [
        ("/api/live/topics/nope/rename", #"{"title":"X"}"#),
        ("/api/live/topics/nope/pin", #"{"pinned":true}"#),
        ("/api/live/topics/nope/select", nil),
        ("/api/live/topics/timing/merge", #"{"targetID":"nope"}"#),
        ("/api/live/topics/timing/move", #"{"parentID":"nope"}"#),
        ("/api/live/memos/release/nope/edit", #"{"text":"X"}"#),
        ("/api/live/memos/nope/m1/pin", #"{"pinned":false}"#),
        ("/api/live/note", #"{"text":"X","kind":"note","topicID":"nope"}"#),
    ])
    func unknownIDsAreNotFound(path: String, json: String?) async throws {
        let api = Self.liveAPI()
        try await api.run { client in
            let response = try await api.request(client, path, method: .post, json: json)
            #expect(response.status == .notFound, "\(path): \(bodyText(response))")
        }
        #expect(api.backend.liveActions.isEmpty)
    }

    @Test func noLiveMeetingIsAConflict() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let response = try await api.request(
                client, "/api/live/note", method: .post, json: #"{"text":"Hi","kind":"note"}"#)
            #expect(response.status == .conflict)
            #expect(try jsonObject(response)["error"] as? String == "no_live_meeting")
        }
        #expect(api.backend.liveActions.isEmpty)
    }

    @Test(arguments: [
        ("/api/live/note", #"{"text":"   ","kind":"note"}"#, "text"),
        ("/api/live/note", #"{"text":"Hi","kind":"shout"}"#, "kind"),
        ("/api/live/note", "{\"text\":\"\(String(repeating: "a", count: 2_001))\",\"kind\":\"note\"}", "text"),
        ("/api/live/topics/timing/rename", #"{"title":""}"#, "title"),
        ("/api/live/topics/timing/rename", "{\"title\":\"\(String(repeating: "a", count: 201))\"}", "title"),
        ("/api/live/memos/release/m1/edit", #"{"text":""}"#, "text"),
        ("/api/live/notes-language", #"{"code":"klingon"}"#, "code"),
        ("/api/live/topics/release/pin", #"{"pinned":"yes"}"#, "pinned"),
        ("/api/live/topics/timing/merge", #"{}"#, "targetID"),
        ("/api/live/topics", #"not json"#, "title"),
    ])
    func bodiesAreValidated(path: String, json: String, key: String) async throws {
        let api = Self.liveAPI()
        try await api.run { client in
            let response = try await api.request(client, path, method: .post, json: json)
            try expectInvalid(response, mentioning: key, key: key)
        }
        #expect(api.backend.liveActions.isEmpty)
    }

    @Test func refusedActionIsAConflictWithTheReason() async throws {
        let api = Self.liveAPI()
        try await api.run { client in
            // "release" is the parent of "timing": moving it under its child would make a cycle.
            let response = try await api.request(
                client, "/api/live/topics/release/move", method: .post, json: #"{"parentID":"timing"}"#)
            #expect(response.status == .conflict, "\(bodyText(response))")
            let body = try jsonObject(response)
            #expect(body["error"] as? String == "refused")
            #expect((body["message"] as? String)?.isEmpty == false)
        }
        #expect(api.backend.liveActions.isEmpty)
    }

    @Test func exportAnswersThePath() async throws {
        let api = Self.liveAPI()
        try await api.run { client in
            let response = try await api.request(client, "/api/live/export", method: .post)
            #expect(response.status == .ok)
            #expect(try jsonObject(response)["path"] as? String == "/tmp/Weekly-sync-live.md")
        }
    }

    @Test func liveIsInactiveWithoutAMeeting() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let response = try await api.request(client, "/api/live")
            #expect(response.status == .ok)
            #expect(bodyText(response) == #"{"active":false}"#)
        }
    }

    @Test func endedMeetingPointsAtItsSavedMap() async throws {
        let api = SignedInAPI()
        api.backend.setLive(LiveFixture.document(recording: false))
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/live"))
            #expect(body["active"] as? Bool == false)
            #expect(body["lastSessionID"] as? String == "S1")
        }
    }

    @Test func liveServesTheMapWithoutFilePaths() async throws {
        let api = Self.liveAPI()
        try await api.run { client in
            let response = try await api.request(client, "/api/live")
            let body = try jsonObject(response)
            #expect(body["active"] as? Bool == true)
            #expect(body["sessionID"] as? String == "S1")
            #expect(body["title"] as? String == "Weekly sync")
            #expect(body["currentTopicID"] as? String == "timing")
            #expect((body["topics"] as? [Any])?.count == 2)
            #expect((body["turns"] as? [Any])?.count == 2)
            #expect(jsonValue(body, "usage.requests") as? Int == 3)
            #expect(body["offlineMessage"] as? String == ConversationTopicService.offlineMessage)
            #expect(!bodyText(response).contains("/tmp/S1.wav"))
            #expect(body["audioPath"] == nil)
        }
    }

    @Test func savedMapIsServedAndEditable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let api = SignedInAPI(backend: FakeBackend(sessions: [try LiveFixture.savedSession(in: dir)]))
        try await api.run { client in
            let saved = try jsonObject(try await api.request(client, "/api/sessions/S2/live"))
            #expect(saved["active"] as? Bool == false)
            #expect(saved["sessionID"] as? String == "S2")
            #expect((saved["topics"] as? [Any])?.count == 2)

            let rename = try await api.request(
                client, "/api/sessions/S2/live/topics/timing/rename", method: .post, json: #"{"title":"When"}"#)
            #expect(rename.status == .noContent, "\(bodyText(rename))")
            let missing = try await api.request(client, "/api/sessions/NOPE/live")
            #expect(missing.status == .notFound)
        }
        #expect(api.backend.liveActions.map(\.target) == [.session("S2")])
        #expect(api.backend.liveActions.map(\.action) == [.renameTopic("timing", title: "When")])
    }

    @Test func sessionWithoutAMapIsNotFound() async throws {
        let session = Session(
            id: "S3", title: "No map", sourceApp: "Zoom", startedAt: Date(), audioPath: "/tmp/none-\(UUID()).wav",
            status: "transcribed")
        let api = SignedInAPI(backend: FakeBackend(sessions: [session]))
        try await api.run { client in
            #expect(try await api.request(client, "/api/sessions/S3/live").status == .notFound)
            let post = try await api.request(client, "/api/sessions/S3/live/catch-up", method: .post)
            #expect(post.status == .notFound)
        }
    }
}
