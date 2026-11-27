import Foundation

@testable import CallCapture

/// Recording control and the live map for `FakeBackend`. The refusals and target
/// resolution come from the production checks (`RecordingRequestError.check`,
/// `LiveAction.problem`, `LiveTargetPolicy`), so the API tests exercise the same rules
/// as the app; only the effects are recorded instead.
final class FakeLive: @unchecked Sendable {
    struct Performed: Equatable {
        let action: LiveAction
        let target: LiveTarget
    }

    private let lock = NSLock()
    private var state: AppState = .idle
    private var transition: RecordingTransition?
    private var livePreparing = false
    private var requests: [RecordingTransition] = []
    private var current: ConversationDocument?
    private var performed: [Performed] = []

    var recordingRequests: [RecordingTransition] { lock.withLock { requests } }
    var actions: [Performed] { lock.withLock { performed } }

    func setSituation(state: AppState, transition: RecordingTransition?, livePreparing: Bool) {
        lock.withLock {
            self.state = state
            self.transition = transition
            self.livePreparing = livePreparing
        }
    }

    /// Changes the recording state only (the live model download flag stays).
    func setRecording(state: AppState, transition: RecordingTransition?) {
        lock.withLock {
            self.state = state
            self.transition = transition
        }
    }

    var recording: (state: AppState, transition: RecordingTransition?) { lock.withLock { (state, transition) } }

    /// The active meeting's session id, as the controller's document reports it ("" for none).
    var activeSessionID: String { lock.withLock { current?.sessionID ?? "" } }

    func setCurrent(_ document: ConversationDocument?) { lock.withLock { current = document } }

    func request(_ wanted: RecordingTransition) throws {
        try lock.withLock {
            if let problem = RecordingRequestError.check(
                wanted, state: state, transition: transition, livePreparing: livePreparing)
            {
                throw problem
            }
            requests.append(wanted)
        }
    }

    func currentView() -> LiveView? {
        lock.withLock {
            guard LiveTargetPolicy.viewSource(.current, activeSessionID: current?.sessionID ?? "") == .active
            else { return nil }
            return current.map { document in
                LiveView(
                    document: document, live: document.isRecording, status: "Live notes (en)",
                    processingStatus: "Local speech active · You / Remote audio", error: nil, followsLive: true,
                    selectedTopicID: document.currentTopicID, catchUpText: "", partials: ["system": "and then"],
                    microphoneEnabled: true, speechRunning: document.isRecording)
            }
        }
    }

    /// `saved` is the session's map from disk, for `.session` targets.
    func perform(_ action: LiveAction, on target: LiveTarget, saved: ConversationDocument?) throws
        -> LiveActionOutcome
    {
        try lock.withLock {
            let source = try LiveTargetPolicy.actionSource(
                target, activeSessionID: current?.sessionID ?? "", activeIsRecording: current?.isRecording ?? false,
                savedMapExists: saved != nil)
            guard let document = source == .active ? current : saved else { throw LiveActionError.notFound }
            if let problem = action.problem(in: document) { throw problem }
            performed.append(Performed(action: action, target: target))
            return action == .export ? .exported("/tmp/Weekly-sync-live.md") : .done
        }
    }
}

extension FakeBackend {
    var recordingRequests: [RecordingTransition] { live.recordingRequests }
    var liveActions: [FakeLive.Performed] { live.actions }

    func setRecordingSituation(
        state: AppState, transition: RecordingTransition? = nil, livePreparing: Bool = false
    ) {
        live.setSituation(state: state, transition: transition, livePreparing: livePreparing)
    }

    func setLive(_ document: ConversationDocument?) { live.setCurrent(document) }

    func startRecording() async throws { try live.request(.starting) }
    func stopRecording() async throws { try live.request(.stopping) }

    func liveView(_ target: LiveTarget) async throws -> LiveView? {
        if case .session(let id) = target { _ = try await requireSession(id) }
        switch LiveTargetPolicy.viewSource(target, activeSessionID: live.activeSessionID) {
        case nil: return nil
        case .active: return live.currentView()
        case .saved:
            guard case .session(let id) = target, let document = try await liveDocument(id: id) else {
                throw BackendError.notFound
            }
            return .saved(document, microphoneEnabled: true)
        }
    }

    func performLive(_ action: LiveAction, on target: LiveTarget) async throws -> LiveActionOutcome {
        var saved: ConversationDocument?
        if case .session(let id) = target {
            saved = try await liveDocument(id: id)
        }
        return try live.perform(action, on: target, saved: saved)
    }
}
