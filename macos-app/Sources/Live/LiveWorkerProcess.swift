import Foundation

enum LiveWorkerEvent: Sendable {
    case ready
    case turn(LiveTurn)
    case partial(source: LiveAudioSource, text: String)
    case chunkDone(String)
    case failure(String)
    case exited(Int32)
    static func parse(_ data: Data) throws -> LiveWorkerEvent {
        guard data.count <= 1_300_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw LiveWorkerError.invalidFrame }
        switch type {
        case "ready": return .ready
        case "chunk_done":
            guard let id = object["id"] as? String, !id.isEmpty, id.count <= 128 else { throw LiveWorkerError.invalidFrame }
            return .chunkDone(id)
        case "error":
            guard let message = object["message"] as? String else { throw LiveWorkerError.invalidFrame }
            return .failure(String(message.prefix(2000)))
        case "turn", "partial":
            guard let raw = object["source"] as? String, let source = LiveAudioSource(rawValue: raw),
                  let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 32_000, let start = object["start"] as? Double,
                  let end = object["end"] as? Double, start.isFinite, end.isFinite, start >= 0, end >= start,
                  end <= LiveMeetingModel.maxOffsetSeconds
            else { throw LiveWorkerError.invalidFrame }
            if type == "partial" { return .partial(source: source, text: text) }
            guard object["final"] as? Bool == true, let id = object["id"] as? String,
                  !id.isEmpty, id.count <= 512 else { throw LiveWorkerError.invalidFrame }
            return .turn(LiveTurn(id: id, source: source, start: start, end: end, text: text,
                                  language: object["language"] as? String))
        default: throw LiveWorkerError.invalidFrame
        }
    }
}

final class LiveWorkerProcess: @unchecked Sendable {
    private let configuration: WorkerProcessConfiguration
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let diagnostics = Pipe()
    private let lock = NSLock()
    /// Signalled by the process termination handler. `Process.waitUntilExit()` is not used on a pool
    /// thread because it can miss the exit notification and then block that thread (and this worker) forever.
    private let exited = DispatchSemaphore(value: 0)
    private let writer = DispatchQueue(label: "com.callcapture.live.stdin", qos: .utility)
    private var ready = false
    private var pending: Set<String> = []
    private var failure: String?
    private var cancelled = false
    private var writeFailed = false
    private var continuation: AsyncThrowingStream<LiveWorkerEvent, Error>.Continuation?

    init(configuration: WorkerProcessConfiguration) {
        self.configuration = configuration
        // A worker that dies mid-meeting must fail our writes with EPIPE, not kill the app with SIGPIPE.
        PipeSafety.suppressSIGPIPE(on: input)
    }
    var isRunning: Bool { process.isRunning }

    func start() throws -> AsyncThrowingStream<LiveWorkerEvent, Error> {
        let stream = AsyncThrowingStream<LiveWorkerEvent, Error>(bufferingPolicy: .bufferingOldest(128)) { continuation in
            self.continuation = continuation
        }
        configuration.apply(to: process)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()
        DispatchQueue.global(qos: .utility).async { [self] in readEvents() }
        // Drain logs without retaining meeting content or allowing stderr pipe pressure.
        DispatchQueue.global(qos: .utility).async { [self] in
            var bytes = [UInt8](repeating: 0, count: 8192)
            let handle = diagnostics.fileHandleForReading
            // The drain thread is the only reader, so it alone closes the handle (at EOF/error).
            while true {
                let count = read(handle.fileDescriptor, &bytes, bytes.count)
                if count > 0 || (count < 0 && errno == EINTR) { continue }
                break
            }
            try? handle.close()
        }
        return stream
    }

    func transcribe(_ chunk: LivePCMChunk, id: String) async throws {
        try await waitUntil(timeout: 90) { self.lock.withLock { self.ready } }
        let data = try Self.requestData(chunk: chunk, id: id, sampleRate: 16_000)
        _ = lock.withLock { pending.insert(id) }
        try await write(data)
        try await waitUntil(timeout: 90) { self.lock.withLock { !self.pending.contains(id) } }
    }

