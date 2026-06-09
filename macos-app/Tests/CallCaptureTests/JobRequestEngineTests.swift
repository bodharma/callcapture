import Foundation
import Testing
@testable import CallCapture

/// Re-processing a session must reuse the engine it was originally transcribed
/// with. Otherwise re-processing a remote session falls back to the configured
/// default (typically local Whisper) — wrong transcription quality AND a $0.00
/// transcription cost, because the remote provider is never billed.
@Suite("JobRequest engine selection")
struct JobRequestEngineTests {

    private func makeSettings() throws -> (settings: SettingsManager, path: String) {
        let path = NSTemporaryDirectory() + "cc-jobreq-\(UUID().uuidString).db"
        let db = try AppDatabase(path: path)
        return (SettingsManager(database: db), path)
    }

    private func makeSession(engineUsed: String?, language: String = "auto") -> Session {
        var session = Session(
            id: "s", title: "t", sourceApp: "x", startedAt: Date(),
            audioPath: "/tmp/x.wav", recordingType: "call_meeting",
            language: language, status: "transcribed"
        )
        session.engineUsed = engineUsed
        return session
    }

    @Test("re-process reuses the session's original engine, not the default")
    func reprocessReusesOriginalEngine() throws {
        let (settings, path) = try makeSettings()
        defer { try? FileManager.default.removeItem(atPath: path) }
        settings.defaultEngine = .localWhisper

        let request = JobRequest.transcribe(
            session: makeSession(engineUsed: "remote"),
            settings: settings
        )

        #expect(request.engine == "remote")
    }

    @Test("a fresh session with no prior engine uses the configured default")
    func freshSessionUsesDefault() throws {
        let (settings, path) = try makeSettings()
        defer { try? FileManager.default.removeItem(atPath: path) }
        settings.defaultEngine = .remote

        let request = JobRequest.transcribe(
            session: makeSession(engineUsed: nil),
            settings: settings
        )

        #expect(request.engine == "remote")
    }

    @Test("an empty persisted engine is treated as absent, falling back to default")
    func emptyEngineFallsBackToDefault() throws {
        let (settings, path) = try makeSettings()
        defer { try? FileManager.default.removeItem(atPath: path) }
        settings.defaultEngine = .localWhisper

        let request = JobRequest.transcribe(
            session: makeSession(engineUsed: ""),
            settings: settings
        )

        #expect(request.engine == "local_whisper")
    }
}
