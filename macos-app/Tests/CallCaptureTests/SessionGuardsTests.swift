import Foundation
import Testing

@testable import CallCapture

/// The production guards, as pure functions over what the app is doing (`AppActivity`).
/// `AppModelBackend` and `FakeBackend` both call these, so the API tests exercise the same rules.
@Suite struct SessionGuardsTests {
    private static func session(_ status: String, id: String = "S1", engine: String? = nil) -> Session {
        Session(
            id: id, title: "Weekly sync", sourceApp: "Zoom", startedAt: Date(timeIntervalSince1970: 0),
            audioPath: "/nonexistent/\(id).wav", engineUsed: engine, status: status)
    }

    private static let stopFirst = "Stop the recording before processing a session."
    private static let otherRun = "Another session is being processed. Try again when it finishes."
    private static let cloudOffline = NetworkPolicy.blockReason(engine: "remote", isOnline: false)!
        + " This session uses cloud transcription."

    // MARK: Delete

    /// Stale rows (a `transcribing` or `recording` status the app no longer backs) are never a dead end.
    @Test(arguments: ["completed", "transcribed", "error", "failed", "interrupted", "transcribing", "recording"])
    func anIdleAppDeletesAnySession(status: String) {
        #expect(DeletePolicy.problem(for: Self.session(status), activity: AppActivity()) == nil)
    }

    @Test(arguments: [
        AppActivity(state: .recording, recordingSessionID: "S1"),
        AppActivity(state: .idle, transition: .starting, recordingSessionID: "S1"),
        AppActivity(state: .recording, transition: .stopping, recordingSessionID: "S1"),
        // A failed stop: the tap may still be writing the file.
        AppActivity(state: .error, playbackBlocked: true, recordingSessionID: "S1"),
    ])
    func theSessionBeingRecordedIsKept(activity: AppActivity) {
        #expect(DeletePolicy.problem(for: Self.session("recording"), activity: activity) == DeletePolicy.recordingMessage)
    }

    @Test func otherSessionsCanBeDeletedWhileOneRecords() {
        let activity = AppActivity(state: .recording, recordingSessionID: "S2")
        #expect(DeletePolicy.problem(for: Self.session("completed"), activity: activity) == nil)
    }

    @Test func aFailedStartLeavesNoDeadEnd() {
        // The start failed: the row still says "recording", but nothing captures it.
        let activity = AppActivity(state: .error, recordingSessionID: "S1")
        #expect(DeletePolicy.problem(for: Self.session("recording"), activity: activity) == nil)
    }

    @Test func theSessionBeingProcessedIsKept() {
        let activity = AppActivity(state: .transcribing)
        #expect(DeletePolicy.problem(for: Self.session("transcribing"), activity: activity) == DeletePolicy.processingMessage)
        #expect(DeletePolicy.problem(for: Self.session("transcribed"), activity: activity) == nil)
    }

    // MARK: Re-process

    @Test(arguments: [
        AppActivity(state: .recording),
        AppActivity(state: .idle, playbackBlocked: true),
        AppActivity(state: .idle, transition: .starting),
        AppActivity(state: .recording, transition: .stopping),
    ])
    func aRecordingOrAStartOrStopBlocksProcessing(activity: AppActivity) {
        #expect(ReprocessPolicy.problem(for: Self.session("transcribed"), activity: activity) == Self.stopFirst)
    }

    @Test func anotherRunBlocksProcessing() {
        let activity = AppActivity(state: .transcribing)
        #expect(ReprocessPolicy.problem(for: Self.session("completed"), activity: activity) == Self.otherRun)
    }

