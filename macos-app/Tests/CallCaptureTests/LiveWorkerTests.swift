import Darwin
import Foundation
import Testing
@testable import CallCapture

/// Upper bound for waits that end as soon as a synthetic Python worker responds.
/// Concurrent cold `python3` launches on CI runners took ~3 s; local runs take <1 s.
/// Tests that deliberately check a bounded stop keep their own short timeouts.
enum TestTiming {
    static let subprocessWait: Double = 20
}

@Suite("Live worker wire protocol")
struct LiveWorkerTests {
    @Test("finals preserve source, immutable identity and audio offsets")
    func turn() throws {
        let event = try LiveWorkerEvent.parse(Data(#"{"type":"turn","id":"system-1","source":"system","start":7.5,"end":8.25,"text":"Test evidence","language":"en","final":true}"#.utf8))
        guard case .turn(let turn) = event else { Issue.record("not a turn"); return }
        #expect(turn.id == "system-1")
        #expect(turn.source == .system)
        #expect(turn.start == 7.5)
        #expect(turn.end == 8.25)
        #expect(turn.text == "Test evidence")
    }

    @Test("malformed, nonfinite, oversized and nonfinal turns fail explicitly")
    func malformed() {
        for json in [#"{"type":"unknown"}"#, #"{"type":"turn","id":"x","source":"mix","start":0,"end":1,"text":"x","final":true}"#, #"{"type":"turn","id":"x","source":"mic","start":2,"end":1,"text":"x","final":true}"#, #"{"type":"turn","id":"x","source":"mic","start":0,"end":1,"text":"x","final":false}"#] {
            #expect(throws: (any Error).self) { try LiveWorkerEvent.parse(Data(json.utf8)) }
        }
        #expect(throws: (any Error).self) { try LiveWorkerEvent.parse(Data(repeating: 65, count: 1_400_000)) }
    }

    @Test("PCM request uses explicit little endian Float32 and stable source offsets")
    func request() throws {
        let chunk = LivePCMChunk(source: .mic, start: 2.5, samples: [1, -1])
        let data = try LiveWorkerProcess.requestData(chunk: chunk, id: "request-1", sampleRate: 16_000)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["id"] as? String == "request-1")
        #expect(json["source"] as? String == "mic")
        #expect(json["start"] as? Double == 2.5)
        #expect(json["final"] as? Bool == true)
        #expect(json["pcm_f32le"] as? String == "AACAPwAAgL8=")
        var preview = chunk
        preview.final = false
        let provisional = try #require(JSONSerialization.jsonObject(with: LiveWorkerProcess.requestData(chunk: preview, id: preview.requestID, sampleRate: 16_000)) as? [String: Any])
        #expect(provisional["final"] as? Bool == false)
    }
    @Test("synthetic persistent worker acknowledges a tail and exits on stop")
    func lifecycle() async throws {
        let script = """
        import sys,json
        print(json.dumps({'type':'ready'}),flush=True)
        for line in sys.stdin:
            r=json.loads(line)
            if r.get('type')=='stop': break
            print(json.dumps({'type':'turn','id':r['id'],'source':r['source'],'start':r['start'],'end':r['start']+1,'text':'Synthetic','final':True}),flush=True)
            print(json.dumps({'type':'chunk_done','id':r['id']}),flush=True)
        """
        let worker = LiveWorkerProcess(configuration: WorkerProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script], directory: nil, environment: [:]))
        defer { worker.cancel() }
        let events = try worker.start()
        let observed = Task { () -> [LiveTurn] in
            var turns: [LiveTurn] = []
            do { for try await event in events { if case .turn(let turn) = event { turns.append(turn) } } }
            catch { Issue.record("Unexpected worker error: \(error)") }
            return turns
        }
        try await worker.transcribe(LivePCMChunk(source: .system, start: 9, samples: [0, 0]), id: "tail")
        try await worker.finish(timeout: TestTiming.subprocessWait)
        let turns = await observed.value
        #expect(turns.map(\.id) == ["tail"])
        #expect(turns.first?.start == 9)
        #expect(!worker.isRunning)
    }

    @Test("a stalled subprocess is killed within a bounded stop")
    func stalledStop() async throws {
        let worker = LiveWorkerProcess(configuration: WorkerProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"], directory: nil, environment: [:]))
        defer { worker.cancel() }
        _ = try worker.start()
        do { try await worker.finish(timeout: 0.15); Issue.record("Expected timeout") } catch { }
        #expect(!worker.isRunning)
    }

    /// The two tests that snapshot the whole process's pipes. Serialized only against each other so one
    /// cannot see the other's in-flight pipes; every other suite still runs in parallel.
    @Suite("Worker pipe release", .serialized)
    struct PipeRelease {
        @Test("concurrently finished workers release their pipes and deallocate")
        func concurrentWorkersRelease() async throws {
            // Regression: with many workers exiting at once, `Process.waitUntilExit()` on a pool thread
            // sometimes never returned, so the reader kept the worker and its pipe descriptors alive forever.
            try await Self.runWorkerOnce() // warm-up: process-lifetime descriptors are created on first launch
            let baseline = PipeSnapshot.current()
            var workers: [WeakWorker] = []
            for _ in 0..<8 {
                workers += try await withThrowingTaskGroup(of: WeakWorker.self) { group in
                    for _ in 0..<24 { group.addTask { try await Self.runWorkerOnce() } }
                    return try await group.reduce(into: []) { $0.append($1) }
                }
            }
            var extra = PipeSnapshot.current().subtracting(baseline)
            var alive = workers.filter { $0.worker != nil }.count
            let deadline = Date().addingTimeInterval(TestTiming.subprocessWait)
            while (!extra.isEmpty || alive > 0) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
                extra = PipeSnapshot.current().subtracting(baseline)
                alive = workers.filter { $0.worker != nil }.count
            }
            #expect(alive == 0, "\(alive) finished workers were never released")
            #expect(extra.isEmpty, "leaked pipe descriptors: \(extra.sorted { $0.fd < $1.fd })")
        }

        @Test("stderr drain ends cleanly and no descriptors leak across worker runs")
        func stderrLifecycle() async throws {
            // Identify pipes by (fd, kernel pipe handle) via libproc. Counting every descriptor (or using
            // fstat/S_IFIFO, which reports kqueues as FIFOs on macOS) also counts unrelated long-lived
            // descriptors that other suites open in parallel (SwiftNIO kqueues from the server tests).
            // Warm up first: Foundation/libdispatch lazily create process-lifetime descriptors on the first
            // worker launch, which must not count against the measured runs.
            try await Self.runWorkerOnce()
            let baseline = PipeSnapshot.current()
            for _ in 0..<5 { try await Self.runWorkerOnce() }
            // Pipes other suites opened meanwhile close when their workers finish; ours must too.
            var extra = PipeSnapshot.current().subtracting(baseline)
            let deadline = Date().addingTimeInterval(TestTiming.subprocessWait)
            while !extra.isEmpty && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
                extra = PipeSnapshot.current().subtracting(baseline)
            }
            #expect(extra.isEmpty, "leaked pipe descriptors: \(extra.sorted { $0.fd < $1.fd })")
        }

        /// One full worker lifecycle: noisy stderr, ready event, graceful stop.
        @discardableResult
        private static func runWorkerOnce() async throws -> WeakWorker {
            let worker = LiveWorkerProcess(configuration: WorkerProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-u", "-c", "import sys,json\nsys.stderr.write('x'*300000)\nprint(json.dumps({'type':'ready'}),flush=True)\nfor l in sys.stdin: break"],
                directory: nil, environment: [:]))
            let events = try worker.start()
            for try await event in events { if case .ready = event { break } }
            try await worker.finish(timeout: TestTiming.subprocessWait)
            return WeakWorker(worker: worker)
        }
    }
}

struct WeakWorker: @unchecked Sendable { weak var worker: LiveWorkerProcess? }

/// Open pipe descriptors of this process, identified by descriptor number plus kernel pipe handle.
struct PipeSnapshot: Hashable {
    let fd: Int32
    let handle: UInt64

    static func current() -> Set<PipeSnapshot> {
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard written > 0 else { return [] }
        var result = Set<PipeSnapshot>()
        for info in fds.prefix(Int(written) / MemoryLayout<proc_fdinfo>.stride)
        where info.proc_fdtype == UInt32(PROX_FDTYPE_PIPE) {
            var pipe = pipe_fdinfo()
            let n = proc_pidfdinfo(pid, info.proc_fd, PROC_PIDFDPIPEINFO, &pipe, Int32(MemoryLayout<pipe_fdinfo>.size))
            if n > 0 { result.insert(PipeSnapshot(fd: info.proc_fd, handle: pipe.pipeinfo.pipe_handle)) }
        }
        return result
    }
}
