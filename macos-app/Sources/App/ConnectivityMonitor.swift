import Foundation
import Network
import Observation

/// Whether the Mac has a usable network path. A hint, not a guarantee: requests still
/// report their own failures (host unreachable, 401, 404).
@MainActor
@Observable
final class ConnectivityMonitor {
    static let offlineReason = "Offline — this needs an internet connection."

    private(set) var isOnline = true
    @ObservationIgnored private let monitor: NWPathMonitor?

    /// Nonisolated so the non-actor `AppModel` can own one.
    nonisolated init(startMonitoring: Bool = true) {
        guard startMonitoring else { monitor = nil; return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.setOnline(online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.callcapture.connectivity"))
    }

    func setOnline(_ online: Bool) {
        if isOnline != online { isOnline = online }
    }
}

/// What the app may do with the network in its current state.
enum NetworkPolicy {
    static let cloudWaitMessage = "Saved. Cloud transcription waits for internet — or choose local Whisper in Settings and press Transcribe."

    enum Decision: Equatable {
        case transcribe
        /// Local Whisper while offline with OpenRouter notes: transcribe, skip the LLM.
        case transcribeOffline
        case wait(String)

        var workerEnvironment: [String: String] {
            self == .transcribeOffline ? ["LLM_OFFLINE": "1"] : [:]
        }
    }

    /// Non-nil when transcribing with `engine` needs a network the Mac does not have.
    static func blockReason(engine: String, isOnline: Bool) -> String? {
        !isOnline && engine == TranscriptionEngine.remote.rawValue ? ConnectivityMonitor.offlineReason : nil
    }

    static func decision(engine: String, provider: LLMProvider, isOnline: Bool) -> Decision {
        guard !isOnline else { return .transcribe }
        if engine == TranscriptionEngine.remote.rawValue { return .wait(cloudWaitMessage) }
        return provider == .openrouter ? .transcribeOffline : .transcribe
    }
}
