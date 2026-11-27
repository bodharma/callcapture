import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Observation
import Testing

@testable import CallCapture

/// Editing a session's details, opening its note and reporting transcription progress.
@Suite struct SessionEditAPITests {
    private static func fixture(note: Bool = true, status: String = "transcribed") throws -> (SignedInAPI, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent("S1").path
        if note { try Data("# Note\n".utf8).write(to: URL(fileURLWithPath: base + "_notes.md")) }
        let session = Session(
            id: "S1", title: "Weekly sync", sourceApp: "Zoom", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            audioPath: base + ".wav", transcriptMarkdownPath: base + "_notes.md", status: status)
        return (SignedInAPI(backend: FakeBackend(sessions: [session])), dir)
    }

    private static func readEvents(_ hub: EventHub) async -> Task<[ServerEvent], Never> {
        let stream = await hub.subscribe()
        return Task { await stream.reduce(into: []) { $0.append($1) } }
    }

    // MARK: PATCH /api/sessions/:id

    @Test func validChangeIsSavedPublishedAndReturned() async throws {
        let (api, dir) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reader = await Self.readEvents(api.backend.events)
        try await api.run { client in
            let response = try await api.request(
                client, "/api/sessions/S1", method: .patch,
                json: #"{"recordingType":"lecture","language":"uk","notesLanguage":"en"}"#)
            #expect(response.status == .ok, "\(bodyText(response))")
            let body = try jsonObject(response)
            #expect(body["recordingType"] as? String == "lecture")
            #expect(body["language"] as? String == "uk")
            #expect(body["notesLanguage"] as? String == "en")
        }
        let saved = await api.backend.session(id: "S1")
        #expect(saved?.recordingType == "lecture" && saved?.language == "uk" && saved?.notesLanguage == "en")
        await api.backend.events.finishAll()
        #expect(await reader.value.contains(.sessionChanged(id: "S1")))
    }

    @Test func oneFieldChangesOnlyThatField() async throws {
        let (api, dir) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = await api.backend.session(id: "S1")
        try await api.run { client in
            let response = try await api.request(
                client, "/api/sessions/S1", method: .patch, json: #"{"notesLanguage":"de"}"#)
            #expect(response.status == .ok, "\(bodyText(response))")
        }
        let after = await api.backend.session(id: "S1")
        #expect(after?.notesLanguage == "de")
        #expect(after?.language == before?.language && after?.recordingType == before?.recordingType)
    }

    @Test(arguments: [
        (#"{"recordingType":"lecture","language":"klingon"}"#, "language"),
        (#"{"recordingType":"podcast"}"#, "recordingType"),
        (#"{"notesLanguage":7}"#, "notesLanguage"),
        (#"{"title":"Renamed"}"#, "title"),
        (#"{"language":"en","status":"completed"}"#, "status"),
    ])
    func invalidBodyIsRefusedAndNothingIsSaved(body: String, key: String) async throws {
        let (api, dir) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = await api.backend.session(id: "S1")
        let reader = await Self.readEvents(api.backend.events)
        try await api.run { client in
            let response = try await api.request(client, "/api/sessions/S1", method: .patch, json: body)
            #expect(response.status == .badRequest, "\(bodyText(response))")
            let object = try jsonObject(response)
            #expect(object["error"] as? String == "invalid")
            #expect(object["key"] as? String == key)
            #expect((object["message"] as? String ?? "").isEmpty == false)
        }
        let after = await api.backend.session(id: "S1")
        #expect(after?.recordingType == before?.recordingType)
        #expect(after?.language == before?.language)
        #expect(after?.notesLanguage == before?.notesLanguage)
        await api.backend.events.finishAll()
        #expect(await reader.value.isEmpty)
    }

    @Test(arguments: ["{}", "[]", "not json", #""text""#])
    func aBodyWithNothingToChangeIsRefused(body: String) async throws {
        let (api, dir) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await api.run { client in
            let response = try await api.request(client, "/api/sessions/S1", method: .patch, json: body)
            #expect(response.status == .badRequest, "\(bodyText(response))")
            #expect(try jsonObject(response)["error"] as? String == "invalid")
        }
    }

    @Test func unknownSessionIsNotFound() async throws {
        let (api, dir) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await api.run { client in
            let response = try await api.request(
                client, "/api/sessions/nope", method: .patch, json: #"{"language":"en"}"#)
            #expect(response.status == .notFound)
        }
    }

    // MARK: GET /api/sessions/options

    @Test func optionsComeFromTheAppsEnums() async throws {
        let (api, dir) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await api.run { client in
            let response = try await api.request(client, "/api/sessions/options")
            #expect(response.status == .ok, "\(bodyText(response))")
            let body = try jsonObject(response)
            let types = try #require(body["recordingTypes"] as? [[String: String]])
            #expect(types.map { $0["value"] } == RecordingType.allCases.map(\.rawValue))
            #expect(types.first?["label"] == "Call / Meeting")
            let languages = try #require(body["languages"] as? [[String: String]])
            #expect(languages.map { $0["value"] } == SpokenLanguage.allCases.map(\.rawValue))
            #expect(languages.contains(["value": "uk", "label": "Ukrainian"]))
            #expect(languages.contains(["value": "auto", "label": "Auto-detect"]))
        }
    }

    // MARK: POST /api/sessions/:id/open-note

    @Test func openNoteAsksTheAppToOpenTheFile() async throws {
        let (api, dir) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await api.run { client in
            let response = try await api.request(client, "/api/sessions/S1/open-note", method: .post)
            #expect(response.status == .noContent, "\(bodyText(response))")
        }
        #expect(api.backend.openedNoteIDs == ["S1"])
    }

    @Test func openNoteWithoutAFileIsNoNote() async throws {
        let (api, dir) = try Self.fixture(note: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await api.run { client in
            let response = try await api.request(client, "/api/sessions/S1/open-note", method: .post)
            #expect(response.status == .notFound)
            let body = try jsonObject(response)
            #expect(body["error"] as? String == "no_note")
            #expect(body["message"] as? String == "This session has no Markdown note yet.")
        }
        #expect(api.backend.openedNoteIDs.isEmpty)
    }

    @Test func openNoteForAnUnknownSessionIsNotFound() async throws {
        let (api, dir) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await api.run { client in
            let response = try await api.request(client, "/api/sessions/nope/open-note", method: .post)
            #expect(response.status == .notFound)
            #expect(try jsonObject(response)["error"] as? String == "not_found")
        }
        #expect(api.backend.openedNoteIDs.isEmpty)
    }

    // MARK: Progress

    @Test func transcribingSessionReportsItsProgress() async throws {
        let (api, dir) = try Self.fixture(status: "transcribing")
        defer { try? FileManager.default.removeItem(at: dir) }
        api.backend.setProgress(0.4, for: "S1")
        try await api.run { client in
            let response = try await api.request(client, "/api/sessions/S1")
            #expect(try jsonObject(response)["progress"] as? Double == 0.4)
        }
    }

    @Test func otherStatusesReportNoProgress() async throws {
        let (api, dir) = try Self.fixture(status: "transcribed")
        defer { try? FileManager.default.removeItem(at: dir) }
        api.backend.setProgress(0.4, for: "S1")
        try await api.run { client in
            let one = try jsonObject(try await api.request(client, "/api/sessions/S1"))
            #expect(one["progress"] == nil)
            let list = try await api.request(client, "/api/sessions")
            #expect(!bodyText(list).contains("progress"))
        }
    }

    @Test func progressEventFrame() {
        #expect(
            SSEFrame.encode(.progress(sessionID: "S1", value: 0.5))
                == "event: progress\ndata: {\"sessionID\":\"S1\",\"value\":0.5}\n\n")
    }
}

@Observable @MainActor
private final class FakeProgress {
    var active = false
    var value = 0.0
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ServerEvent] = []
    func append(_ event: ServerEvent) { lock.withLock { events.append(event) } }
    var all: [ServerEvent] { lock.withLock { events } }
}

@MainActor
@Suite struct ProgressEventWatcherTests {
    private static func make(
        _ source: FakeProgress, sessionID: String? = "S1", log: ProgressLog
    ) -> ProgressEventWatcher {
        ProgressEventWatcher(
            isActive: { source.active }, progress: { source.value }, sessionID: { sessionID },
            post: { log.append($0) }, interval: .milliseconds(40))
    }

    @Test func aBurstOfUpdatesBecomesOneEventWithTheLatestValue() async {
        let source = FakeProgress()
        let log = ProgressLog()
        let watcher = Self.make(source, log: log)
        source.active = true
        for step in 1...20 { source.value = Double(step) / 20 }
        #expect(await eventually { log.all.count >= 1 })
        try? await Task.sleep(for: .milliseconds(120))
        #expect(log.all == [.progress(sessionID: "S1", value: 1.0)])
        watcher.stop()
    }

    @Test func eventsAreAtMostFourPerSecond() async {
        let source = FakeProgress()
        let log = ProgressLog()
        let watcher = ProgressEventWatcher(
            isActive: { source.active }, progress: { source.value }, sessionID: { "S1" },
            post: { log.append($0) })
        source.active = true
        let end = ContinuousClock.now + .milliseconds(1100)
        var value = 0.0
        while ContinuousClock.now < end {
            value += 0.001
            source.value = value
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(300))
        #expect((1...5).contains(log.all.count), "got \(log.all.count) events in ~1.1 s")
        watcher.stop()
    }

    @Test func nothingIsPublishedWhenNotTranscribing() async {
        let source = FakeProgress()
        let log = ProgressLog()
        let watcher = Self.make(source, log: log)
        source.value = 0.5
        try? await Task.sleep(for: .milliseconds(120))
        #expect(log.all.isEmpty)
        watcher.stop()
    }

    @Test func nothingIsPublishedWithoutASession() async {
        let source = FakeProgress()
        let log = ProgressLog()
        let watcher = Self.make(source, sessionID: nil, log: log)
        source.active = true
        source.value = 0.5
        try? await Task.sleep(for: .milliseconds(120))
        #expect(log.all.isEmpty)
        watcher.stop()
    }
}

@Suite(.serialized) struct SessionDetailEditHookTests {
    @Test func theThreeDetailWritersReportTheChange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-hook2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SessionManager(database: try AppDatabase(path: dir.appendingPathComponent("db.sqlite").path))
        let session = manager.createSession(sourceApp: "Test")
        let seen = NSLockedValue<[String]>([])
        manager.onSessionChange = { id in seen.mutate { $0.append(id) } }

        manager.updateRecordingType(id: session.id, recordingType: "lecture")
        manager.updateLanguage(id: session.id, language: "uk")
        manager.updateNotesLanguage(id: session.id, language: "en")

        #expect(seen.get() == [session.id, session.id, session.id])
    }
}
