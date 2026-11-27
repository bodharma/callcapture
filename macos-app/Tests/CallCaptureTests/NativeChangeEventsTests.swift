import Foundation
import Testing

@testable import CallCapture

/// Changes made outside the HTTP routes (native windows, the menu) still reach open pages.
@Suite struct NativeChangeEventsTests {
    private static func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Collects what the hub publishes until `finishAll`.
    private static func reader(_ hub: EventHub) async -> Task<[ServerEvent], Never> {
        let stream = await hub.subscribe()
        return Task { await stream.reduce(into: []) { $0.append($1) } }
    }

    @MainActor @Test func settingsChangedOutsideTheAPIPublish() async throws {
        let dir = try Self.tempDir("settings-events")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SettingsManager(
            database: try AppDatabase(path: dir.appendingPathComponent("db.sqlite").path),
            credentialStore: InMemoryCredentialStore())
        let hub = EventHub()
        let events = await Self.reader(hub)
        let watcher = NativeChangeSources.settings(manager, post: { hub.post($0) })
        defer { watcher.stop() }

        manager.autoProcessOnStop.toggle()
        #expect(await eventually { await hub.subscriberCount == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        manager.setSecret(.openrouter, to: "sk-test")
        try? await Task.sleep(for: .milliseconds(100))
        await hub.finishAll()
        let received = await events.value
        #expect(received.filter { $0 == .settings }.count == 2, "\(received)")
        #expect(!received.description.contains("sk-test"), "no secret in any event")
    }

    @Test func speakerNamesSavedThroughTheSharedWriterPublish() async throws {
        let dir = try Self.tempDir("names-events")
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("S-names.wav").path
        let hub = EventHub()
        let events = await Self.reader(hub)
        let forwarding = ModelFileEvents.forward(to: hub) { path in path == audio ? "S-names" : nil }
        defer { ModelFileEvents.remove(forwarding) }

        try SpeakerNames().renamed("Speaker 1", to: "Olena").save(audioPath: audio)
        try? await Task.sleep(for: .milliseconds(100))
        await hub.finishAll()
        #expect(await events.value.contains(.sessionChanged(id: "S-names")))
    }

    @MainActor @Test func persistingAnOpenedSavedMapPublishes() async throws {
        let dir = try Self.tempDir("map-events")
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("S-map.wav").path
        try JSONEncoder().encode(LiveFixture.document(sessionID: "S-map", audioPath: audio, recording: false))
            .write(to: URL(fileURLWithPath: SavedLiveMap.path(audioPath: audio)))
        let hub = EventHub()
        let events = await Self.reader(hub)
        let forwarding = ModelFileEvents.forward(to: hub) { _ in nil }
        defer { ModelFileEvents.remove(forwarding) }

        let saved = try LiveMeetingModel.opened(audioPath: audio)
        saved.renameTopic("timing", title: "Schedule")
        try? await Task.sleep(for: .milliseconds(100))
        await hub.finishAll()
        #expect(await events.value.contains(.liveDocument(sessionID: "S-map")))
    }

    @MainActor @Test func theRecordingMeetingIsLeftToTheLiveWatcher() async throws {
        let dir = try Self.tempDir("live-events")
        defer { try? FileManager.default.removeItem(at: dir) }
        let hub = EventHub()
        let events = await Self.reader(hub)
        let forwarding = ModelFileEvents.forward(to: hub) { _ in nil }
        defer { ModelFileEvents.remove(forwarding) }

        let live = LiveMeetingModel()
        try live.begin(
            sessionID: "S-recording", title: "Sync", audioPath: dir.appendingPathComponent("S-recording.wav").path,
            speechLanguage: "en", notesLanguage: "en",
            configuration: LiveNotesConfiguration(
                enabled: false, baseURL: URL(string: "http://127.0.0.1:1")!, apiKey: "", model: ""))
        live.ingest(LiveTurn(id: "t1", source: .mic, start: 1, end: 2, text: "Hello", language: "en"))
        try? await Task.sleep(for: .milliseconds(100))
        await hub.finishAll()
        // Every ingest persists; the throttled LiveEventWatcher reports those, not this hook.
        #expect(!(await events.value.contains(.liveDocument(sessionID: "S-recording"))))
    }

    @Test func sessionIsFoundByItsAudioPath() throws {
        let dir = try Self.tempDir("audio-lookup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SessionManager(database: try AppDatabase(path: dir.appendingPathComponent("db.sqlite").path))
        let session = manager.createSession(sourceApp: "Test")
        #expect(manager.sessionID(audioPath: session.audioPath) == session.id)
        #expect(manager.sessionID(audioPath: "/nowhere.wav") == nil)
        manager.deleteSession(id: session.id)
    }
}