    @Test func aStatusWithoutTheButtonSaysWhy() {
        #expect(
            ReprocessPolicy.problem(for: Self.session("transcribing"), activity: AppActivity())
                == "This session can't be processed while it is transcribing.")
    }

    @Test func offlineComesLastAndOnlyForCloudSessions() {
        let offline = AppActivity(isOnline: false)
        #expect(ReprocessPolicy.problem(for: Self.session("transcribed", engine: "remote"), activity: offline) == Self.cloudOffline)
        #expect(ReprocessPolicy.problem(for: Self.session("transcribed", engine: "local_whisper"), activity: offline) == nil)
        let recordingOffline = AppActivity(state: .recording, isOnline: false)
        #expect(
            ReprocessPolicy.problem(for: Self.session("transcribed", engine: "remote"), activity: recordingOffline)
                == Self.stopFirst)
    }

    @Test func theButtonReasonIsOnlyForStatusesWithTheButton() {
        let busy = AppActivity(state: .transcribing)
        #expect(ReprocessPolicy.buttonReason(for: Self.session("transcribed"), activity: busy) == Self.otherRun)
        #expect(ReprocessPolicy.buttonReason(for: Self.session("transcribing"), activity: busy) == nil)
        #expect(ReprocessPolicy.buttonReason(for: Self.session("recording"), activity: AppActivity()) == nil)
    }

    // MARK: Engine

    @Test func theSessionsEngineWinsUnlessItIsMissingOrEmpty() {
        #expect(JobRequest.engine(engineUsed: "remote", defaultEngine: "local_whisper") == "remote")
        #expect(JobRequest.engine(engineUsed: nil, defaultEngine: "remote") == "remote")
        #expect(JobRequest.engine(engineUsed: "", defaultEngine: "remote") == "remote")
    }

    // MARK: Progress

    @Test func progressOnlyWhileTheAppProcessesThisSession() {
        let running = AppActivity(state: .transcribing, processingProgress: 0.4)
        #expect(ProcessingProgress.value(for: Self.session("transcribing"), activity: running) == 0.4)
        #expect(ProcessingProgress.value(for: Self.session("transcribed"), activity: running) == nil)
        let stale = AppActivity(state: .idle, processingProgress: 0.4)
        #expect(ProcessingProgress.value(for: Self.session("transcribing"), activity: stale) == nil)
    }

    @Test func progressIsClamped() {
        let over = AppActivity(state: .transcribing, processingProgress: 1.7)
        let under = AppActivity(state: .transcribing, processingProgress: -0.2)
        #expect(ProcessingProgress.value(for: Self.session("transcribing"), activity: over) == 1)
        #expect(ProcessingProgress.value(for: Self.session("transcribing"), activity: under) == 0)
    }

    // MARK: Live targets

    @Test func viewingResolvesToTheActiveMeetingOrTheSavedMap() {
        #expect(LiveTargetPolicy.viewSource(.current, activeSessionID: "") == nil)
        #expect(LiveTargetPolicy.viewSource(.current, activeSessionID: "S1") == .active)
        #expect(LiveTargetPolicy.viewSource(.session("S1"), activeSessionID: "S1") == .active)
        #expect(LiveTargetPolicy.viewSource(.session("S2"), activeSessionID: "S1") == .saved)
        #expect(LiveTargetPolicy.viewSource(.session("S1"), activeSessionID: "") == .saved)
    }

    @Test func actionsNeedARecordingMeetingOrASavedMap() throws {
        #expect(
            try LiveTargetPolicy.actionSource(
                .current, activeSessionID: "S1", activeIsRecording: true, savedMapExists: false) == .active)
        #expect(throws: LiveActionError.noLiveMeeting) {
            try LiveTargetPolicy.actionSource(.current, activeSessionID: "S1", activeIsRecording: false, savedMapExists: true)
        }
        // The meeting just recorded stays the one writer for its own session.
        #expect(
            try LiveTargetPolicy.actionSource(
                .session("S1"), activeSessionID: "S1", activeIsRecording: false, savedMapExists: false) == .active)
        #expect(
            try LiveTargetPolicy.actionSource(
                .session("S2"), activeSessionID: "S1", activeIsRecording: true, savedMapExists: true) == .saved)
        #expect(throws: LiveActionError.notFound) {
            try LiveTargetPolicy.actionSource(.session("S2"), activeSessionID: "S1", activeIsRecording: true, savedMapExists: false)
        }
    }
}
