import Foundation

/// Fans server events out to every open `/api/events` stream.
///
/// Each subscriber gets its own stream that keeps only the newest `bufferLimit`
/// events, so a stalled page loses old events (it resyncs from `hello` when it
/// reconnects) instead of growing memory. A subscriber is removed when its stream
/// terminates: the reader is cancelled (page closed, write failed) or the hub stops.
actor EventHub {
    static let bufferLimit = 256

    private var subscribers: [UUID: AsyncStream<ServerEvent>.Continuation] = [:]
    /// Keeps `post` calls from any thread in the order they were made.
    private nonisolated let inbox: AsyncStream<ServerEvent>.Continuation
    private var pump: Task<Void, Never>?

    init() {
        let (stream, inbox) = AsyncStream<ServerEvent>.makeStream()
        self.inbox = inbox
        Task { await self.startPump(stream) }
    }

    deinit {
        inbox.finish()
        pump?.cancel()
    }

    var subscriberCount: Int { subscribers.count }

    func subscribe() -> AsyncStream<ServerEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ServerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.bufferLimit))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        subscribers[id] = continuation
        return stream
    }

    func publish(_ event: ServerEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    /// For callers outside the actor (main-actor app state, file hooks): queues the
    /// event and returns at once; events are published in call order.
    nonisolated func post(_ event: ServerEvent) {
        inbox.yield(event)
    }

    /// Ends every stream, so open `/api/events` responses complete (server stop).
    func finishAll() {
        let open = subscribers.values
        subscribers.removeAll()
        for continuation in open {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }

    private func startPump(_ stream: AsyncStream<ServerEvent>) {
        pump = Task { [weak self] in
            for await event in stream {
                await self?.publish(event)
            }
        }
    }
}
