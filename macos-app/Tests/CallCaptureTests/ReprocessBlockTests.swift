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
}
