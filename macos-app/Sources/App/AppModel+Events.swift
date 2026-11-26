import Foundation

/// Where `AppModel` feeds the web UI's events stream:
/// - recording phase and its problem: `didSet` on `state`, `playbackBlocked`,
///   `recordingTransition` and `lastError` (some are set off the main actor);
/// - session records: `SessionManager.onSessionChange` (every create/update/delete);
/// - connectivity and the catalog: observed main-actor state;
/// - the live meeting: `LiveEventWatcher` over the controller's current model.
@available(macOS 14.2, *)
extension AppModel {
    /// The recording state the API reports (`GET /api/system`, `hello`, `recording`).
    var recordingPhase: RecordingPhase {
        RecordingPhase.derive(state: state, playbackBlocked: playbackBlocked, transition: recordingTransition)
    }

    /// Why the last start, stop or run failed, while the app shows it as an error.
    var recordingProblem: String? { state == .error ? lastError : nil }

    @MainActor func startPublishingEvents() {
        let hub = events
        sessionManager.onSessionChange = { id in hub.post(.sessionChanged(id: id)) }
        let connectivity = self.connectivity
        let liveMeeting = self.liveMeeting
        eventWatchers = [
            ChangeWatcher(read: { connectivity.isOnline }) { hub.post(.connectivity(online: $0)) },
            ChangeWatcher(read: { [weak self] in self?.catalogToken ?? "" }) { _ in hub.post(.catalog) },
            LiveEventWatcher(
                model: { liveMeeting.model },
                extra: { [weak self] in
                    _ = (liveMeeting.status, liveMeeting.isRunning, self?.liveMicrophoneEnabled)
                },
                post: { hub.post($0) }),
        ]
    }

    /// Sends `recording` when the phase or its problem changed. Safe from any thread.
    func recordingStateDidChange() {
        let phase = recordingPhase
        let problem = recordingProblem
        let key = phase.rawValue + "\u{1F}" + (problem ?? "")
        let changed = publishedRecording.withLock { last -> Bool in
            guard last != key else { return false }
            last = key
            return true
        }
        if changed { events.post(.recording(state: phase.rawValue, problem: problem)) }
    }

    /// Changes whenever the catalog, its refresh state or its problem does.
    private var catalogToken: String {
        let fetched = catalogSnapshot.map { "\($0.modelsFetchedAt.timeIntervalSince1970)|\($0.scoresFetchedAt?.timeIntervalSince1970 ?? 0)|\($0.models.count)" } ?? "none"
        return "\(fetched)|\(catalogRefreshing)|\(catalogProblem ?? "")"
    }
}
