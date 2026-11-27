import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

private let port = 54321
private let authority = "127.0.0.1:\(port)"
private let ownOrigin = "http://127.0.0.1:\(port)"

/// One processed session in a throwaway directory: a 3 s sine WAV (larger than
/// one 64 KB read chunk), a transcript, a note, an analysis and a live map.
private struct Fixture: Sendable {
    static let id = "S1"
    static let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
    static let transcriptJSON = """
        [{"start":0.0,"end":1.5,"text":"Hello there","speaker":"Speaker 1"},
         {"start":1.5,"end":3.0,"text":"Hi, the budget is fine","speaker":"You"},
         {"start":3.0,"end":3.5,"text":"Ambient noise","speaker":null}]
        """
    static let noteMarkdown = "# Weekly sync\n\n**Speaker 1:** Hello there\n**You:** Hi\n"
    static let analysisJSON = """
        {"recording_type":"call_meeting","num_speakers":2,
         "speakers":[{"label":"Speaker 1","is_self":false,"talk_ratio":0.6},
                     {"label":"You","is_self":true,"talk_ratio":0.4}],
         "warnings":["Short call"],
         "sentiment":{"overall":"positive","overall_score":0.4,"by_speaker":{},
                      "arc":[{"t":0,"score":0.1},{"t":2,"score":0.3}]},
         "insights":{"title":"Sync","summary":"Speaker 1 led.","key_points":["Budget"],
                     "action_items":["Speaker 1 sends notes"]}}
        """

    let dir: URL
    let session: Session
    let backend: FakeBackend
    let security: ServerSecurity
    let cookie: String

    var audioPath: String { session.audioPath }

    init(title: String = "Weekly sync", liveMap: Bool = true, note: Bool = true) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent(Self.id).path
        let audio = base + ".wav"
        try SyntheticAudio.writeSine(to: URL(fileURLWithPath: audio), seconds: 3)
        try Self.write(Self.transcriptJSON, to: base + "_transcript.json")
        if note { try Self.write(Self.noteMarkdown, to: base + "_notes.md") }
        try Self.write(Self.analysisJSON, to: base + "_analysis.json")
        if liveMap {
            try JSONEncoder().encode(Self.liveDocument(audioPath: audio))
                .write(to: URL(fileURLWithPath: base + "_live.json"))
        }
        let session = Session(
            id: Self.id, title: title, sourceApp: "Zoom", startedAt: Self.startedAt,
            endedAt: Self.startedAt.addingTimeInterval(3), durationSec: 3, audioPath: audio,
            transcriptRawPath: base + "_transcript.json", transcriptMarkdownPath: base + "_notes.md",
            recordingType: "call_meeting", language: "en", notesLanguage: "uk",
            analysisPath: base + "_analysis.json", engineUsed: "local_whisper",
            costTranscription: 0.01, costProcessing: 0.0042, costCurrency: "USD",
            warningMessage: "AI notes skipped: offline", status: "transcribed")
        let security = ServerSecurity(port: port)
        self.dir = dir
        self.session = session
        self.backend = FakeBackend(sessions: [session])
        self.security = security
        self.cookie = "cc_session=" + security.exchange(token: security.issueLoginToken())!
    }

    static func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// Memos covering every marker rule: kept (decision, question, edited manual note)
    /// and dropped (automatic idea/note, untimed manual note, pending suggestion).
    static func liveDocument(audioPath: String) -> ConversationDocument {
        var document = ConversationDocument()
        document.sessionID = id
        document.title = "Weekly sync"
        document.audioPath = audioPath
        document.turns = [
            LiveTurn(id: "t1", source: .system, start: 0.5, end: 1.4, text: "Can we ship?", language: "en"),
            LiveTurn(id: "t2", source: .mic, start: 2.0, end: 2.6, text: "Yes, Friday.", language: "en"),
            LiveTurn(id: "t3", source: .mic, start: 2.8, end: 2.95, text: "Noting that.", language: "en"),
        ]
        document.arrivalTurnIDs = ["t1", "t2", "t3"]
        document.topics = [
            ConversationTopic(
                id: "topic", title: "Release",
                memos: [
                    LiveMemo(id: "m-decision", kind: .decision, text: "Ship Friday", turnIDs: ["t2"]),
                    LiveMemo(id: "m-question", kind: .question, text: "Can we ship?", turnIDs: ["t3", "t1"]),
                    LiveMemo(id: "m-idea", kind: .idea, text: "Automatic idea", turnIDs: ["t1"]),
                    LiveMemo(id: "m-note", kind: .note, text: "Edited by me", manual: true, turnIDs: ["t3"]),
                    LiveMemo(id: "m-untimed", kind: .note, text: "Typed live", manual: true),
                    LiveMemo(id: "m-suggest", kind: .decision, text: "Ship Monday", turnIDs: ["t2"],
                             suggestedRevisionOf: "m-decision"),
                    LiveMemo(id: "m-auto-note", kind: .note, text: "Automatic note", turnIDs: ["t2"]),
                ],
                turnIDs: ["t1", "t2", "t3"]),
        ]
        return document
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    func run(_ test: @escaping @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        try await makeServerApp(security, authority: authority, backend: backend).test(.router, test)
    }

    func request(
        _ client: any TestClientProtocol, _ path: String, method: HTTPRequest.Method = .get,
        headers extra: HTTPFields = [:], json: String? = nil
    ) async throws -> TestResponse {
        var headers: HTTPFields = [.cookie: cookie]
        headers.append(contentsOf: extra)
        if json != nil { headers[.contentType] = "application/json" }
        return try await client.execute(
            uri: path, method: method, headers: headers, body: json.map { ByteBuffer(string: $0) })
    }
}