    func finish(timeout: Double) async throws {
        // If the stop request cannot be delivered the worker is already gone; the wait below reports it.
        if process.isRunning { try? await write(Data(#"{"type":"stop"}"#.utf8)) }
        do {
            try await waitUntil(timeout: timeout) { !self.process.isRunning }
            if let message = lock.withLock({ failure }) { throw LiveWorkerError.unavailable(message) }
            guard process.terminationStatus == 0 else { throw LiveWorkerError.unavailable("Local speech worker stopped unexpectedly.") }
        } catch {
            cancel()
            let deadline = Date().addingTimeInterval(0.6)
            while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            throw error
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        // Cancellation is not a graceful stop: do not leave a child behind on app exit.
        kill(pid, SIGKILL)
    }

    func write(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.async { [self] in
                    do {
                        // Once a write has failed the worker is unreachable: stop writing (no repeated errors).
                        if lock.withLock({ writeFailed }) { throw LiveWorkerError.unavailable(Self.stdinClosedMessage) }
                        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
                        continuation.resume()
                    } catch {
                        noteWriteFailure()
                        continuation.resume(throwing: LiveWorkerError.unavailable(Self.stdinClosedMessage))
                    }
                }
            }
        } onCancel: { self.cancel() }
    }

    private static let stdinClosedMessage = "Local speech worker stopped accepting audio."

    /// Records the first failed write (typically EPIPE: the worker died) as the worker's failure.
    /// `waitUntil` then surfaces it through the usual error path; later writes are refused.
    private func noteWriteFailure() {
        lock.withLock {
            guard !writeFailed else { return }
            writeFailed = true
            if failure == nil { failure = Self.stdinClosedMessage }
            pending.removeAll()
        }
    }

    private func waitUntil(timeout: Double, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            try Task.checkCancellation()
            let state = lock.withLock { (failure, cancelled) }
            if let message = state.0 { throw LiveWorkerError.unavailable(message) }
            if state.1 { throw CancellationError() }
            if !process.isRunning { throw LiveWorkerError.unavailable("Local speech worker exited before completing accepted audio.") }
            if Date() >= deadline { throw LiveWorkerError.timeout }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func readEvents() {
        var buffer = Data()
        do {
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw LiveWorkerError.unavailable("Could not read the local speech worker.")
                }
                buffer.append(contentsOf: bytes.prefix(count))
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    let event = try LiveWorkerEvent.parse(line)
                    switch event {
                    case .ready: lock.withLock { ready = true }
                    case .chunkDone(let id): _ = lock.withLock { pending.remove(id) }
                    case .failure(let message): lock.withLock { failure = message; pending.removeAll() }
                    default: break
                    }
                    if case .dropped = continuation?.yield(event) {
                        throw LiveWorkerError.unavailable("Live event queue overflow; recording retained.")
                    }
                }
                guard buffer.count <= 1_300_000 else { throw LiveWorkerError.invalidFrame }
            }
            guard buffer.isEmpty else { throw LiveWorkerError.invalidFrame }
            exited.wait()
            continuation?.yield(.exited(process.terminationStatus))
            continuation?.finish()
        } catch {
            lock.withLock { failure = error.localizedDescription; pending.removeAll() }
            continuation?.finish(throwing: error)
            cancel()
        }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }

    static func requestData(chunk: LivePCMChunk, id: String, sampleRate: Int) throws -> Data {
        guard sampleRate == 16_000, !id.isEmpty, id.count <= 128, chunk.start.isFinite, chunk.start >= 0,
              !chunk.samples.isEmpty, chunk.samples.count <= sampleRate * 15,
              chunk.samples.allSatisfy({ $0.isFinite }) else { throw LiveWorkerError.invalidFrame }
        var bytes = Data(capacity: chunk.samples.count * 4)
        for sample in chunk.samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return try JSONSerialization.data(withJSONObject: ["id": id, "source": chunk.source.rawValue,
            "start": chunk.start, "sample_rate": sampleRate, "pcm_f32le": bytes.base64EncodedString(), "final": chunk.final])
    }
}

enum LiveWorkerError: LocalizedError {
    case invalidFrame, unavailable(String), timeout
    var errorDescription: String? {
        switch self {
        case .invalidFrame: "The local speech worker returned an invalid frame. Recording continues."
        case .unavailable(let message): message
        case .timeout: "Local speech timed out; live evidence may be incomplete. Recording is retained."
        }
    }
}
