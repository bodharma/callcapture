import Foundation
import Observation

/// Owns only live processing. Failure never changes the recording state.
@MainActor @Observable
final class LiveMeetingController {
    private(set) var model = LiveMeetingModel()
    private(set) var status = "Local speech is off"
    private(set) var isRunning = false
    private(set) var isPreparing = false
    private(set) var buffer = LivePCMBuffer()
    @ObservationIgnored private var worker: LiveWorkerProcess?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var lagTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var workerReady = false
    @ObservationIgnored private var eventsFinished = true
    @ObservationIgnored private var acceptedEnds: [LiveAudioSource: Double] = [:]

    nonisolated init() {}

    func start(session: Session, bridge: PythonBridge, modelName: String,
               speechLanguage: String, notesLanguage: String, configuration: LiveNotesConfiguration) {
        guard !isPreparing else { status = "Wait for the model download or cancel it before starting live speech."; return }
        guard !isRunning && !model.document.isRecording else { return }
        buffer = LivePCMBuffer()
        stopping = false
        workerReady = false
        acceptedEnds = [:]
        do {
            let nextModel = LiveMeetingModel()
            try nextModel.begin(sessionID: session.id, title: session.title, audioPath: session.audioPath,
                            speechLanguage: speechLanguage, notesLanguage: notesLanguage, configuration: configuration)
            model = nextModel
            let worker = LiveWorkerProcess(configuration: try bridge.workerConfiguration(
                arguments: ["live", "--model", modelName, "--language", speechLanguage]))
            self.worker = worker
            let events = try worker.start()
            isRunning = true
            eventsFinished = false
            status = "Loading local speech model…"
            eventTask = Task { [weak self] in
                do {
                    for try await event in events {
                        guard self?.worker === worker else { return }
                        self?.receive(event)
                    }
                } catch { if self?.worker === worker { self?.fail(error.localizedDescription) } }
                if self?.worker === worker { self?.eventsFinished = true }
            }
            // Independent of the drain loop, which is blocked while the worker infers.
            lagTask = Task { [weak self, buffer] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, self.worker === worker, self.isRunning else { return }
                    let behind = "Local speech is behind; recording continues"
                    if self.stopping || !self.workerReady { continue }
                    if buffer.queuedSamples > 16_000 * 12 { self.status = behind }
                    else if self.status == behind { self.status = "Local speech active · You / Remote audio" }
                }
            }
            drainTask = Task { [weak self, buffer] in
                var windows = LivePCMWindowBuilder()
                do {
                    while !Task.isCancelled && self?.worker === worker {
                        if let chunk = buffer.take() {
                            let result = windows.append(chunk)
                            self?.acceptedEnds[chunk.source] = chunk.start + Double(chunk.samples.count) / 16_000
                            if let gap = result.gap { self?.model.markGap(gap) }
                            for window in result.chunks {
                                try await worker.transcribe(window, id: window.requestID)
                            }
                        } else if self?.stopping == true {
                            for tail in windows.flush() {
                                try await worker.transcribe(tail, id: tail.requestID)
                            }
                            try await worker.finish(timeout: 2)
                            break
                        } else {
                            try await Task.sleep(for: .milliseconds(50))
                        }
                    }
                } catch is CancellationError { worker.cancel() }
                catch { if self?.worker === worker { self?.fail(error.localizedDescription) }; worker.cancel() }
                if self?.worker === worker { self?.isRunning = false }
            }
        } catch { fail(error.localizedDescription) }
    }

    private func receive(_ event: LiveWorkerEvent) {
        switch event {
        case .ready: workerReady = true; status = "Local speech active · You / Remote audio"
        case .turn(let turn): model.ingest(turn); model.updatePartial(source: turn.source, text: "")
        case .partial(let source, let text): model.updatePartial(source: source, text: text)
        case .failure(let message): fail(message)
        case .exited(let code):
            if !stopping { fail("Local speech exited (\(code)); recording continues. Stop to retain and re-process saved audio.") }
        case .chunkDone: break
        }
    }

    private func fail(_ message: String) {
        lagTask?.cancel()
        status = message
        model.markGap(message)
        drainTask?.cancel()
        worker?.cancel()
        isRunning = false
    }

    /// Capture has stopped before this is called, so final offsets are stable.
    func stop(finalOffset: Double, sources: [LiveAudioSource], timeout: Double = 12) async {
        stopping = true
        status = "Finishing accepted local audio…"
        let deadline = Date().addingTimeInterval(timeout)
        while (isRunning || !eventsFinished) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if isRunning || !eventsFinished {
            model.markGap("Live stop timed out; some accepted tail audio remains untranscribed. Saved recording retained.")
            drainTask?.cancel()
            worker?.cancel()
            isRunning = false
        }
        for source in sources {
            let accepted = acceptedEnds[source] ?? 0
            if finalOffset - accepted > 0.02 {
                model.markGap("\(source.rawValue) live audio gap at \(String(format: "%.2f", accepted))–\(String(format: "%.2f", finalOffset))s; saved recording retained.")
            }
        }
        lagTask?.cancel()
        eventTask?.cancel()
        model.end()
        status = "Live map saved · recording retained"
        worker = nil
    }

    func prepareModel(bridge: PythonBridge, modelName: String) {
        guard !isPreparing && !isRunning else { return }
        isPreparing = true
        status = "Downloading local model \(modelName)…"
        preparationTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { isPreparing = false } }
            do {
                let worker = LiveWorkerProcess(configuration: try bridge.workerConfiguration(
                    arguments: ["prepare-live-model", "--model", modelName]))
                self.worker = worker
                defer {
                    worker.cancel()
                    if self.worker === worker { self.worker = nil }
                }
                let events = try worker.start()
                for try await event in events {
                    guard !Task.isCancelled && self.worker === worker else { break }
                    switch event {
                    case .ready: status = "Local model \(modelName) is ready"
                    case .failure(let message): status = message
                    default: break
                    }
                }
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }

    func cancel() {
        lagTask?.cancel()
        drainTask?.cancel()
        eventTask?.cancel()
        preparationTask?.cancel()
        worker?.cancel()
        worker = nil
        isRunning = false
        isPreparing = false
        if model.document.isRecording { model.markGap("Live processing interrupted; original recording retained."); model.end() }
    }
}
