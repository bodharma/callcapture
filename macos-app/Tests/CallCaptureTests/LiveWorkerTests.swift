import Foundation
import Testing
@testable import CallCapture

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
        try await worker.finish(timeout: 2)
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

    @Test("stderr drain ends cleanly and no descriptors leak across worker runs")
    func stderrLifecycle() async throws {
        func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        let baseline = openDescriptors()
        for _ in 0..<5 {
            let worker = LiveWorkerProcess(configuration: WorkerProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-u", "-c", "import sys,json\nsys.stderr.write('x'*300000)\nprint(json.dumps({'type':'ready'}),flush=True)\nfor l in sys.stdin: break"],
                directory: nil, environment: [:]))
            let events = try worker.start()
            for try await event in events { if case .ready = event { break } }
            try await worker.finish(timeout: 3)
        }
        var now = openDescriptors()
        let deadline = Date().addingTimeInterval(3)
        while now > baseline && Date() < deadline { try await Task.sleep(for: .milliseconds(50)); now = openDescriptors() }
        #expect(now <= baseline, "leaked \(now - baseline) descriptors")
    }
}
