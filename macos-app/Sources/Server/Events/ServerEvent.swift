import Foundation
import os

/// What `GET /api/events` tells open pages. Payloads carry ids and state only, never
/// secrets or file paths; the live view gets committed turn text, which it shows anyway.
///
/// | Event | Payload | Source |
/// |---|---|---|
/// | `hello` | `{online, recording, problem?}` | first frame of every connection |
/// | `recording` | `{state, problem?}` | `AppModel` state, transition, playback block, last error |
/// | `liveDocument` | `{sessionID}` | live map or runtime change (≤ 4/s) |
/// | `liveTurn` | `LiveTurn` | each committed live turn |
/// | `partial` | `{source, text}` | partial live speech (≤ 4/s per channel) |
/// | `spend` | `LiveNotesUsage` | live-notes usage change |
/// | `connectivity` | `{online}` | `ConnectivityMonitor` |
/// | `sessionChanged` | `{id}` | any session record change; API rename, vault, delete, re-process |
/// | `catalog` | `{}` | catalog refresh started, finished or failed |
/// | `settings` | `{}` | settings, secrets or model downloads changed |
enum ServerEvent: Sendable, Equatable {
    /// First frame of every connection, so a reconnecting page resyncs.
    case hello(recording: String, online: Bool, problem: String? = nil)
    /// `RecordingPhase` raw value; `problem` is why the last start or stop failed.
    case recording(state: String, problem: String? = nil)
    case liveDocument(sessionID: String)
    case liveTurn(LiveTurn)
    case partial(source: String, text: String)
    case spend(LiveNotesUsage)
    case connectivity(online: Bool)
    case sessionChanged(id: String)
    case catalog
    case settings

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
        }
    }

    /// The `data:` JSON object.
    fileprivate func payload(_ encoder: JSONEncoder) throws -> Data {
        switch self {
        case .hello(let recording, let online, let problem):
            try encoder.encode(Hello(online: online, recording: recording, problem: problem))
        case .recording(let state, let problem):
            try encoder.encode(Recording(state: state, problem: problem))
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
        }
    }

    private struct Hello: Encodable {
        let online: Bool
        let recording: String
        let problem: String?
    }

    private struct Recording: Encodable {
        let state: String
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
