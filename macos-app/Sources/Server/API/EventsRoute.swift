import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// `GET /api/events` → `text/event-stream`. The first frame is `hello` (recording state
/// and online flag, so a reconnecting page resyncs); then one frame per `ServerEvent`
/// and a `: hb` comment every `heartbeat`. Like every `/api/*` route it needs the
/// session cookie, which `EventSource` sends same-origin.
///
/// The stream ends when the client goes away (inbound close, or the next write
/// failing — at the latest one heartbeat later) or when the hub stops; either way the
/// hub drops the subscriber.
func addEventsRoute(to router: Router<BasicRequestContext>, backend: any AppBackend, heartbeat: Duration) {
    router.get("api/events") { request, _ in
        let hub = backend.events
        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream; charset=utf-8",
                .cacheControl: "no-cache",
            ],
            body: ResponseBody { writer in
                // Subscribe before reading the state, so nothing between the two is lost.
                let events = await hub.subscribe()
                let hello = ServerEvent.hello(await backend.systemStatus())
                let (closed, closeSignal) = AsyncStream<Void>.makeStream()
                try await request.body.withInboundCloseHandler {
                    try await EventStreamWriter.run(
                        writer: &writer, hello: hello, events: events, heartbeat: heartbeat, closed: closed)
                } onInboundClosed: {
                    closeSignal.finish()
                }
            })
    }
}

/// Writes an SSE stream: `hello`, then events and heartbeats in one ordered sequence.
enum EventStreamWriter {
    /// Returns (after finishing the body) when `events` ends or `closed` finishes; throws
    /// when a write fails. Either way the subscription is cancelled on the way out.
    static func run(
        writer: inout any ResponseBodyWriter, hello: ServerEvent, events: AsyncStream<ServerEvent>,
        heartbeat: Duration, closed: AsyncStream<Void> = AsyncStream { _ in }
    ) async throws {
        let (frames, sink) = AsyncStream<ByteBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(EventHub.bufferLimit))
        sink.yield(ByteBuffer(string: SSEFrame.encode(hello)))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events {
                    sink.yield(ByteBuffer(string: SSEFrame.encode(event)))
                }
                sink.finish()
            }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(for: heartbeat)
                    sink.yield(ByteBuffer(string: SSEFrame.heartbeat))
                }
            }
            group.addTask {
                for await _ in closed {}
                if !Task.isCancelled { sink.finish() }
            }
            for await frame in frames {
                try await writer.write(frame)
            }
            group.cancelAll()
        }
        try await writer.finish(nil)
    }
}
