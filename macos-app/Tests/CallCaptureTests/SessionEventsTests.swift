import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

/// Edits made through the API reach every open host as `sessionChanged`.
@Suite struct SessionEventsTests {
    private static func fixture() throws -> (SignedInAPI, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent("S1").path
        try Data(#"[{"start":0,"end":1,"text":"Hello","speaker":"Speaker 1"}]"#.utf8)
            .write(to: URL(fileURLWithPath: base + "_transcript.json"))
        try Data("# Note\n\nSpeaker 1 said hello.\n".utf8).write(to: URL(fileURLWithPath: base + "_notes.md"))
        let session = Session(
            id: "S1", title: "Weekly sync", sourceApp: "Zoom", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            audioPath: base + ".wav", transcriptRawPath: base + "_transcript.json",
            transcriptMarkdownPath: base + "_notes.md", status: "transcribed")
        return (SignedInAPI(backend: FakeBackend(sessions: [session])), dir)
    }

    /// Subscribes `count` readers and returns what each of them gets until the hub stops.
    private static func readers(_ hub: EventHub, count: Int) async -> [Task<[ServerEvent], Never>] {
        var tasks: [Task<[ServerEvent], Never>] = []
        for _ in 0..<count {
            let stream = await hub.subscribe()
            tasks.append(Task { await stream.reduce(into: []) { $0.append($1) } })
        }
        return tasks
    }

    @Test func renameBroadcasts() async throws {
        let (api, dir) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hub = api.backend.events
        let readers = await Self.readers(hub, count: 2)
        try await api.run { client in
            let response = try await api.request(
                client, "/api/sessions/S1/speakers/Speaker%201", method: .put, json: #"{"name":"Olena"}"#)
            #expect(response.status == .noContent, "\(bodyText(response))")
        }
        await hub.finishAll()
        for reader in readers {
            #expect(await reader.value.contains(.sessionChanged(id: "S1")))
        }
    }

    @Test func refusedRenameBroadcastsNothing() async throws {
        let (api, dir) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hub = api.backend.events
        let readers = await Self.readers(hub, count: 1)
        try await api.run { client in
            let response = try await api.request(
                client, "/api/sessions/S1/speakers/Nobody", method: .put, json: #"{"name":"Olena"}"#)
            #expect(response.status == .notFound)
        }
        await hub.finishAll()
        #expect(await readers[0].value.isEmpty)
    }

    @Test(arguments: [
        ("DELETE", "/api/sessions/S1"),
        ("POST", "/api/sessions/S1/reprocess"),
        ("POST", "/api/sessions/S1/vault"),
    ])
    func sessionActionsBroadcast(method: String, path: String) async throws {
        let (api, dir) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        api.backend.saveVault(into: dir)
        let hub = api.backend.events
        let readers = await Self.readers(hub, count: 1)
        try await api.run { client in
            let response = try await api.request(client, path, method: HTTPRequest.Method(method)!)
            #expect((200..<300).contains(response.status.code), "\(bodyText(response))")
        }
        await hub.finishAll()
        #expect(await readers[0].value.contains(.sessionChanged(id: "S1")))
        await api.backend.releaseReprocess()
    }

    @Test func settingsChangesBroadcast() async throws {
        let api = SignedInAPI()
        let hub = api.backend.events
        let readers = await Self.readers(hub, count: 1)
        try await api.run { client in
            let response = try await api.request(
                client, "/api/settings", method: .patch, json: #"{"general":{"autoProcessOnStop":false}}"#)
            #expect(response.status == .ok, "\(bodyText(response))")
        }
        await hub.finishAll()
        #expect(await readers[0].value.contains(.settings))
    }
}

@Suite(.serialized) struct SessionManagerChangeHookTests {
    @Test func everyRecordChangeIsReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SessionManager(database: try AppDatabase(path: dir.appendingPathComponent("db.sqlite").path))
        let seen = NSLockedValue<[String]>([])
        manager.onSessionChange = { id in seen.mutate { $0.append(id) } }

        let session = manager.createSession(sourceApp: "Test")
        manager.updateSessionStatus(id: session.id, status: "transcribing")
        manager.updateSessionWarning(id: session.id, message: "Short")
        manager.updateSessionPaths(id: session.id, rawTranscriptPath: nil, markdownPath: nil, engineUsed: nil)
        manager.updateSessionCost(id: session.id, costTranscription: 0.1, costProcessing: nil, costCurrency: "USD")
        manager.updateAnalysisPath(id: session.id, analysisPath: nil)
        manager.finalizeSession()
        manager.deleteSession(id: session.id)

        #expect(seen.get().count == 8)
        #expect(Set(seen.get()) == [session.id])
    }
}
