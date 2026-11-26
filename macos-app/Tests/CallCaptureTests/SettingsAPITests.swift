import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

@Suite("Settings API")
struct SettingsAPITests {
    @Test("GET groups every editable setting by pane, with typed values")
    func snapshotShape() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let response = try await api.request(client, "/api/settings")
            #expect(response.status == .ok)
            #expect(response.headers[.contentType]?.hasPrefix("application/json") == true)
            let body = try jsonObject(response)
            #expect(jsonValue(body, "general.autoProcessOnStop") as? Bool == true)
            #expect(jsonValue(body, "recording.keepSeparateMicTrack") as? Bool == false)
            #expect(jsonValue(body, "recording.outputDirectory") is String)
            #expect(jsonValue(body, "transcription.engine") as? String == "local_whisper")
            #expect(jsonValue(body, "transcription.whisperModel") as? String == "base")
            #expect(jsonValue(body, "transcription.remoteProvider") as? String == "groq")
            #expect(jsonValue(body, "transcription.models.diarization.ready") as? Bool == false)
            #expect(jsonValue(body, "transcription.models.emotion.downloading") as? Bool == false)
            #expect(jsonValue(body, "aiNotes.provider") as? String == "openrouter")
            #expect(jsonValue(body, "aiNotes.finalModel") as? String == "google/gemini-2.5-flash")
            #expect(jsonValue(body, "aiNotes.liveModel") as? String == "google/gemini-2.5-flash")
            #expect(jsonValue(body, "aiNotes.localModel") as? String == "")
            #expect(jsonValue(body, "aiNotes.localBaseURL") as? String == "http://localhost:11434/v1")
            #expect(jsonValue(body, "vault.obsidianVault") as? String == "")
            #expect(jsonValue(body, "vault.folderPattern") as? String == "_meetings/{YYYY-MM}/")
            #expect(jsonValue(body, "vault.markdownProfile") as? String == "meeting_notes")
            #expect(jsonValue(body, "costs.assemblyAIPerMin") as? Double == 0.0035)
            #expect(jsonValue(body, "costs.llmFallbackPer1M") as? Double == 3.0)
            for key in SecretKey.allCases {
                #expect(jsonValue(body, "secrets.\(key.rawValue)") as? [String: Bool] == ["set": false])
            }
        }
    }

    @Test("the offline reasons are the app's own wording")
    func offlineReasonsCopy() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let body = try jsonObject(try await api.request(client, "/api/settings"))
            #expect(jsonValue(body, "offlineReasons.refreshCatalog") as? String
                == "Offline — refreshing needs an internet connection.")
            #expect(jsonValue(body, "offlineReasons.testKey") as? String == "Offline — testing the key needs internet.")
            #expect(jsonValue(body, "offlineReasons.download") as? String
                == "Offline — downloading needs an internet connection. Downloaded models work offline.")
        }
    }

    @Test("PATCH applies a valid partial object and answers with the new snapshot")
    func patchApplies() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let response = try await api.request(
                client, "/api/settings", method: .patch,
                json: """
                    {"general":{"autoProcessOnStop":false},
                     "transcription":{"engine":"remote","remoteProvider":"deepgram","whisperModel":"medium"},
                     "aiNotes":{"provider":"local","localModel":"qwen2.5:32b","liveModel":"openai/gpt-5-mini"},
                     "vault":{"markdownProfile":"obsidian","folderPattern":"meetings/{YYYY}/"},
                     "costs":{"groqPerMin":0.001,"llmFallbackPer1M":2}}
                    """)
            #expect(response.status == .ok, "\(bodyText(response))")
            let body = try jsonObject(response)
            #expect(jsonValue(body, "general.autoProcessOnStop") as? Bool == false)
            #expect(jsonValue(body, "transcription.engine") as? String == "remote")
            #expect(jsonValue(body, "aiNotes.provider") as? String == "local")
            #expect(jsonValue(body, "costs.llmFallbackPer1M") as? Double == 2)
        }
        api.settings.withManager { settings in
            #expect(settings.autoProcessOnStop == false)
            #expect(settings.defaultEngine == .remote)
            #expect(settings.remoteProvider == .deepgram)
            #expect(settings.whisperModel == .medium)
            #expect(settings.llmProvider == .local)
            #expect(settings.localLLMModel == "qwen2.5:32b")
            #expect(settings.liveLLMModel == "openai/gpt-5-mini")
            #expect(settings.llmModel == "google/gemini-2.5-flash")
            #expect(settings.markdownProfile == .obsidian)
            #expect(settings.obsidianFolderPattern == "meetings/{YYYY}/")
            #expect(settings.sttRateGroq == 0.001)
            #expect(settings.llmFallbackRatePer1M == 2)
        }
    }

    @Test("PATCH refuses unknown keys, wrong types and bad values, and saves nothing")
    func patchValidates() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            func patch(_ json: String) async throws -> TestResponse {
                try await api.request(client, "/api/settings", method: .patch, json: json)
            }
            try expectInvalid(try await patch(#"{"general":{"nope":true}}"#), mentioning: "general.nope")
            try expectInvalid(try await patch(#"{"nope":{}}"#), mentioning: "nope")
            try expectInvalid(try await patch(#"[1]"#), mentioning: "JSON object")
            try expectInvalid(try await patch(#"{"general":true}"#), mentioning: "general")
            try expectInvalid(try await patch(#"not json"#), mentioning: "JSON object")
            // Number for a flag, flag for a rate, text for a rate.
            try expectInvalid(
                try await patch(#"{"general":{"autoProcessOnStop":1}}"#), mentioning: "true or false",
                key: "general.autoProcessOnStop")
            try expectInvalid(
                try await patch(#"{"costs":{"groqPerMin":true}}"#), mentioning: "number", key: "costs.groqPerMin")
            try expectInvalid(
                try await patch(#"{"costs":{"groqPerMin":"0.1"}}"#), mentioning: "number", key: "costs.groqPerMin")
            try expectInvalid(
                try await patch(#"{"costs":{"groqPerMin":-1}}"#), mentioning: "0 or more", key: "costs.groqPerMin")
            try expectInvalid(
                try await patch(#"{"transcription":{"engine":"cloud"}}"#), mentioning: "local_whisper, remote",
                key: "transcription.engine")
            try expectInvalid(
                try await patch(#"{"vault":{"markdownProfile":null}}"#), mentioning: "meeting_notes",
                key: "vault.markdownProfile")
            // Read-only reports.
            try expectInvalid(
                try await patch(#"{"transcription":{"models":{}}}"#), mentioning: "can't be changed",
                key: "transcription.models")
            try expectInvalid(
                try await patch(#"{"aiNotes":{"warnings":{}}}"#), mentioning: "can't be changed", key: "aiNotes.warnings")
            try expectInvalid(try await patch(#"{"offlineReasons":{}}"#), mentioning: "can't be changed")
            try expectInvalid(try await patch(#"{"secrets":{}}"#), mentioning: "/api/settings/secrets/")

            // One valid and one invalid key in the same body: neither is saved.
            try expectInvalid(
                try await patch(#"{"general":{"autoProcessOnStop":false},"recording":{"keepSeparateMicTrack":"yes"}}"#),
                mentioning: "true or false", key: "recording.keepSeparateMicTrack")
            let after = try jsonObject(try await api.request(client, "/api/settings"))
            #expect(jsonValue(after, "general.autoProcessOnStop") as? Bool == true)
            #expect(jsonValue(after, "recording.keepSeparateMicTrack") as? Bool == false)
        }
        api.settings.withManager { settings in
            #expect(settings.autoProcessOnStop == true)
            #expect(settings.sttRateGroq == 0.0007)
            #expect(settings.defaultEngine == .localWhisper)
        }
    }

    @Test("text settings refuse values that would not survive a relaunch or escape the vault")
    func patchValidatesText() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            func patch(_ json: String) async throws -> TestResponse {
                try await api.request(client, "/api/settings", method: .patch, json: json)
            }
            try expectInvalid(
                try await patch(#"{"aiNotes":{"finalModel":"  "}}"#), mentioning: "can't be empty", key: "aiNotes.finalModel")
            try expectInvalid(
                try await patch(#"{"aiNotes":{"liveModel":""}}"#), mentioning: "can't be empty", key: "aiNotes.liveModel")
            try expectInvalid(
                try await patch(#"{"aiNotes":{"localBaseURL":"ftp://box/v1"}}"#), mentioning: "http://",
                key: "aiNotes.localBaseURL")
            try expectInvalid(
                try await patch(#"{"aiNotes":{"localBaseURL":""}}"#), mentioning: "http://", key: "aiNotes.localBaseURL")
            try expectInvalid(
                try await patch(#"{"vault":{"folderPattern":""}}"#), mentioning: "can't be empty", key: "vault.folderPattern")
            try expectInvalid(
                try await patch(#"{"vault":{"folderPattern":"../outside/{YYYY}"}}"#), mentioning: "inside the vault",
                key: "vault.folderPattern")
            try expectInvalid(
                try await patch(#"{"vault":{"folderPattern":"/etc/{YYYY}"}}"#), mentioning: "inside the vault",
                key: "vault.folderPattern")
            let ok = try await patch(#"{"aiNotes":{"localBaseURL":"http://127.0.0.1:1234/v1","localModel":""}}"#)
            #expect(ok.status == .ok, "\(bodyText(ok))")
        }
        api.settings.withManager { #expect($0.localLLMBaseURL == "http://127.0.0.1:1234/v1") }
    }

    @Test("folder settings must be absolute, existing directories; the output folder must be writable")
    func patchValidatesPaths() async throws {
        let api = SignedInAPI()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cc-paths-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Recordings", isDirectory: true)
        let readOnly = root.appendingPathComponent("ReadOnly", isDirectory: true)
        let file = root.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
            try? FileManager.default.removeItem(at: root)
        }
        try await api.run { client in
            func patch(_ group: String, _ key: String, _ path: String) async throws -> TestResponse {
                let json = String(
                    data: try JSONSerialization.data(withJSONObject: [group: [key: path]]), encoding: .utf8)!
                return try await api.request(client, "/api/settings", method: .patch, json: json)
            }
            let output = "recording.outputDirectory"
            try expectInvalid(try await patch("recording", "outputDirectory", "Recordings"), mentioning: "full path", key: output)
            try expectInvalid(try await patch("recording", "outputDirectory", ""), mentioning: "can't be empty", key: output)
            try expectInvalid(
                try await patch("recording", "outputDirectory", root.appendingPathComponent("missing").path),
                mentioning: "doesn't exist", key: output)
            try expectInvalid(try await patch("recording", "outputDirectory", file.path), mentioning: "not a folder", key: output)
            try expectInvalid(try await patch("recording", "outputDirectory", readOnly.path), mentioning: "can't write", key: output)

            let vault = "vault.obsidianVault"
            try expectInvalid(try await patch("vault", "obsidianVault", "notes/vault"), mentioning: "full path", key: vault)
            try expectInvalid(try await patch("vault", "obsidianVault", file.path), mentioning: "not a folder", key: vault)

            let saved = try await patch("recording", "outputDirectory", folder.path + "/")
            #expect(saved.status == .ok, "\(bodyText(saved))")
            #expect(jsonValue(try jsonObject(saved), "recording.outputDirectory") as? String == folder.path)
            // `~` is expanded to the home folder and stored as an absolute path.
            let home = try await patch("vault", "obsidianVault", "~")
            #expect(home.status == .ok, "\(bodyText(home))")
            #expect(jsonValue(try jsonObject(home), "vault.obsidianVault") as? String
                == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
            // A vault only has to exist: read-only is fine.
            let vaultSaved = try await patch("vault", "obsidianVault", readOnly.path)
            #expect(vaultSaved.status == .ok, "\(bodyText(vaultSaved))")
        }
        api.settings.withManager { settings in
            #expect(settings.outputDirectory == folder.path)
            #expect(settings.obsidianExportDirectory == readOnly.path)
        }
    }

    @Test("reset restores the pricing defaults")
    func resetCosts() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            _ = try await api.request(
                client, "/api/settings", method: .patch, json: #"{"costs":{"deepgramPerMin":0.5,"llmFallbackPer1M":9}}"#)
            let reset = try await api.request(client, "/api/settings/costs/reset", method: .post)
            #expect(reset.status == .ok)
            let body = try jsonObject(reset)
            #expect(jsonValue(body, "costs.deepgramPerMin") as? Double == 0.0043)
            #expect(jsonValue(body, "costs.llmFallbackPer1M") as? Double == 3.0)
        }
    }

    @Test("the live model warning comes from the app")
    func modelWarnings() async throws {
        let api = SignedInAPI()
        api.settings.setCatalog(CatalogState(snapshot: CatalogFixtures.snapshot(), problem: nil, refreshing: false))
        try await api.run { client in
            _ = try await api.request(
                client, "/api/settings", method: .patch,
                json: #"{"aiNotes":{"liveModel":"text/only","finalModel":"gone/model"}}"#)
            let body = try jsonObject(try await api.request(client, "/api/settings"))
            #expect(jsonValue(body, "aiNotes.warnings.live") as? String
                == "Text Only does not support JSON output, which automatic live notes need.")
            #expect(jsonValue(body, "aiNotes.warnings.final") as? String
                == "gone/model is no longer offered by OpenRouter. Choose another model.")
        }
    }

    @Test("model downloads start in the background, report progress, and are refused offline")
    func modelDownloads() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            api.backend.setOnline(false)
            let offline = try await api.request(client, "/api/settings/models/diarization/download", method: .post)
            #expect(offline.status == .conflict)
            let refusal = try jsonObject(offline)
            #expect(refusal["error"] as? String == "offline")
            #expect(refusal["message"] as? String
                == "Offline — downloading needs an internet connection. Downloaded models work offline.")

            api.backend.setOnline(true)
            let started = try await api.request(client, "/api/settings/models/diarization/download", method: .post)
            #expect(started.status == .accepted)
            #expect(bodyText(started) == #"{"started":true}"#)
            let again = try await api.request(client, "/api/settings/models/diarization/download", method: .post)
            #expect(again.status == .conflict)
            let body = try jsonObject(try await api.request(client, "/api/settings"))
            #expect(jsonValue(body, "transcription.models.diarization.downloading") as? Bool == true)

            api.settings.downloads.finish(.diarization, error: "Disk full.")
            let failed = try jsonObject(try await api.request(client, "/api/settings"))
            #expect(jsonValue(failed, "transcription.models.diarization.downloading") as? Bool == false)
            #expect(jsonValue(failed, "transcription.models.diarization.error") as? String == "Disk full.")

            api.settings.withManager { $0.emotionModelsReady = true }
            let ready = try await api.request(client, "/api/settings/models/emotion/download", method: .post)
            #expect(ready.status == .conflict)
            let unknown = try await api.request(client, "/api/settings/models/whisper/download", method: .post)
            #expect(unknown.status == .notFound)
        }
        #expect(api.settings.downloadRequests == [.diarization])
    }
}
