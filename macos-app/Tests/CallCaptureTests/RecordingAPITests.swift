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
        api.backend.setStatus(
            SystemStatus(online: true, recording: true, version: "test", recordingState: "starting"))
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/system"))
            #expect(body["recordingState"] as? String == "starting")
            #expect(body["recording"] as? Bool == true)
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

    @Test func phaseFollowsTheAppState() {
        typealias P = RecordingPhase
        #expect(P.derive(state: .idle, playbackBlocked: false, transition: nil) == .idle)
        #expect(P.derive(state: .error, playbackBlocked: false, transition: nil) == .idle)
        #expect(P.derive(state: .idle, playbackBlocked: false, transition: .starting) == .starting)
        #expect(P.derive(state: .idle, playbackBlocked: true, transition: .starting) == .starting)
        #expect(P.derive(state: .recording, playbackBlocked: true, transition: .starting) == .starting)
        #expect(P.derive(state: .recording, playbackBlocked: true, transition: nil) == .recording)
        #expect(P.derive(state: .recording, playbackBlocked: true, transition: .stopping) == .stopping)
        // A failed stop leaves the tap possibly running: playback stays blocked.
        #expect(P.derive(state: .error, playbackBlocked: true, transition: nil) == .recording)
        #expect(P.derive(state: .transcribing, playbackBlocked: false, transition: nil) == .processing)
    }

    @Test func playbackIsBlockedFromStartToStop() {
        #expect(RecordingPhase.starting.blocksPlayback)
        #expect(RecordingPhase.recording.blocksPlayback)
        #expect(RecordingPhase.stopping.blocksPlayback)
        #expect(!RecordingPhase.idle.blocksPlayback)
        #expect(!RecordingPhase.processing.blocksPlayback)
    }
}
