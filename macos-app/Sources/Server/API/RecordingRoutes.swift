import Foundation
import Hummingbird

/// `POST /api/recording/start` and `POST /api/recording/stop` → 202 `{"started": true}`
/// once the app has accepted the request; progress (and a failed start, e.g. a
/// refused microphone permission) arrives as `recording` events. A request the app
/// can't act on now is 409 `{"error": code, "message": …}` with the code from
/// `RecordingRequestError`. Permission prompts still appear natively.
func addRecordingRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.post("api/recording/start") { _, _ in
        await recordingResult { try await backend.startRecording() }
    }
    router.post("api/recording/stop") { _, _ in
        await recordingResult { try await backend.stopRecording() }
    }
}

private func recordingResult(_ request: () async throws -> Void) async -> Response {
    do {
        try await request()
        return APIResponse.json(StartedDTO(), status: .accepted)
    } catch let refusal as RecordingRequestError {
        return APIResponse.error(.conflict, refusal.code, message: refusal.message)
    } catch {
        return APIResponse.from(error)
    }
}
