import Foundation
import Testing
@testable import CallCapture

@Suite("Native live state routing")
@MainActor struct LiveMeetingIntegrationTests {
    private func fixture(script: String) throws -> (URL, PythonBridge, Session) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = directory.appendingPathComponent("app")
        let bin = directory.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("__init__.py"))
        try Data(script.utf8).write(to: app.appendingPathComponent("cli.py"))
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("python"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let bridge = PythonBridge()
        bridge.devMode = true
        bridge.pythonWorkerDirectory = directory.path
        let session = Session(id: "synthetic", title: "Synthetic meeting", sourceApp: "Test", startedAt: Date(), audioPath: directory.appendingPathComponent("audio.wav").path, status: "recording")
        return (directory, bridge, session)
    }
    private let configuration = LiveNotesConfiguration(enabled: false, baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: "", model: "unused")

    @Test("accepted mic/system tails route into persisted independent evidence before stop returns")
    func sourceRoutingAndStop() async throws {
        let script = """
        import sys,json,base64
        print(json.dumps({'type':'ready'}),flush=True)
        for line in sys.stdin:
            r=json.loads(line)
            if r.get('type')=='stop': break
            count=len(base64.b64decode(r['pcm_f32le']))//4
            print(json.dumps({'type':'turn','id':r['id'],'source':r['source'],'start':r['start'],'end':r['start']+count/16000,'text':r['source']+' evidence','language':'en','final':True}),flush=True)
            print(json.dumps({'type':'chunk_done','id':r['id']}),flush=True)
        """
        let (directory, bridge, session) = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LiveMeetingController()
        defer { controller.cancel() }
        controller.start(session: session, bridge: bridge, modelName: "base", speechLanguage: "en", notesLanguage: "uk", configuration: configuration)
        let samples = [Float](repeating: 0, count: 16_000)
        #expect(controller.buffer.offer(samples: samples, source: .mic, start: 0))
        #expect(controller.buffer.offer(samples: samples, source: .system, start: 0))
        await controller.stop(finalOffset: 1, sources: [.mic, .system], timeout: 3)
        #expect(Set(controller.model.document.turns.map(\.source)) == Set([.mic, .system]))
        #expect(controller.model.document.turns.count == 2)
        #expect(!controller.model.document.isRecording)
        #expect(!controller.isRunning)
        #expect(controller.model.document.warnings.isEmpty)
        let saved = LiveMeetingModel()
        try saved.load(audioPath: session.audioPath)
        #expect(saved.document.turns.count == 2)
        let previous = controller.model
        var nextSession = session
        nextSession.audioPath = directory.appendingPathComponent("next.wav").path
        controller.start(session: nextSession, bridge: bridge, modelName: "base", speechLanguage: "en", notesLanguage: "en", configuration: configuration)
        #expect(previous.document.turns.count == 2)
        #expect(controller.model !== previous)
        #expect(controller.model.document.turns.isEmpty)
    }

    @Test("worker failure becomes visible without leaving a live drain task running")
    func failureStopsLiveOnly() async throws {
        let (directory, bridge, session) = try fixture(script: "import json\nprint(json.dumps({'type':'error','message':'Synthetic unavailable model'}),flush=True)\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LiveMeetingController()
        defer { controller.cancel() }
        controller.start(session: session, bridge: bridge, modelName: "base", speechLanguage: "en", notesLanguage: "en", configuration: configuration)
        let deadline = Date().addingTimeInterval(2)
        while !controller.model.document.warnings.contains(where: { $0.contains("Synthetic unavailable model") }) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!controller.isRunning)
        #expect(controller.model.document.warnings.contains { $0.contains("Synthetic unavailable model") })
        #expect(controller.model.document.isRecording)
        controller.model.addManualNote("Recording and notes continue", kind: .note)
        #expect(controller.model.document.topics.contains { $0.memos.contains { $0.text == "Recording and notes continue" } })
    }
    @Test("preparation cannot replace live ownership and cancellation cannot clear a new worker")
    func preparationOwnership() async throws {
        let script = """
        import sys,json,time,base64
        print(json.dumps({'type':'ready'}),flush=True)
        if 'prepare-live-model' in sys.argv: time.sleep(10)
        else:
            for line in sys.stdin:
                r=json.loads(line)
                if r.get('type')=='stop': break
                print(json.dumps({'type':'turn','id':r['id'],'source':r['source'],'start':r['start'],'end':r['start']+len(base64.b64decode(r['pcm_f32le']))/64000,'text':'After cancellation','final':True}),flush=True)
                print(json.dumps({'type':'chunk_done','id':r['id']}),flush=True)
        """
        let (directory, bridge, session) = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LiveMeetingController()
        defer { controller.cancel() }
        controller.prepareModel(bridge: bridge, modelName: "base")
        try await Task.sleep(for: .milliseconds(80))
        controller.start(session: session, bridge: bridge, modelName: "base", speechLanguage: "en", notesLanguage: "en", configuration: configuration)
        #expect(controller.model.document.sessionID.isEmpty)
        #expect(controller.isPreparing)
        controller.cancel()
        controller.start(session: session, bridge: bridge, modelName: "base", speechLanguage: "en", notesLanguage: "en", configuration: configuration)
        #expect(controller.buffer.offer(samples: [Float](repeating: 0, count: 16_000), source: .system, start: 0))
        await controller.stop(finalOffset: 1, sources: [.system], timeout: 3)
        #expect(controller.model.document.turns.count == 1)
    }

    @Test("three-second partial stays provisional and the final commits the same window once")
    func previewRouting() async throws {
        let script = """
        import sys,json,base64
        print(json.dumps({'type':'ready'}),flush=True)
        for line in sys.stdin:
            r=json.loads(line)
            if r.get('type')=='stop': break
            event={'type':'turn' if r['final'] else 'partial','id':r['id'],'source':r['source'],'start':r['start'],'end':r['start']+len(base64.b64decode(r['pcm_f32le']))/64000,'text':'Committed' if r['final'] else 'Provisional','final':r['final']}
            print(json.dumps(event),flush=True)
            print(json.dumps({'type':'chunk_done','id':r['id']}),flush=True)
        """
        let (directory, bridge, session) = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LiveMeetingController()
        defer { controller.cancel() }
        controller.start(session: session, bridge: bridge, modelName: "base", speechLanguage: "en", notesLanguage: "en", configuration: configuration)
        let samples = [Float](repeating: 0, count: 16_000)
        for offset in 0..<3 { #expect(controller.buffer.offer(samples: samples, source: .mic, start: Double(offset))) }
        let deadline = Date().addingTimeInterval(2)
        while controller.model.partials[.mic] == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(controller.model.partials[.mic] == "Provisional")
        #expect(controller.model.document.turns.isEmpty)
        for offset in 3..<6 { #expect(controller.buffer.offer(samples: samples, source: .mic, start: Double(offset))) }
        await controller.stop(finalOffset: 6, sources: [.mic], timeout: 3)
        #expect(controller.model.document.turns.map(\.id) == ["mic-0"])
        #expect(controller.model.document.turns.first?.text == "Committed")
        #expect(controller.model.partials[.mic] == nil || controller.model.partials[.mic] == "")
    }

    @Test("backlog status appears while inference is blocked and stop stays bounded")
    func lagDuringInference() async throws {
        let script = """
        import sys,json,time,os
        print(json.dumps({'type':'ready'}),flush=True)
        for line in sys.stdin:
            open(os.environ.get('LAG_MARKER') or sys.argv[-1],'w').write('blocked')
            time.sleep(30)
        """
        let (directory, bridge, session) = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("blocked.marker")
        setenv("LAG_MARKER", marker.path, 1)
        defer { unsetenv("LAG_MARKER") }
        let controller = LiveMeetingController()
        defer { controller.cancel() }
        controller.start(session: session, bridge: bridge, modelName: "base", speechLanguage: "en", notesLanguage: "en", configuration: configuration)
        let samples = [Float](repeating: 0, count: 16_000)
        // Six seconds on one source produce the first (blocking) request.
        for offset in 0..<3 { #expect(controller.buffer.offer(samples: samples, source: .system, start: Double(offset))) }
        var deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(FileManager.default.fileExists(atPath: marker.path), "worker never reached blocked inference")
        // Only now, with the drain loop awaiting inference, build a >12s backlog.
        for offset in 3..<16 { _ = controller.buffer.offer(samples: samples, source: .system, start: Double(offset)) }
        deadline = Date().addingTimeInterval(3)
        while !controller.status.contains("behind") && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(controller.status.contains("behind"))
        await controller.stop(finalOffset: 16, sources: [.system], timeout: 0.3)
        #expect(!controller.isRunning)
        #expect(controller.model.document.warnings.contains { $0.contains("timed out") })
        #expect(!controller.status.contains("behind"))
    }
}
