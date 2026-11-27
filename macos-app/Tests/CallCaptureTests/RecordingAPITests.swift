import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

@Suite struct RecordingAPITests {
    @Test func startAnswersAcceptedAndAsksTheAppOnce() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let response = try await api.request(client, "/api/recording/start", method: .post)
            #expect(response.status == .accepted, "\(bodyText(response))")
            #expect(try jsonObject(response)["started"] as? Bool == true)
        }
        #expect(api.backend.recordingRequests == [.starting])
    }

    @Test func stopAnswersAccepted() async throws {
        let api = SignedInAPI()
        api.backend.setRecordingSituation(state: .recording)
        try await api.run { client in
            let response = try await api.request(client, "/api/recording/stop", method: .post)
            #expect(response.status == .accepted, "\(bodyText(response))")
        }
        #expect(api.backend.recordingRequests == [.stopping])
    }

    @Test(arguments: [
        ("/api/recording/start", AppState.recording, nil as RecordingTransition?, false, "already_recording"),
        ("/api/recording/stop", AppState.idle, nil, false, "not_recording"),
        ("/api/recording/start", AppState.transcribing, nil, false, "processing"),
        ("/api/recording/start", AppState.idle, RecordingTransition.starting, false, "busy"),
        ("/api/recording/stop", AppState.recording, RecordingTransition.stopping, false, "busy"),
        ("/api/recording/start", AppState.idle, nil, true, "live_model_downloading"),
    ])
    func conflictsAreExplained(
        path: String, state: AppState, transition: RecordingTransition?, preparing: Bool, code: String
    ) async throws {
        let api = SignedInAPI()
        api.backend.setRecordingSituation(state: state, transition: transition, livePreparing: preparing)
        try await api.run { client in
            let response = try await api.request(client, path, method: .post)
            #expect(response.status == .conflict, "\(bodyText(response))")
            let body = try jsonObject(response)
            #expect(body["error"] as? String == code)
            let message = body["message"] as? String ?? ""
            #expect(message.hasSuffix("."), "a sentence: \(message)")
        }
        #expect(api.backend.recordingRequests.isEmpty)
    }

    @Test func crossOriginStartIsRefused() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let response = try await client.execute(
                uri: "/api/recording/start", method: .post,
                headers: [.cookie: api.cookie, .origin: "https://evil.example"])
            #expect(response.status == .forbidden)
        }
        #expect(api.backend.recordingRequests.isEmpty)
    }

    @Test func systemReportsTheRecordingState() async throws {
        let api = SignedInAPI()
        let status = RecordingStatus.make(
            state: .idle, playbackBlocked: false, transition: .starting, livePreparing: false, lastError: nil)
        api.backend.setStatus(SystemStatus(online: true, version: "test", recordingStatus: status))
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/system"))
            #expect(body["recordingState"] as? String == "starting")
            #expect(body["recording"] as? Bool == true)
            #expect(jsonValue(body, "button.action") as? String == "start")
            #expect(jsonValue(body, "button.enabled") as? Bool == false)
        }
    }
}

@Suite struct RecordingControlTests {
    @Test func checkMirrorsTheMenuButton() {
        typealias E = RecordingRequestError
        #expect(E.check(.starting, state: .idle, transition: nil, livePreparing: false) == nil)
        #expect(E.check(.starting, state: .error, transition: nil, livePreparing: false) == nil)
        #expect(E.check(.stopping, state: .recording, transition: nil, livePreparing: false) == nil)
        #expect(E.check(.starting, state: .recording, transition: nil, livePreparing: false) == .alreadyRecording)
        #expect(E.check(.stopping, state: .idle, transition: nil, livePreparing: false) == .notRecording)
        #expect(E.check(.stopping, state: .error, transition: nil, livePreparing: false) == .notRecording)
        #expect(E.check(.starting, state: .transcribing, transition: nil, livePreparing: false) == .processing)
        #expect(E.check(.stopping, state: .transcribing, transition: nil, livePreparing: false) == .notRecording)
        #expect(E.check(.starting, state: .idle, transition: .starting, livePreparing: false) == .inTransition(.starting))
        #expect(E.check(.stopping, state: .recording, transition: .stopping, livePreparing: false) == .inTransition(.stopping))
        #expect(E.check(.starting, state: .idle, transition: nil, livePreparing: true) == .livePreparing)
    }

