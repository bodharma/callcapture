import Foundation
import os

/// What `GET /api/events` tells open pages. Payloads carry ids and state only, never
/// secrets or file paths; the live view gets committed turn text, which it shows anyway.
///
/// | Event | Payload | Source |
/// |---|---|---|
/// | `hello` | `{online, recording, blocked, button, problem?}` | first frame of every connection |
/// | `recording` | `{state, blocked, button, problem?}` | `AppModel` state, transition, playback block, live model download, last error |
/// | `liveDocument` | `{sessionID}` | live map or runtime change (≤ 4/s) |
/// | `liveTurn` | `LiveTurn` | each committed live turn |
/// | `partial` | `{source, text}` | partial live speech (≤ 4/s per channel) |
/// | `spend` | `LiveNotesUsage` | live-notes usage change |
/// | `connectivity` | `{online}` | `ConnectivityMonitor` |
/// | `sessionChanged` | `{id}` | any session record change; API rename, vault, delete, re-process |
/// | `catalog` | `{}` | catalog refresh started, finished or failed |
/// | `settings` | `{}` | settings, secrets or model downloads changed |
/// | `progress` | `{sessionID, value}` | transcription progress, 0…1 (≤ 4/s) |
enum ServerEvent: Sendable, Equatable {
    /// First frame of every connection, so a reconnecting page resyncs.
    case hello(SystemStatus)
    /// The phase (from state and transition only), whether playback would be recorded,
    /// the Record/Stop button exactly as the menu shows it, and the last failure.
    case recording(RecordingStatus)
    case liveDocument(sessionID: String)
    case liveTurn(LiveTurn)
    case partial(source: String, text: String)
    case spend(LiveNotesUsage)
    case connectivity(online: Bool)
    case sessionChanged(id: String)
    case catalog
    case settings
    case progress(sessionID: String, value: Double)

    /// The SSE `event:` name the web client listens for.
    var name: String {
        switch self {
        case .hello: "hello"
        case .recording: "recording"
        case .liveDocument: "liveDocument"
        case .liveTurn: "liveTurn"
        case .partial: "partial"
        case .spend: "spend"
        case .connectivity: "connectivity"
        case .sessionChanged: "sessionChanged"
        case .catalog: "catalog"
        case .settings: "settings"
        case .progress: "progress"
        }
    }

    /// The `data:` JSON object.
    fileprivate func payload(_ encoder: JSONEncoder) throws -> Data {
        switch self {
        case .hello(let status):
            try encoder.encode(
                Hello(
                    online: status.online, recording: status.recordingState, blocked: status.recording,
                    button: status.button, problem: status.problem))
        case .recording(let status):
            try encoder.encode(
                Recording(
                    state: status.phase.rawValue, blocked: status.playbackBlocked,
                    button: RecordingButtonDTO(status.button), problem: status.problem))
        case .liveDocument(let sessionID):
            try encoder.encode(["sessionID": sessionID])
        case .liveTurn(let turn):
            try encoder.encode(turn)
        case .partial(let source, let text):
            try encoder.encode(["source": source, "text": text])
        case .spend(let usage):
            try encoder.encode(usage)
        case .connectivity(let online):
            try encoder.encode(["online": online])
        case .sessionChanged(let id):
            try encoder.encode(["id": id])
        case .catalog, .settings:
            Data("{}".utf8)
        case .progress(let sessionID, let value):
            try encoder.encode(ProgressPayload(sessionID: sessionID, value: value))
        }
    }

    private struct ProgressPayload: Encodable {
        let sessionID: String
        let value: Double
    }

    private struct Hello: Encodable {
        let online: Bool
        let recording: String
        let blocked: Bool
        let button: RecordingButtonDTO
        let problem: String?
    }

    private struct Recording: Encodable {
        let state: String
        let blocked: Bool
        let button: RecordingButtonDTO
        let problem: String?
    }
}

/// `text/event-stream` framing: `event: <name>\ndata: <one line of JSON>\n\n`. JSON
/// escapes newlines inside strings, so the data is always a single line.
enum SSEFrame {
    static let heartbeat = ": hb\n\n"

    private static let logger = Logger(subsystem: "com.callcapture.app", category: "Events")

    static func encode(_ event: ServerEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let json = String(decoding: try event.payload(encoder), as: UTF8.self)
            return "event: \(event.name)\ndata: \(json)\n\n"
        } catch {
            logger.error("Event \(event.name) could not be encoded: \(error.localizedDescription)")
            return "event: \(event.name)\ndata: {}\n\n"
        }
    }
}
