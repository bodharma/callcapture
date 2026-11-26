import Foundation
import Observation

/// Turns live-meeting changes into server events:
/// - every committed turn, once, in arrival order → `liveTurn`;
/// - any change to the map or its runtime state → `liveDocument` (at most once per `interval`);
/// - partial speech → `partial` per channel (at most once per `interval`), so a slow
///   page's bounded buffer isn't flooded and recording events stay in it;
/// - live-notes usage → `spend`.
///
/// `model` is read again on every change, so a meeting that replaces the controller's
/// model is followed; `extra` reads any other state that should refresh the view.
@MainActor
final class LiveEventWatcher {
    private let model: @MainActor () -> LiveMeetingModel
    private let post: @Sendable (ServerEvent) -> Void
    private var loops: [ObservationLoop] = []
    private var documentThrottle: TrailingThrottle?
    private var partialThrottle: TrailingThrottle?
    private var sessionID: String
    /// How many of the meeting's `arrivalTurnIDs` (append-only) have been published.
    private var arrivalCursor: Int
    private var sentPartials: [LiveAudioSource: String]
    private var sentUsage: LiveNotesUsage?

    init(
        model: @escaping @MainActor () -> LiveMeetingModel, extra: @escaping @MainActor () -> Void = {},
        post: @escaping @Sendable (ServerEvent) -> Void, interval: Duration = .milliseconds(250)
    ) {
        self.model = model
        self.post = post
        let current = model()
        sessionID = current.document.sessionID
        arrivalCursor = current.document.arrivalTurnIDs.count
        sentPartials = current.partials
        sentUsage = current.document.liveNotesUsage
        documentThrottle = TrailingThrottle(interval: interval) { [weak self] in self?.publishDocument() }
        partialThrottle = TrailingThrottle(interval: interval) { [weak self] in self?.publishPartials() }
        loops = [
            ObservationLoop(track: {
                let live = model()
                _ = (live.document, live.status, live.error, live.followsLive, live.selectedTopicID, live.catchUpText)
                extra()
            }) { [weak self] in self?.mapChanged() },
            ObservationLoop(track: { _ = model().partials }) { [weak self] in self?.partialThrottle?.signal() },
        ]
    }

    func stop() {
        loops.forEach { $0.stop() }
        documentThrottle?.cancel()
        partialThrottle?.cancel()
    }

    private func mapChanged() {
        let document = model().document
        if document.sessionID != sessionID {
            sessionID = document.sessionID
            arrivalCursor = 0
            sentPartials = [:]
            sentUsage = nil
        }
        publishNewTurns(document)
        if let usage = document.liveNotesUsage, usage != sentUsage {
            sentUsage = usage
            post(.spend(usage))
        }
        documentThrottle?.signal()
    }

    private func publishNewTurns(_ document: ConversationDocument) {
        let arrivals = document.arrivalTurnIDs
        guard arrivals.count > arrivalCursor else {
            arrivalCursor = arrivals.count
            return
        }
        let turns = Dictionary(document.turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in arrivals[arrivalCursor...] {
            if let turn = turns[id] { post(.liveTurn(turn)) }
        }
        arrivalCursor = arrivals.count
    }

    private func publishDocument() {
        let id = model().document.sessionID
        if !id.isEmpty { post(.liveDocument(sessionID: id)) }
    }

    private func publishPartials() {
        let current = model().partials
        for source in [LiveAudioSource.mic, .system] where current[source] != sentPartials[source] {
            post(.partial(source: source.rawValue, text: current[source] ?? ""))
        }
        sentPartials = current
    }
}