    @Test func phaseFollowsStateAndTransitionOnly() {
        typealias P = RecordingPhase
        #expect(P.derive(state: .idle, transition: nil) == .idle)
        #expect(P.derive(state: .error, transition: nil) == .idle)
        #expect(P.derive(state: .idle, transition: .starting) == .starting)
        #expect(P.derive(state: .recording, transition: .starting) == .starting)
        #expect(P.derive(state: .recording, transition: nil) == .recording)
        #expect(P.derive(state: .recording, transition: .stopping) == .stopping)
        #expect(P.derive(state: .transcribing, transition: nil) == .processing)
    }

    /// Every situation the menu can show: the button the web gets (`RecordingStatus.button`)
    /// is the menu's button, the menu's button is the rule ContentView used to have
    /// inline, and the API accepts exactly the action that is offered.
    @Test func webButtonOffersWhatTheMenuOffers() {
        let states: [AppState] = [.idle, .recording, .transcribing, .error]
        let transitions: [RecordingTransition?] = [nil, .starting, .stopping]
        for state in states {
            for blocked in [false, true] {
                for transition in transitions {
                    for preparing in [false, true] {
                        let status = RecordingStatus.make(
                            state: state, playbackBlocked: blocked, transition: transition, livePreparing: preparing,
                            lastError: nil)
                        let menu = RecordingButton.current(state: state, transition: transition, livePreparing: preparing)
                        let where_ = "\(state) blocked:\(blocked) \(String(describing: transition)) preparing:\(preparing)"
                        #expect(status.button == menu, "\(where_)")
                        // ContentView before the rule was shared: Stop when recording; disabled while
                        // processing, while the live model downloads, or during a start/stop.
                        #expect((menu.action == .stopping) == (state == .recording), "\(where_)")
                        #expect(menu.enabled == !(state == .transcribing || preparing || transition != nil), "\(where_)")
                        let offered = RecordingRequestError.check(
                            menu.action, state: state, transition: transition, livePreparing: preparing)
                        #expect((offered == nil) == menu.enabled, "\(where_)")
                        let other: RecordingTransition = menu.action == .starting ? .stopping : .starting
                        #expect(
                            RecordingRequestError.check(other, state: state, transition: transition, livePreparing: preparing)
                                != nil, "\(where_)")
                    }
                }
            }
        }
    }

    @Test func failedStopOffersRecordAndKeepsPlaybackOff() {
        let status = RecordingStatus.make(
            state: .error, playbackBlocked: true, transition: nil, livePreparing: false, lastError: "Stop failed.")
        #expect(status.phase == .idle)
        #expect(status.button == RecordingButton(action: .starting, refusal: nil))
        #expect(status.playbackBlocked)
        #expect(status.problem == "Stop failed.")
    }

    @Test func processingDuringACaptureDisablesTheButtonAndAfterwardsOffersRecord() {
        // Task 5 #5: native Transcribe while recording, then the run ends with the tap still running.
        let during = RecordingStatus.make(
            state: .transcribing, playbackBlocked: true, transition: nil, livePreparing: false, lastError: nil)
        #expect(!during.button.enabled)
        #expect(during.playbackBlocked)
        let after = RecordingStatus.make(
            state: .idle, playbackBlocked: true, transition: nil, livePreparing: false, lastError: nil)
        #expect(after.button == RecordingButton(action: .starting, refusal: nil))
        #expect(after.playbackBlocked)
    }

    @Test func playbackIsBlockedFromStartToStop() {
        func blocked(_ state: AppState, _ flag: Bool, _ transition: RecordingTransition?) -> Bool {
            RecordingStatus.make(state: state, playbackBlocked: flag, transition: transition, livePreparing: false, lastError: nil)
                .playbackBlocked
        }
        #expect(blocked(.idle, false, .starting))
        #expect(blocked(.recording, true, nil))
        #expect(blocked(.recording, true, .stopping))
        #expect(blocked(.error, true, nil))
        #expect(!blocked(.idle, false, nil))
        #expect(!blocked(.error, false, nil))
        #expect(!blocked(.transcribing, false, nil))
    }

    @Test func downloadingLiveModelDisablesRecordWithTheReason() {
        let status = RecordingStatus.make(
            state: .idle, playbackBlocked: false, transition: nil, livePreparing: true, lastError: nil)
        #expect(!status.button.enabled)
        #expect(status.button.reason == RecordingRequestError.livePreparing.message)
    }
}
