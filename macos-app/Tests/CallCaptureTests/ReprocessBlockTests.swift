import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

/// Why Transcribe / Re-process / Retry is off before any click, and the session DTO field that carries it.
@Suite struct ReprocessBlockTests {
    private static let cloudOffline = NetworkPolicy.blockReason(engine: "remote", isOnline: false)!
        + " This session uses cloud transcription."

    // MARK: ReprocessPolicy

    @Test func cloudSessionOfflineIsBlockedWithTheAppsWording() {
        #expect(ReprocessPolicy.offlineReason(status: "transcribed", engine: "remote", isOnline: false) == Self.cloudOffline)
    }

    @Test(arguments: ["completed", "transcribed", "error", "failed", "interrupted"])
    func everyStatusWithTheButtonIsCovered(status: String) {
        #expect(ReprocessPolicy.offlineReason(status: status, engine: "remote", isOnline: false) == Self.cloudOffline)
    }

    @Test func onlineOrLocalEngineIsNotBlocked() {
        #expect(ReprocessPolicy.offlineReason(status: "transcribed", engine: "remote", isOnline: true) == nil)
        #expect(ReprocessPolicy.offlineReason(status: "transcribed", engine: "local_whisper", isOnline: false) == nil)
    }

    @Test(arguments: ["recording", "transcribing"])
    func statusesWithoutTheButtonHaveNoReason(status: String) {
        #expect(ReprocessPolicy.offlineReason(status: status, engine: "remote", isOnline: false) == nil)
    }

    // MARK: GET /api/sessions/:id

    private static func api(engine: String?, online: Bool) -> SignedInAPI {
        let session = Session(
            id: "S1", title: "Weekly sync", sourceApp: "Zoom", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            audioPath: "/nonexistent/S1.wav", engineUsed: engine, status: "transcribed")
        let backend = FakeBackend(sessions: [session])
        backend.setOnline(online)
        return SignedInAPI(backend: backend)
    }

    @Test func detailCarriesTheReasonWhileACloudSessionIsOffline() async throws {
        let api = Self.api(engine: "remote", online: false)
        try await api.run { client in
            let response = try await api.request(client, "/api/sessions/S1")
            #expect(response.status == .ok)
            #expect(try jsonObject(response)["reprocessBlocked"] as? String == Self.cloudOffline)
        }
    }

    @Test func detailOmitsTheReasonOnlineOrForLocalSessions() async throws {
        for (engine, online) in [("remote", true), ("local_whisper", false)] {
            let api = Self.api(engine: engine, online: online)
            try await api.run { client in
                let body = try jsonObject(try await api.request(client, "/api/sessions/S1"))
                #expect(body["reprocessBlocked"] == nil, "engine \(engine), online \(online)")
            }
        }
    }

    @Test func sessionWithoutAnEngineUsesTheConfiguredDefault() async throws {
        let api = Self.api(engine: nil, online: false)
        api.backend.setDefaultEngine("remote")
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/sessions/S1"))
            #expect(body["reprocessBlocked"] as? String == Self.cloudOffline)
        }
    }

    // MARK: What the app is doing, before any click

    @Test func detailSaysToStopTheRecordingFirst() async throws {
        let api = Self.api(engine: "local_whisper", online: true)
        api.backend.setActivity(state: .recording, recordingSessionID: "S2")
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/sessions/S1"))
            #expect(body["reprocessBlocked"] as? String == "Stop the recording before processing a session.")
        }
    }

    @Test func detailSaysAnotherSessionIsProcessed() async throws {
        let api = Self.api(engine: "local_whisper", online: true)
        api.backend.setActivity(state: .transcribing)
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/sessions/S1"))
            #expect(body["reprocessBlocked"] as? String == "Another session is being processed. Try again when it finishes.")
            let refused = try await api.request(client, "/api/sessions/S1/reprocess", method: .post)
            #expect(refused.status == .conflict)
            #expect(bodyText(refused) == #"{"error":"Another session is being processed. Try again when it finishes."}"#)
        }
        #expect(api.backend.reprocessedIDs.isEmpty)
    }

    /// An empty stored engine counts as none, as in `JobRequest.transcribe`.
    @Test func sessionWithAnEmptyEngineUsesTheConfiguredDefault() async throws {
        let api = Self.api(engine: "", online: false)
        api.backend.setDefaultEngine("remote")
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/sessions/S1"))
            #expect(body["reprocessBlocked"] as? String == Self.cloudOffline)
        }
    }
}
