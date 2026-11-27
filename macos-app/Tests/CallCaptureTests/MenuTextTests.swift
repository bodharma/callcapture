import Foundation
import Testing

@testable import CallCapture

/// The menu bar popover's wording, kept pure so it is testable without `AppModel`.
@Suite struct MenuTextTests {
    // MARK: Channels

    @Test func readyChannelsNameTheDevices() {
        let lines = MenuText.channels(
            recording: false, microphoneOn: true, micName: "MacBook Pro Microphone",
            outputName: "MacBook Pro Speakers", live: nil)
        #expect(lines == [
            MenuChannel(id: "ch.1", name: "You", detail: "MacBook Pro Microphone"),
            MenuChannel(id: "ch.2", name: "Remote", detail: "MacBook Pro Speakers"),
        ])
    }

    @Test func microphoneOffSaysSo() {
        let ready = MenuText.channels(recording: false, microphoneOn: false, micName: "Mic", outputName: "Out", live: nil)
        #expect(ready[0].detail == "microphone off")
        let recording = MenuText.channels(recording: true, microphoneOn: false, micName: "Mic", outputName: "Out", live: nil)
        #expect(recording[0].detail == "microphone off")
        #expect(recording[1].detail == "recording")
    }

    @Test func recordingWithoutTheLiveMapSaysRecording() {
        let lines = MenuText.channels(recording: true, microphoneOn: true, micName: "Mic", outputName: "Out", live: nil)
        #expect(lines.map(\.detail) == ["recording", "recording"])
    }

    @Test func liveMapStatusFollowsTheSpeechWorker() {
        func details(_ live: MenuText.LiveRuntime) -> [String] {
            MenuText.channels(recording: true, microphoneOn: true, micName: "M", outputName: "O", live: live).map(\.detail)
        }
        #expect(details(.init(running: true, status: "Local speech active · You / Remote audio")) == ["listening", "listening"])
        #expect(details(.init(running: true, status: "Local speech is behind; recording continues"))
            == ["behind, recording continues", "behind, recording continues"])
        #expect(details(.init(running: false, status: "Loading local speech model…"))
            == ["recording, not transcribing", "recording, not transcribing"])
    }

    // MARK: Header, button, timer

    @Test func headerWordFollowsThePhase() {
        #expect(MenuText.header(state: .idle, transition: nil) == "idle")
        #expect(MenuText.header(state: .error, transition: nil) == "error")
        #expect(MenuText.header(state: .transcribing, transition: nil) == "processing")
        #expect(MenuText.header(state: .idle, transition: .starting) == "starting")
        #expect(MenuText.header(state: .recording, transition: .stopping) == "stopping")
    }

    @Test func recordLabelFollowsTheSharedButtonRule() {
        let idle = RecordingButton.current(state: .idle, transition: nil, livePreparing: false)
        #expect(MenuText.recordLabel(idle, stopMakesNotes: true) == "Start recording")
        let starting = RecordingButton.current(state: .idle, transition: .starting, livePreparing: false)
        #expect(MenuText.recordLabel(starting, stopMakesNotes: true) == "Starting…")
        let recording = RecordingButton.current(state: .recording, transition: nil, livePreparing: false)
        #expect(MenuText.recordLabel(recording, stopMakesNotes: true) == "Stop and make notes")
        #expect(MenuText.recordLabel(recording, stopMakesNotes: false) == "Stop recording")
        let stopping = RecordingButton.current(state: .recording, transition: .stopping, livePreparing: false)
        #expect(MenuText.recordLabel(stopping, stopMakesNotes: true) == "Stopping…")
    }

    @Test func elapsedReadsLikeAClock() {
        #expect(MenuText.elapsed(7) == "00:07")
        #expect(MenuText.elapsed(1122) == "18:42")
        #expect(MenuText.elapsed(3725) == "1:02:05")
        #expect(MenuText.elapsed(-4) == "00:00")
        #expect(MenuText.elapsed(.nan) == "00:00")
    }

    // MARK: Offline line

    @Test func offlineLineSaysWhatWaits() {
        #expect(MenuText.offlineLine(engine: .remote, provider: .openrouter)
            == "Offline. Recording works; cloud transcription waits for a connection.")
        #expect(MenuText.offlineLine(engine: .localWhisper, provider: .openrouter)
            == "Offline. Recording and local transcription still work; cloud notes wait for a connection.")
        #expect(MenuText.offlineLine(engine: .localWhisper, provider: .local)
            == "Offline. Recording, transcription and notes all run on this Mac.")
    }

    // MARK: Recent sessions

    private static func session(status: String) -> Session {
        Session(
            id: "S1", title: "Weekly sync, release plan", sourceApp: "System Audio",
            startedAt: Date(timeIntervalSince1970: 1_795_687_200),  // 2026-11-26 10:00 UTC
            audioPath: "/tmp/S1.wav", status: status)
    }

    @Test func recentRowUsesTheArchiveWording() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let row = MenuText.recentRow(Self.session(status: "transcribed"), calendar: utc)
        #expect(row == MenuRecentRow(id: "S1", date: "26.11", title: "Weekly sync, release plan", state: "notes", tone: .signal))
    }

    @Test func recentStatesMatchTheWebArchive() {
        let expected: [(String, String, SignalTone)] = [
            ("recording", "recording", .rust), ("transcribing", "working", .soft), ("completed", "waiting", .amber),
            ("transcribed", "notes", .signal), ("error", "failed", .amber), ("failed", "failed", .amber),
            ("interrupted", "interrupted", .ash), ("odd", "odd", .ash),
        ]
        for (status, word, tone) in expected {
            let row = MenuText.recentRow(Self.session(status: status), calendar: .current)
            #expect(row.state == word && row.tone == tone, "\(status)")
        }
    }

    // MARK: Now on (live map)

    @Test func nowOnShowsTheTopicPathAndTheLatestTurn() {
        let topics = [
            ConversationTopic(id: "t1", title: "Release plan"),
            ConversationTopic(id: "t2", parentID: "t1", title: "Testing"),
        ]
        let turn = LiveTurn(id: "x", source: .system, start: 1111, end: 1115, text: "Ship Friday.", language: nil)
        let now = MenuText.nowOn(topics: topics, currentTopicID: "t2", lastTurn: turn)
        #expect(now == MenuLiveNow(topic: "Release plan / Testing", quote: "Ship Friday.", source: "ch.2 at 18:31"))
    }

    @Test func nowOnBeforeAnySpeech() {
        let now = MenuText.nowOn(topics: [], currentTopicID: nil, lastTurn: nil)
        #expect(now == MenuLiveNow(topic: "Waiting for committed speech", quote: nil, source: nil))
        let mic = LiveTurn(id: "y", source: .mic, start: 5, end: 6, text: "Hello.", language: nil)
        #expect(MenuText.nowOn(topics: [], currentTopicID: nil, lastTurn: mic)?.source == "ch.1 at 00:05")
    }

    @Test func sessionPathEncodesTheIDAsOneSegment() {
        #expect(MenuText.sessionPath("S1") == "/sessions/S1")
        #expect(MenuText.sessionPath("a/b c") == "/sessions/a%2Fb%20c")
    }

    @Test func deviceNoteSaysWhoChoseTheDevices() {
        #expect(MenuText.deviceNote(followsSystem: true) == "Following the Mac's sound settings.")
        #expect(MenuText.deviceNote(followsSystem: false) == "Using the devices you chose.")
    }
}
