import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import CallCapture

/// Polls `condition` until it holds or `timeout` passes; events and unsubscribes hop actors.
func eventually(
    timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Collects what an SSE body writes; optionally fails a write, as a closed socket does.
final class CollectingWriter: ResponseBodyWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []
    private var finished = false
    private let failWhen: @Sendable (String) -> Bool

    init(failWhen: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.failWhen = failWhen
    }

    var frames: [String] { lock.withLock { chunks } }
    var didFinish: Bool { lock.withLock { finished } }

    func write(_ buffer: ByteBuffer) async throws {
        let text = String(buffer: buffer)
        lock.withLock { chunks.append(text) }
        if failWhen(text) { throw ClosedSocket() }
    }

    func finish(_ trailingHeaders: HTTPFields?) async throws {
        lock.withLock { finished = true }
    }

    struct ClosedSocket: Error {}
}

@Suite struct EventHubTests {
    @Test func sseFormat() async throws {
        let api = SignedInAPI()
        let hub = api.backend.events
        try await api.run { client in
            async let response = api.request(client, "/api/events")
            #expect(await eventually { await hub.subscriberCount == 1 })
            await hub.publish(.sessionChanged(id: "S1"))
            await hub.finishAll()
            let answer = try await response
            #expect(answer.status == .ok)
            #expect(answer.headers[.contentType]?.hasPrefix("text/event-stream") == true)
            #expect(answer.headers[.cacheControl] == "no-cache")
            let frames = bodyText(answer).components(separatedBy: "\n\n").filter { !$0.isEmpty }
            #expect(frames.count == 2, "\(frames)")
            #expect(frames.last == #"event: sessionChanged"# + "\n" + #"data: {"id":"S1"}"#)
        }
    }

    @Test func helloFirstCarriesRecordingAndOnline() async throws {
        let api = SignedInAPI()
        api.backend.setStatus(SystemStatus(online: false, recording: true, version: "test", recordingState: "recording"))
        let hub = api.backend.events
        try await api.run { client in
            async let response = api.request(client, "/api/events")
            #expect(await eventually { await hub.subscriberCount == 1 })
            await hub.finishAll()
            let text = bodyText(try await response)
            #expect(text.hasPrefix("event: hello\n"), "\(text)")
            #expect(text.contains(#"data: {"online":false,"recording":"recording"}"#), "\(text)")
        }
    }

    @Test func eventsNeedASession() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let response = try await client.execute(uri: "/api/events", method: .get, headers: [:])
            #expect(response.status == .unauthorized)
        }
    }

    @Test func subscriberDropsOnDisconnect() async throws {
        let hub = EventHub()
        let stream = await hub.subscribe()
        let reader = Task { for await _ in stream {} }
        #expect(await hub.subscriberCount == 1)
        reader.cancel()
        #expect(await eventually { await hub.subscriberCount == 0 })
    }

    @Test func streamDropsSubscriberWhenTheWriteFails() async throws {
        let hub = EventHub()
        let writer = CollectingWriter { $0.hasPrefix("event: catalog") }
        let run = Task {
            var body: any ResponseBodyWriter = writer
            try await EventStreamWriter.run(
                writer: &body, hello: .connectivity(online: true), events: await hub.subscribe(),
                heartbeat: .seconds(60))
        }
        #expect(await eventually { await hub.subscriberCount == 1 })
        await hub.publish(.catalog)
        await #expect(throws: CollectingWriter.ClosedSocket.self) { try await run.value }
        #expect(await eventually { await hub.subscriberCount == 0 })
        #expect(!writer.didFinish)
    }

    @Test func streamEndsAndFinishesWhenTheHubStops() async throws {
        let hub = EventHub()
        let writer = CollectingWriter()
        let run = Task {
            var body: any ResponseBodyWriter = writer
            try await EventStreamWriter.run(
                writer: &body, hello: .connectivity(online: true), events: await hub.subscribe(),
                heartbeat: .seconds(60))
        }
        #expect(await eventually { await hub.subscriberCount == 1 })
        await hub.finishAll()
        try await run.value
        #expect(writer.didFinish)
        #expect(await hub.subscriberCount == 0)
    }

    @Test func heartbeatKeepsTheStreamAlive() async throws {
        let hub = EventHub()
        let writer = CollectingWriter { $0 == SSEFrame.heartbeat }
        var body: any ResponseBodyWriter = writer
        await #expect(throws: CollectingWriter.ClosedSocket.self) {
            try await EventStreamWriter.run(
                writer: &body, hello: .catalog, events: await hub.subscribe(), heartbeat: .milliseconds(20))
        }
        #expect(writer.frames == ["event: catalog\ndata: {}\n\n", ": hb\n\n"])
    }

    @Test func slowSubscriberKeepsOnlyTheNewestEvents() async throws {
        let hub = EventHub()
        let stream = await hub.subscribe()
        for index in 0..<300 { await hub.publish(.sessionChanged(id: "\(index)")) }
        await hub.finishAll()
        var received: [ServerEvent] = []
        for await event in stream { received.append(event) }
        #expect(received.count == EventHub.bufferLimit)
        #expect(received.first == .sessionChanged(id: "\(300 - EventHub.bufferLimit)"))
        #expect(received.last == .sessionChanged(id: "299"))
    }

    @Test func postKeepsOrder() async throws {
        let hub = EventHub()
        let stream = await hub.subscribe()
        for index in 0..<50 { hub.post(.sessionChanged(id: "\(index)")) }
        var received: [ServerEvent] = []
        for await event in stream {
            received.append(event)
            if received.count == 50 { break }
        }
        #expect(received == (0..<50).map { .sessionChanged(id: "\($0)") })
    }

    @Test func framesAreOneLineOfJSON() throws {
        let turn = LiveTurn(id: "t1", source: .mic, start: 1, end: 2, text: "Line one\nline two", language: "en")
        let frame = SSEFrame.encode(.liveTurn(turn))
        #expect(frame.hasPrefix("event: liveTurn\ndata: {"))
        #expect(frame.hasSuffix("}\n\n"))
        #expect(frame.dropLast(2).components(separatedBy: "\n").count == 2, "a raw newline would split the frame")
        #expect(SSEFrame.encode(.recording(state: "starting")) == "event: recording\ndata: {\"state\":\"starting\"}\n\n")
        #expect(SSEFrame.encode(.partial(source: "system", text: "hi")) ==
            "event: partial\ndata: {\"source\":\"system\",\"text\":\"hi\"}\n\n")
        #expect(SSEFrame.encode(.connectivity(online: false)) == "event: connectivity\ndata: {\"online\":false}\n\n")
        #expect(SSEFrame.encode(.liveDocument(sessionID: "S1")) == "event: liveDocument\ndata: {\"sessionID\":\"S1\"}\n\n")
        #expect(SSEFrame.encode(.settings) == "event: settings\ndata: {}\n\n")
    }
}
