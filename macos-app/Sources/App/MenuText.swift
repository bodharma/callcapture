import Foundation

/// One input channel and what it is doing, shown as text instead of level meters.
struct MenuChannel: Equatable, Identifiable {
    let id: String
    let name: String
    let detail: String
}

/// The signal-room colour a state word is drawn in (see `SignalPalette`).
enum SignalTone: Equatable {
    case rust, soft, amber, signal, ash
}

/// A recent session in the popover; opening it shows `/sessions/<id>` in the archive window.
struct MenuRecentRow: Equatable, Identifiable {
    let id: String
    let date: String
    let title: String
    let state: String
    let tone: SignalTone
}

/// "Now on" while a meeting records with the live map.
struct MenuLiveNow: Equatable {
    let topic: String
    let quote: String?
    let source: String?
}

/// The menu bar popover's wording. Pure, so it is testable without `AppModel`;
/// state words and channel text match the web archive and the compact live panel.
enum MenuText {
    /// The local speech worker, when the meeting uses the live map.
    struct LiveRuntime: Equatable {
        let running: Bool
        let status: String
    }

    static func channels(
        recording: Bool, microphoneOn: Bool, micName: String, outputName: String, live: LiveRuntime?
    ) -> [MenuChannel] {
        let you: String
        let remote: String
        if recording {
            let state = recordingState(live)
            (you, remote) = (microphoneOn ? state : "microphone off", state)
        } else {
            (you, remote) = (microphoneOn ? micName : "microphone off", outputName)
        }
        return [
            MenuChannel(id: "ch.1", name: "You", detail: you),
            MenuChannel(id: "ch.2", name: "Remote", detail: remote),
        ]
    }

    private static func recordingState(_ live: LiveRuntime?) -> String {
        guard let live else { return "recording" }
        guard live.running else { return "recording, not transcribing" }
        return live.status.localizedCaseInsensitiveContains("behind") ? "behind, recording continues" : "listening"
    }

    /// The small status word in the ready header.
    static func header(state: AppState, transition: RecordingTransition?) -> String {
        if state == .error && transition == nil { return "error" }
        switch RecordingPhase.derive(state: state, transition: transition) {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .stopping: return "stopping"
        case .processing: return "processing"
        }
    }

    /// The Record/Stop button's text for `RecordingButton.current`, the rule the web shares.
    static func recordLabel(_ button: RecordingButton, stopMakesNotes: Bool) -> String {
        switch (button.action, button.refusal) {
        case (.starting, .inTransition(.starting)?): return "Starting…"
        case (.starting, _): return "Start recording"
        case (.stopping, .inTransition(.stopping)?): return "Stopping…"
        case (.stopping, _): return stopMakesNotes ? "Stop and make notes" : "Stop recording"
        }
    }

    /// "00:07", "18:42", "1:02:05".
    static func elapsed(_ seconds: Double) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(seconds) : 0
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// What still works offline and what waits, for the amber line.
    static func offlineLine(engine: TranscriptionEngine, provider: LLMProvider) -> String {
        if engine == .remote { return "Offline. Recording works; cloud transcription waits for a connection." }
        if provider == .openrouter {
            return "Offline. Recording and local transcription still work; cloud notes wait for a connection."
        }
        return "Offline. Recording, transcription and notes all run on this Mac."
    }

    /// Same words and tones as the web archive's `sessionState`.
    static func recentRow(_ session: Session, calendar: Calendar) -> MenuRecentRow {
        let parts = calendar.dateComponents([.day, .month], from: session.startedAt)
        let date = String(format: "%02d.%02d", parts.day ?? 0, parts.month ?? 0)
        let (state, tone) = stateWord(session.status)
        return MenuRecentRow(id: session.id, date: date, title: session.title, state: state, tone: tone)
    }

    private static func stateWord(_ status: String) -> (String, SignalTone) {
        switch status {
        case "recording": ("recording", .rust)
        case "transcribing": ("working", .soft)
        case "completed": ("waiting", .amber)
        case "transcribed": ("notes", .signal)
        case "error", "failed": ("failed", .amber)
        case "interrupted": ("interrupted", .ash)
        default: (status, .ash)
        }
    }

    /// The current topic as "parent / child", the last committed turn and where it came from.
    static func nowOn(topics: [ConversationTopic], currentTopicID: String?, lastTurn: LiveTurn?) -> MenuLiveNow? {
        let topic = topics.first { $0.id == currentTopicID }
        let parent = topic?.parentID.flatMap { id in topics.first { $0.id == id } }
        let title = topic.map { topic in parent.map { "\($0.title) / \(topic.title)" } ?? topic.title }
        let source = lastTurn.map { "\($0.source == .mic ? "ch.1" : "ch.2") at \(elapsed($0.start))" }
        return MenuLiveNow(topic: title ?? "Waiting for committed speech", quote: lastTurn?.text, source: source)
    }

    static func deviceNote(followsSystem: Bool) -> String {
        followsSystem ? "Following the Mac's sound settings." : "Using the devices you chose."
    }
}

extension MenuText {
    /// The archive route for a session, with the id kept as one path segment.
    static func sessionPath(_ id: String) -> String {
        let segment = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return "/sessions/" + (id.addingPercentEncoding(withAllowedCharacters: segment) ?? id)
    }
}