private func json(_ response: TestResponse) throws -> Any {
    try JSONSerialization.jsonObject(
        with: Data(String(buffer: response.body).utf8), options: [.fragmentsAllowed])
}

private func bytes(_ response: TestResponse) -> Data { Data(response.body.readableBytesView) }

private func expectNotFoundJSON(_ response: TestResponse, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(response.status == .notFound, sourceLocation: sourceLocation)
    #expect(response.headers[.contentType]?.hasPrefix("application/json") == true, sourceLocation: sourceLocation)
    #expect(String(buffer: response.body) == #"{"error":"not_found"}"#, sourceLocation: sourceLocation)
}

@Suite("Sessions API")
struct SessionsAPITests {
    @Test("list and detail carry the session meta as JSON")
    func listAndDetailShapes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.backend.add(Session(
            id: "S0", title: "Older", sourceApp: "Meet", startedAt: Fixture.startedAt.addingTimeInterval(-86_400),
            audioPath: fixture.dir.appendingPathComponent("missing.wav").path, status: "completed"))
        try await fixture.run { client in
            let list = try await fixture.request(client, "/api/sessions")
            #expect(list.status == .ok)
            #expect(list.headers[.contentType]?.hasPrefix("application/json") == true)
            let items = try #require(try json(list) as? [[String: Any]])
            #expect(items.map { $0["id"] as? String } == ["S1", "S0"])
            #expect(items[1]["hasAudio"] as? Bool == false)
            #expect(items[1]["hasTranscript"] as? Bool == false)
            #expect(items[1]["hasLiveMap"] as? Bool == false)

            let response = try await fixture.request(client, "/api/sessions/S1")
            #expect(response.status == .ok)
            let detail = try #require(try json(response) as? [String: Any])
            #expect(detail["id"] as? String == "S1")
            #expect(detail["title"] as? String == "Weekly sync")
            #expect(detail["sourceApp"] as? String == "Zoom")
            #expect(detail["startedAt"] as? String == ISO8601DateFormatter().string(from: Fixture.startedAt))
            #expect(detail["durationSec"] as? Double == 3)
            #expect(detail["status"] as? String == "transcribed")
            #expect(detail["recordingType"] as? String == "call_meeting")
            #expect(detail["language"] as? String == "en")
            #expect(detail["notesLanguage"] as? String == "uk")
            #expect(detail["engine"] as? String == "local_whisper")
            #expect(detail["warning"] as? String == "AI notes skipped: offline")
            #expect(detail["audioFileName"] as? String == "S1.wav")
            let costs = try #require(detail["costs"] as? [String: Any])
            #expect(costs["transcription"] as? Double == 0.01)
            #expect(costs["processing"] as? Double == 0.0042)
            #expect(abs((costs["total"] as? Double ?? 0) - 0.0142) < 1e-9)
            #expect(costs["currency"] as? String == "USD")
            for flag in ["hasAudio", "hasTranscript", "hasNote", "hasAnalysis", "hasLiveMap"] {
                #expect(detail[flag] as? Bool == true, "\(flag)")
            }
        }
    }

    @Test("transcript lines keep the original label and add the display name")
    func transcriptShape() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.run { client in
            let response = try await fixture.request(client, "/api/sessions/S1/transcript")
            #expect(response.status == .ok)
            let lines = try #require(try json(response) as? [[String: Any]])
            #expect(lines.count == 3)
            #expect(lines[0]["start"] as? Double == 0)
            #expect(lines[0]["end"] as? Double == 1.5)
            #expect(lines[0]["text"] as? String == "Hello there")
            #expect(lines[0]["speaker"] as? String == "Speaker 1")
            #expect(lines[0]["name"] as? String == "Speaker 1")
            #expect(lines[2]["speaker"] == nil)
            #expect(lines[2]["name"] == nil)
        }
    }

    @Test("note and analysis apply speaker names; analysis keeps the untimed insight lists")
    func noteAndAnalysis() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try SpeakerNames().renamed("Speaker 1", to: "Олена").save(audioPath: fixture.audioPath)
        try await fixture.run { client in
            let note = try #require(try json(try await fixture.request(client, "/api/sessions/S1/note")) as? [String: Any])
            #expect(note["markdown"] as? String == "# Weekly sync\n\n**Олена:** Hello there\n**You:** Hi\n")

            let response = try await fixture.request(client, "/api/sessions/S1/analysis")
            #expect(response.status == .ok)
            let analysis = try #require(try json(response) as? [String: Any])
            #expect(analysis["recordingType"] as? String == "call_meeting")
            #expect(analysis["warnings"] as? [String] == ["Short call"])
            let speakers = try #require(analysis["speakers"] as? [[String: Any]])
            #expect(speakers.map { $0["label"] as? String } == ["Speaker 1", "You"])
            #expect(speakers.map { $0["name"] as? String } == ["Олена", "You"])
            #expect(speakers[0]["talkRatio"] as? Double == 0.6)
            let insights = try #require(analysis["insights"] as? [String: Any])
            #expect(insights["summary"] as? String == "Олена led.")
            #expect(insights["actionItems"] as? [String] == ["Олена sends notes"])
            #expect(insights["keyPoints"] as? [String] == ["Budget"])
            let sentiment = try #require(analysis["sentiment"] as? [String: Any])
            #expect(sentiment["overall"] as? String == "positive")
            #expect((sentiment["arc"] as? [Any])?.count == 2)
        }
    }

    @Test("a session without note or analysis answers null values, not errors")
    func missingNoteAndAnalysis() async throws {
        let fixture = try Fixture(note: false)
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(atPath: try #require(fixture.session.analysisPath))
        try await fixture.run { client in
            let note = try await fixture.request(client, "/api/sessions/S1/note")
            #expect(note.status == .ok)
            #expect(String(buffer: note.body) == #"{"markdown":null}"#)
            let analysis = try await fixture.request(client, "/api/sessions/S1/analysis")
            #expect(analysis.status == .ok)
            #expect(String(buffer: analysis.body) == "null")
        }
    }

    @Test("speakersRoundTrip: PUT then GET shows the name; export JSON applies it")
    func speakersRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.run { client in
            let before = try #require(
                try json(try await fixture.request(client, "/api/sessions/S1/speakers")) as? [[String: Any]])
            #expect(before.map { $0["label"] as? String } == ["Speaker 1", "You"])
            #expect(before.map { $0["renamed"] as? Bool } == [false, false])

            // A label with a space arrives percent-encoded in the path.
            let put = try await fixture.request(
                client, "/api/sessions/S1/speakers/Speaker%201", method: .put,
                headers: [.origin: ownOrigin], json: #"{"name":"Alice"}"#)
            #expect(put.status == .noContent)

            let after = try #require(
                try json(try await fixture.request(client, "/api/sessions/S1/speakers")) as? [[String: Any]])
            #expect(after.first?["label"] as? String == "Speaker 1")
            #expect(after.first?["name"] as? String == "Alice")
            #expect(after.first?["renamed"] as? Bool == true)

            let lines = try #require(
                try json(try await fixture.request(client, "/api/sessions/S1/transcript")) as? [[String: Any]])
            #expect(lines[0]["speaker"] as? String == "Speaker 1")
            #expect(lines[0]["name"] as? String == "Alice")

            let export = try await fixture.request(client, "/api/sessions/S1/export?format=json")
            #expect(export.status == .ok)
            let exported = try #require(try json(export) as? [[String: Any]])
            #expect(exported.first?["speaker"] as? String == "Alice")

            // A blank name restores the label (no Origin header is also accepted).
            let reset = try await fixture.request(
                client, "/api/sessions/S1/speakers/Speaker%201", method: .put, json: #"{"name":"  "}"#)
            #expect(reset.status == .noContent)
            let restored = try #require(
                try json(try await fixture.request(client, "/api/sessions/S1/speakers")) as? [[String: Any]])
            #expect(restored.first?["name"] as? String == "Speaker 1")
            #expect(restored.first?["renamed"] as? Bool == false)
        }
    }

    @Test("renaming needs a known label and a JSON body with a string name")
    func renameValidation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.run { client in
            let unknown = try await fixture.request(
                client, "/api/sessions/S1/speakers/Nobody", method: .put, json: #"{"name":"X"}"#)
            expectNotFoundJSON(unknown)
            for body in [#"{"nom":"X"}"#, #"{"name":5}"#, "not json"] {
                let bad = try await fixture.request(
                    client, "/api/sessions/S1/speakers/You", method: .put, json: body)
                #expect(bad.status == .badRequest, "\(body)")
                #expect((try? json(bad) as? [String: Any])?["error"] as? String == "bad_request")
            }
            #expect(!FileManager.default.fileExists(atPath: SpeakerNames.sidecarPath(audioPath: fixture.audioPath)))
        }
    }

    @Test("audioRanges: 206 slices for a-b, a- and -n; 416 past the end")
    func audioRanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try Data(contentsOf: URL(fileURLWithPath: fixture.audioPath))
        let size = file.count
        #expect(size > 64 * 1024)
        try await fixture.run { client in
            let first = try await fixture.request(client, "/api/sessions/S1/audio", headers: [.range: "bytes=0-99"])
            #expect(first.status == .partialContent)
            #expect(first.headers[.contentRange] == "bytes 0-99/\(size)")
            #expect(first.headers[.acceptRanges] == "bytes")
            #expect(first.headers[.contentType] == "audio/wav")
            #expect(first.headers[.contentLength] == "100")
            #expect(bytes(first) == file.prefix(100))

            let tail = try await fixture.request(client, "/api/sessions/S1/audio", headers: [.range: "bytes=100-"])
            #expect(tail.status == .partialContent)
            #expect(tail.headers[.contentRange] == "bytes 100-\(size - 1)/\(size)")
            #expect(bytes(tail) == file.dropFirst(100))

            let suffix = try await fixture.request(client, "/api/sessions/S1/audio", headers: [.range: "bytes=-50"])
            #expect(suffix.status == .partialContent)
            #expect(suffix.headers[.contentRange] == "bytes \(size - 50)-\(size - 1)/\(size)")
            #expect(bytes(suffix) == file.suffix(50))

            let past = try await fixture.request(
                client, "/api/sessions/S1/audio", headers: [.range: "bytes=999999999-"])
            #expect(past.status == .rangeNotSatisfiable)
            #expect(past.headers[.contentRange] == "bytes */\(size)")

            let whole = try await fixture.request(client, "/api/sessions/S1/audio")
            #expect(whole.status == .ok)
            #expect(whole.headers[.acceptRanges] == "bytes")
            #expect(whole.headers[.contentLength] == "\(size)")
            #expect(bytes(whole) == file)
        }
    }

    @Test("multi-range or malformed Range headers get the whole file with 200",
          arguments: ["bytes=0-1,5-6", "bytes=5-2", "items=0-5", "bytes=abc", "bytes="])
    func audioIgnoresUnusableRanges(header: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try Data(contentsOf: URL(fileURLWithPath: fixture.audioPath))
        try await fixture.run { client in
            let response = try await fixture.request(client, "/api/sessions/S1/audio", headers: [.range: header])
            #expect(response.status == .ok)
            #expect(response.headers[.contentRange] == nil)
            #expect(bytes(response) == file)
        }
    }

    @Test("a missing audio file is 404 JSON for audio and peaks")
    func missingAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(atPath: fixture.audioPath)
        try await fixture.run { client in
            expectNotFoundJSON(try await fixture.request(client, "/api/sessions/S1/audio"))
            expectNotFoundJSON(try await fixture.request(client, "/api/sessions/S1/peaks"))
        }
    }

    @Test("peaks route serves 1200 values in 0…1 and caches them beside the audio")
    func peaksRoute() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.run { client in
            let response = try await fixture.request(client, "/api/sessions/S1/peaks")
            #expect(response.status == .ok)
            let peaks = try #require(try json(response) as? [Double])
            #expect(peaks.count == 1200)
            #expect(peaks.allSatisfy { (0...1).contains($0) })
            #expect(peaks.contains { $0 > 0.5 })
        }
        #expect(FileManager.default.fileExists(atPath: WaveformPeaks.cachePath(audioPath: fixture.audioPath)))
    }

    @Test("markersFromLiveMap: decision, question and manual-note memos at their evidence times")
    func markersFromLiveMap() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.run { client in
            let response = try await fixture.request(client, "/api/sessions/S1/markers")
            #expect(response.status == .ok)
            let markers = try #require(try json(response) as? [[String: Any]])
            #expect(markers.map { $0["kind"] as? String } == ["question", "decision", "note"])
            #expect(markers.map { $0["time"] as? Double } == [0.5, 2.0, 2.8])
            #expect(markers.map { $0["text"] as? String } == ["Can we ship?", "Ship Friday", "Edited by me"])
            #expect(markers.map { $0["id"] as? String } == ["m-question", "m-decision", "m-note"])
        }
    }

    @Test("a session recorded without the live map has no markers")
    func noLiveMapNoMarkers() async throws {
        let fixture = try Fixture(liveMap: false)
        defer { fixture.cleanup() }
        try await fixture.run { client in
            let response = try await fixture.request(client, "/api/sessions/S1/markers")
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == "[]")
        }
    }

    @Test("exportsAreAttachments: each format downloads under the session title")
    func exportsAreAttachments() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.run { client in
            let markdown = try await fixture.request(client, "/api/sessions/S1/export?format=md")
            #expect(markdown.status == .ok)
            #expect(markdown.headers[.contentDisposition] == #"attachment; filename="Weekly sync.md""#)
            #expect(markdown.headers[.contentType] == "text/markdown; charset=utf-8")
            #expect(String(buffer: markdown.body) == Fixture.noteMarkdown)

            let text = try await fixture.request(client, "/api/sessions/S1/export?format=txt")
            #expect(text.headers[.contentDisposition] == #"attachment; filename="Weekly sync.txt""#)
            #expect(text.headers[.contentType] == "text/plain; charset=utf-8")

            let transcript = try await fixture.request(client, "/api/sessions/S1/export?format=json")
            #expect(transcript.headers[.contentDisposition] == #"attachment; filename="Weekly sync.json""#)
            #expect(transcript.headers[.contentType] == "application/json; charset=utf-8")
        }
    }

    @Test("a Ukrainian title gets an ASCII fallback name plus filename*")
    func exportNonASCIITitle() async throws {
        let fixture = try Fixture(title: "План: Q3")
        defer { fixture.cleanup() }
        try await fixture.run { client in
            let response = try await fixture.request(client, "/api/sessions/S1/export?format=md")
            #expect(response.status == .ok)
            #expect(response.headers[.contentDisposition]
                == #"attachment; filename="Plan- Q3.md"; filename*=UTF-8''%D0%9F%D0%BB%D0%B0%D0%BD-%20Q3.md"#)
        }
    }

    @Test("export needs a known format and an existing note")
    func exportErrors() async throws {
        let fixture = try Fixture(note: false)
        defer { fixture.cleanup() }
        try await fixture.run { client in
            for path in ["/api/sessions/S1/export", "/api/sessions/S1/export?format=pdf"] {
                let response = try await fixture.request(client, path)
                #expect(response.status == .badRequest, "\(path)")
            }
            let missing = try await fixture.request(client, "/api/sessions/S1/export?format=md")
            #expect(missing.status == .conflict)
            #expect((try? json(missing) as? [String: Any])?["error"] as? String == "nothing_to_export")
        }
    }

    @Test("an unknown session id is 404 JSON on every route", arguments: [
        "GET /api/sessions/nope", "GET /api/sessions/nope/transcript", "GET /api/sessions/nope/note",
        "GET /api/sessions/nope/analysis", "GET /api/sessions/nope/speakers",
        "GET /api/sessions/nope/export?format=md", "GET /api/sessions/nope/audio",
        "GET /api/sessions/nope/peaks", "GET /api/sessions/nope/markers",
        "PUT /api/sessions/nope/speakers/You", "DELETE /api/sessions/nope",
        "POST /api/sessions/nope/reprocess", "POST /api/sessions/nope/vault",
        "POST /api/sessions/nope/reveal",
    ])
    func unknownIDIsNotFound(route: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let parts = route.split(separator: " ").map(String.init)
        let method = HTTPRequest.Method(parts[0])!
        try await fixture.run { client in
            let response = try await fixture.request(
                client, parts[1], method: method, json: method == .put ? #"{"name":"X"}"# : nil)
            expectNotFoundJSON(response)
        }
        #expect(fixture.backend.reprocessedIDs.isEmpty)
        #expect(fixture.backend.revealedIDs.isEmpty)
    }

    @Test("search finds transcript lines with their time, and ignores short queries")
    func search() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.run { client in
            let response = try await fixture.request(client, "/api/search?q=budget")
            #expect(response.status == .ok)
            let hits = try #require(try json(response) as? [[String: Any]])
            #expect(hits.count == 1)
            #expect(hits.first?["sessionId"] as? String == "S1")
            #expect(hits.first?["title"] as? String == "Weekly sync")
            #expect(hits.first?["time"] as? Double == 1.5)
            #expect((hits.first?["excerpt"] as? String)?.contains("budget") == true)
            #expect(hits.first?["id"] as? String != nil)

            for path in ["/api/search?q=b", "/api/search"] {
                #expect(String(buffer: try await fixture.request(client, path).body) == "[]", "\(path)")
            }
        }
    }

    @Test("re-process starts in the background: 202 at once, then the detail follows the run",
          .timeLimit(.minutes(1)))
    func reprocessRunsInBackground() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.backend.finishReprocess(status: "error", error: "Worker crashed")
        try await fixture.run { client in
            // The fake's run stays blocked until released: a route that waited for it
            // would never answer, and the time limit would fail the test.
            let started = try await fixture.request(
                client, "/api/sessions/S1/reprocess", method: .post, headers: [.origin: ownOrigin])
            #expect(started.status == .accepted)
            #expect(String(buffer: started.body) == #"{"started":true}"#)
            #expect(fixture.backend.reprocessedIDs == ["S1"])

            let running = try #require(try json(try await fixture.request(client, "/api/sessions/S1")) as? [String: Any])
            #expect(running["status"] as? String == "transcribing")
            #expect(running["error"] == nil)

            await fixture.backend.releaseReprocess()

            let done = try #require(try json(try await fixture.request(client, "/api/sessions/S1")) as? [String: Any])
            #expect(done["status"] as? String == "error")
            #expect(done["error"] as? String == "Worker crashed")
            #expect(done["warning"] as? String == "AI notes skipped: offline")
        }
    }

    @Test("a re-process that cannot start now is 409 with the reason as the error")
    func reprocessRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.backend.setActivity(state: .transcribing)
        try await fixture.run { client in
            let response = try await fixture.request(client, "/api/sessions/S1/reprocess", method: .post)
            #expect(response.status == .conflict)
            #expect(String(buffer: response.body)
                == #"{"error":"Another session is being processed. Try again when it finishes."}"#)
        }
        #expect(fixture.backend.reprocessedIDs.isEmpty)
    }

    @Test("a garbled speakers file reads as no names (200), and a rename rewrites it, like the detail view")
    func corruptSpeakersFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("{garbled".utf8).write(to: URL(fileURLWithPath: SpeakerNames.sidecarPath(audioPath: fixture.audioPath)))
        fixture.backend.saveVault(into: fixture.dir.appendingPathComponent("vault"))
        try await fixture.run { client in
            for leaf in ["transcript", "note", "analysis", "speakers", "export?format=md", "export?format=json"] {
                let response = try await fixture.request(client, "/api/sessions/S1/\(leaf)")
                #expect(response.status == .ok, "\(leaf)")
            }
            let lines = try #require(
                try json(try await fixture.request(client, "/api/sessions/S1/transcript")) as? [[String: Any]])
            #expect(lines[0]["name"] as? String == "Speaker 1")
            let vault = try await fixture.request(client, "/api/sessions/S1/vault", method: .post)
            #expect(vault.status == .ok)

            let rename = try await fixture.request(
                client, "/api/sessions/S1/speakers/Speaker%201", method: .put, json: #"{"name":"Alice"}"#)
            #expect(rename.status == .noContent)
            let speakers = try #require(
                try json(try await fixture.request(client, "/api/sessions/S1/speakers")) as? [[String: Any]])
            #expect(speakers.first?["name"] as? String == "Alice")
        }
        #expect(try SpeakerNames.load(audioPath: fixture.audioPath).display("Speaker 1") == "Alice")
    }

    @Test("vault, reveal and delete reach the backend and answer JSON")
    func writeActions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let vault = fixture.dir.appendingPathComponent("vault")
        try SpeakerNames().renamed("Speaker 1", to: "Alice").save(audioPath: fixture.audioPath)
        let same: HTTPFields = [.origin: ownOrigin]
        try await fixture.run { client in
            let noVault = try await fixture.request(client, "/api/sessions/S1/vault", method: .post)
            #expect(noVault.status == .conflict)
            #expect((try json(noVault) as? [String: Any])?["error"] as? String == "nothing_to_save")
            fixture.backend.saveVault(into: vault)
            let saved = try await fixture.request(client, "/api/sessions/S1/vault", method: .post, headers: same)
            #expect(saved.status == .ok)
            let path = try #require((try json(saved) as? [String: Any])?["path"] as? String)
            #expect(try String(contentsOfFile: path, encoding: .utf8).contains("**Alice:** Hello there"))

            let reveal = try await fixture.request(client, "/api/sessions/S1/reveal", method: .post, headers: same)
            #expect(reveal.status == .noContent)
            #expect(fixture.backend.revealedIDs == ["S1"])

            fixture.backend.setActivity(state: .recording, recordingSessionID: "S1")
            let busy = try await fixture.request(client, "/api/sessions/S1", method: .delete)
            #expect(busy.status == .conflict)
            #expect((try json(busy) as? [String: Any])?["error"] as? String == "busy")
            fixture.backend.setActivity(state: .idle)
            let deleted = try await fixture.request(client, "/api/sessions/S1", method: .delete, headers: same)
            #expect(deleted.status == .noContent)
            #expect(fixture.backend.deletedIDs == ["S1"])
            expectNotFoundJSON(try await fixture.request(client, "/api/sessions/S1"))
        }
    }

    @Test("GET /api/system reports online, recording and version")
    func systemStatus() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.backend.setStatus(SystemStatus(online: false, recording: true, version: "9.9"))
        try await fixture.run { client in
            let response = try await fixture.request(client, "/api/system")
            #expect(response.status == .ok)
            let status = try #require(try json(response) as? [String: Any])
            #expect(status["online"] as? Bool == false)
            #expect(status["recording"] as? Bool == true)
            #expect(status["version"] as? String == "9.9")
        }
    }

    @Test("sessions routes need the session cookie")
    func requiresSignIn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.run { client in
            for path in ["/api/sessions", "/api/sessions/S1/audio", "/api/system"] {
                let response = try await client.execute(uri: path, method: .get)
                #expect(response.status == .unauthorized, "\(path)")
            }
        }
    }
}
