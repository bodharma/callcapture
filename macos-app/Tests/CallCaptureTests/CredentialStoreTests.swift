import Foundation
import GRDB
import Testing
@testable import CallCapture

@Suite("Settings credential isolation")
struct CredentialStoreTests {
    private var syntheticSecrets: [String: String] {
        ["remote_api_key": "synthetic-remote-secret", "assemblyai_api_key": "synthetic-assembly-secret",
         "deepgram_api_key": "synthetic-deepgram-secret", "llm_api_key": "synthetic-llm-secret",
         "openrouter_api_key": "synthetic-router-secret"]
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("bootstrap only reads credentials and never rewrites settings")
    func bootstrapDoesNotSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("settings.db").path)
        let store = InMemoryCredentialStore(syntheticSecrets)
        let settings = SettingsManager(database: database, credentialStore: store)
        #expect(settings.remoteApiKey == syntheticSecrets["remote_api_key"])
        #expect(settings.assemblyAIApiKey == syntheticSecrets["assemblyai_api_key"])
        #expect(settings.deepgramApiKey == syntheticSecrets["deepgram_api_key"])
        #expect(settings.llmApiKey == syntheticSecrets["llm_api_key"])
        #expect(settings.openRouterApiKey == syntheticSecrets["openrouter_api_key"])
        #expect(Set(store.reads) == Set(syntheticSecrets.keys))
        #expect(store.writes.isEmpty)
        #expect(store.values == syntheticSecrets)
        #expect(try database.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM settings") } == 0)
    }

    @Test("denied credential reads never delete existing secrets during bootstrap")
    func deniedReadsDoNotClear() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("settings.db").path)
        let store = InMemoryCredentialStore(syntheticSecrets)
        store.deniesReads = true
        let settings = SettingsManager(database: database, credentialStore: store)
        #expect(settings.remoteApiKey.isEmpty)
        #expect(settings.openRouterApiKey.isEmpty)
        #expect(store.writes.isEmpty)
        #expect(store.values == syntheticSecrets)
    }

    @Test("explicit edits and clears write only credential markers to SQLite")
    func explicitChangesPersistSafely() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("settings.db").path)
        let store = InMemoryCredentialStore(syntheticSecrets)
        let settings = SettingsManager(database: database, credentialStore: store)
        settings.remoteApiKey = "replacement-remote-secret"
        settings.assemblyAIApiKey = "replacement-assembly-secret"
        settings.deepgramApiKey = "replacement-deepgram-secret"
        settings.llmApiKey = "replacement-llm-secret"
        settings.openRouterApiKey = ""
        #expect(store.writes.count == 5)
        #expect(store.values["remote_api_key"] == "replacement-remote-secret")
        #expect(store.values["openrouter_api_key"] == nil)
        let values = try database.dbPool.read { try String.fetchAll($0, sql: "SELECT value FROM settings") }
        #expect(values.count == 5)
        #expect(Set(values) == ["keychain"])
        let reloaded = SettingsManager(database: database, credentialStore: store)
        #expect(reloaded.remoteApiKey == "replacement-remote-secret")
        #expect(reloaded.openRouterApiKey.isEmpty)
        #expect(store.writes.count == 5)
    }

    @MainActor @Test("runtime credentials never enter requests, saved maps, or exported notes")
    func credentialsStayOutOfArtifacts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(path: directory.appendingPathComponent("settings.db").path)
        let store = InMemoryCredentialStore(syntheticSecrets)
        let settings = SettingsManager(database: database, credentialStore: store)
        let map = LiveMeetingModel()
        try map.begin(sessionID: "synthetic", title: "Synthetic meeting",
                      audioPath: directory.appendingPathComponent("meeting.wav").path,
                      speechLanguage: "en", notesLanguage: "en",
                      configuration: .init(enabled: false, baseURL: URL(string: "https://example.invalid/v1")!,
                                           apiKey: settings.openRouterApiKey, model: "synthetic"))
        map.addManualNote("Synthetic note", kind: .note)
        map.end()
        let exported = try map.exportMarkdown(to: directory)
        let persisted = directory.appendingPathComponent("meeting_live.json")
        let session = Session(id: "synthetic", title: "Synthetic", sourceApp: "test", startedAt: Date(),
                              audioPath: directory.appendingPathComponent("meeting.wav").path, status: "recording")
        let request = try JSONEncoder().encode(JobRequest.transcribe(session: session, settings: settings))
        let contents = [String(decoding: request, as: UTF8.self), try String(contentsOf: exported, encoding: .utf8),
                        try String(contentsOf: persisted, encoding: .utf8)]
        for secret in syntheticSecrets.values {
            #expect(contents.allSatisfy { !$0.contains(secret) })
        }
        #expect(store.writes.isEmpty)
    }
}
