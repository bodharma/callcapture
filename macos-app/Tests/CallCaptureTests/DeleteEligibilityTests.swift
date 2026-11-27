import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

/// `canDelete` / `deleteBlocked` in the session detail, from what the app is doing
/// (`DeletePolicy`), and `DELETE` refusing with the same words.
@Suite struct DeleteEligibilityTests {
    private static func api(status: String) -> SignedInAPI {
        let session = Session(
            id: "S1", title: "Weekly sync", sourceApp: "Zoom", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            audioPath: "/nonexistent/S1.wav", status: status)
        return SignedInAPI(backend: FakeBackend(sessions: [session]))
    }

    @Test func anIdleAppOffersDelete() async throws {
        let api = Self.api(status: "transcribed")
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/sessions/S1"))
            #expect(body["canDelete"] as? Bool == true)
            #expect(body["deleteBlocked"] == nil)
        }
    }

    /// A row left `transcribing` by a quit is not a dead end: the app isn't processing it.
    @Test func aStaleTranscribingRowCanBeDeleted() async throws {
        let api = Self.api(status: "transcribing")
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/sessions/S1"))
            #expect(body["canDelete"] as? Bool == true)
            let deleted = try await api.request(client, "/api/sessions/S1", method: .delete)
            #expect(deleted.status == .noContent)
        }
        #expect(api.backend.deletedIDs == ["S1"])
    }

    @Test func theSessionBeingProcessedIsKeptWithTheReason() async throws {
        let api = Self.api(status: "transcribing")
        api.backend.setActivity(state: .transcribing)
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/sessions/S1"))
            #expect(body["canDelete"] as? Bool == false)
            #expect(body["deleteBlocked"] as? String == DeletePolicy.processingMessage)
            let refused = try await api.request(client, "/api/sessions/S1", method: .delete)
            #expect(refused.status == .conflict)
            #expect(try jsonObject(refused)["error"] as? String == "busy")
            #expect(try jsonObject(refused)["message"] as? String == DeletePolicy.processingMessage)
        }
        #expect(api.backend.deletedIDs.isEmpty)
    }

    @Test func theSessionBeingRecordedIsKeptWithTheReason() async throws {
        let api = Self.api(status: "recording")
        api.backend.setActivity(state: .recording, recordingSessionID: "S1")
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/sessions/S1"))
            #expect(body["canDelete"] as? Bool == false)
            #expect(body["deleteBlocked"] as? String == DeletePolicy.recordingMessage)
        }
    }

    @Test func listAnswersCarryNoGuards() async throws {
        let api = Self.api(status: "transcribed")
        try await api.run { client in
            let list = bodyText(try await api.request(client, "/api/sessions"))
            #expect(!list.contains("canDelete"))
            #expect(!list.contains("reprocessBlocked"))
        }
    }
}
