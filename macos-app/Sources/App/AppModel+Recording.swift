import Foundation

/// Recording start/stop shared by the menu and the web UI. The check and the mark
/// happen in one synchronous main-actor step, so the menu and `POST /api/recording/*`
/// can never both start (or both stop) a recording.
@available(macOS 14.2, *)
extension AppModel {
    /// Toggles recording on/off. Creates a new session on start, finalizes capture on stop.
    @MainActor func toggleRecording() async {
        let wanted: RecordingTransition = state == .recording ? .stopping : .starting
        guard let run = try? beginRecordingTransition(wanted) else { return }
        await run.value
    }

    /// Refuses (`RecordingRequestError`) or marks the transition and starts it in the
    /// background; the returned task finishes when the start or stop has.
    @MainActor @discardableResult
    func beginRecordingTransition(_ wanted: RecordingTransition) throws -> Task<Void, Never> {
        if let refusal = RecordingRequestError.check(
            wanted, state: state, transition: recordingTransition, livePreparing: liveMeeting.isPreparing)
        {
            throw refusal
        }
        recordingTransition = wanted
        return Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recordingTransition = nil }
            switch wanted {
            case .starting:
                self.state = .idle
                self.lastError = nil
                await self.startRecording()
                // A live meeting opens its floating panel, whether the menu or the web
                // started it, as the old Live Meeting window did.
                if self.state == .recording && self.liveMeetingEnabled { self.showLivePanel() }
            case .stopping:
                await self.stopRecording()
            }
        }
    }
}
