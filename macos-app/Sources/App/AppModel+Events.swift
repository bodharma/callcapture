import Foundation

/// Where `AppModel` feeds the web UI's events stream:
/// - recording status: `didSet` on `state`, `playbackBlocked`, `recordingTransition` and
///   `lastError` (some are set off the main actor), plus the live model download flag;
/// - session records: `SessionManager.onSessionChange` (every create/update/delete);
/// - speaker names and saved live maps edited in any window: `ModelFileEvents`;
/// - connectivity, the catalog and settings (any window, the menu): observed main-actor state;
/// - the live meeting: `LiveEventWatcher` over the controller's current model.
@available(macOS 14.2, *)
extension AppModel {
    /// The recording status the API reports (`GET /api/system`, `hello`).
    @MainActor var recordingStatus: RecordingStatus {
        RecordingStatus.make(
            state: state, playbackBlocked: playbackBlocked, transition: recordingTransition,
            livePreparing: liveMeeting.isPreparing, lastError: lastError)
    }

    @MainActor func startPublishingEvents() {
        let hub = events
        sessionManager.onSessionChange = { id in hub.post(.sessionChanged(id: id)) }
        let connectivity = self.connectivity
        let liveMeeting = self.liveMeeting
        let sessions = sessionManager
        ModelFileEvents.forward(to: hub) { audioPath in sessions.sessionID(audioPath: audioPath) }
        eventWatchers = [
            ChangeWatcher(read: { connectivity.isOnline }) { hub.post(.connectivity(online: $0)) },
            ChangeWatcher(read: { [weak self] in self?.catalogToken ?? "" }) { _ in hub.post(.catalog) },
            NativeChangeSources.settings(settingsManager, post: { hub.post($0) }),
            ChangeWatcher(read: { liveMeeting.isPreparing }) { [weak self] preparing in
                self?.recordingStateDidChange(livePreparing: preparing)
            },
            ProgressEventWatcher(
                isActive: { [weak self] in self?.state == .transcribing },
                progress: { [weak self] in self?.pythonBridge.progress ?? 0 },
                sessionID: { sessions.allSessions().first { $0.status == "transcribing" }?.id },
                post: { hub.post($0) }),
            LiveEventWatcher(
                model: { liveMeeting.model },
                extra: { [weak self] in
                    _ = (liveMeeting.status, liveMeeting.isRunning, self?.liveMicrophoneEnabled)
                },
                post: { hub.post($0) }),
        ]
    }

    /// Sends `recording` when anything in the recording status changed. Safe from any
    /// thread: the live model flag comes from the mirror the main actor keeps current.
    func recordingStateDidChange(livePreparing: Bool? = nil) {
        let changed = publishedRecording.withLockUnchecked { box -> RecordingStatus? in
            if let livePreparing { box.livePreparing = livePreparing }
            let status = RecordingStatus.make(
                state: state, playbackBlocked: playbackBlocked, transition: recordingTransition,
                livePreparing: box.livePreparing, lastError: lastError)
            guard status != box.last else { return nil }
            box.last = status
            return status
        }
        if let changed { events.post(.recording(changed)) }
    }

    /// Changes whenever the catalog, its refresh state or its problem does.
    private var catalogToken: String {
        let fetched = catalogSnapshot.map { "\($0.modelsFetchedAt.timeIntervalSince1970)|\($0.scoresFetchedAt?.timeIntervalSince1970 ?? 0)|\($0.models.count)" } ?? "none"
        return "\(fetched)|\(catalogRefreshing)|\(catalogProblem ?? "")"
    }
}

/// What `recordingStateDidChange` remembers between calls.
struct RecordingPublication {
    var livePreparing = false
    var last: RecordingStatus?
}
