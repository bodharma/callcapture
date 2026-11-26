import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CallCapture

private let syntheticSecret = "sk-or-v1-synthetic-SECRET-4f2a9c"

@Suite("Settings API: secrets")
struct SettingsSecretsAPITests {
    @Test("a saved secret reads back only as set, and its value appears in no response")
    func secretsNeverReturned() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            var bodies: [String] = []
            let put = try await api.request(
                client, "/api/settings/secrets/openrouter", method: .put, json: #"{"value":"\#(syntheticSecret)"}"#)
            #expect(put.status == .noContent)
            #expect(bodyText(put).isEmpty)
            bodies.append(bodyText(put))

            let settings = try await api.request(client, "/api/settings")
            #expect(settings.status == .ok)
            let body = try jsonObject(settings)
            #expect(jsonValue(body, "secrets.openrouter") as? [String: Bool] == ["set": true])
            #expect(jsonValue(body, "secrets.deepgram") as? [String: Bool] == ["set": false])
            bodies.append(bodyText(settings))

            // Malformed or misrouted bodies carrying the secret are refused without echoing it.
            let truncated = try await api.request(
                client, "/api/settings/secrets/deepgram", method: .put, json: #"{"value":"\#(syntheticSecret)""#)
            #expect(truncated.status == .badRequest)
            bodies.append(bodyText(truncated))
            let misrouted = try await api.request(
                client, "/api/settings", method: .patch, json: #"{"secrets":{"openrouter":"\#(syntheticSecret)"}}"#)
            #expect(misrouted.status == .badRequest)
            bodies.append(bodyText(misrouted))
            let wrongKey = try await api.request(
                client, "/api/settings", method: .patch, json: #"{"aiNotes":{"apiKey":"\#(syntheticSecret)"}}"#)
            #expect(wrongKey.status == .badRequest)
            bodies.append(bodyText(wrongKey))

            bodies.append(bodyText(try await api.request(client, "/api/catalog")))
            for text in bodies { #expect(!text.contains(syntheticSecret), "leaked in: \(text)") }
        }
        #expect(api.settings.storedSecrets == ["openrouter_api_key": syntheticSecret])
    }

    @Test("PUT trims a pasted key and refuses an empty one")
    func secretInputChecks() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            let blank = try await api.request(
                client, "/api/settings/secrets/assemblyai", method: .put, json: #"{"value":"   "}"#)
            try expectInvalid(blank, mentioning: "can't be empty")
            let wrongType = try await api.request(
                client, "/api/settings/secrets/assemblyai", method: .put, json: #"{"value":42}"#)
            #expect(wrongType.status == .badRequest)
            let pasted = try await api.request(
                client, "/api/settings/secrets/assemblyai", method: .put, json: #"{"value":"  aai-synthetic\n"}"#)
            #expect(pasted.status == .noContent)
        }
        #expect(api.settings.storedSecrets == ["assemblyai_api_key": "aai-synthetic"])
    }

    @Test("DELETE removes a key, as clearing the SwiftUI field does")
    func deleteSecret() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            _ = try await api.request(
                client, "/api/settings/secrets/remote", method: .put, json: #"{"value":"gsk-synthetic"}"#)
            let delete = try await api.request(client, "/api/settings/secrets/remote", method: .delete)
            #expect(delete.status == .noContent)
            #expect(bodyText(delete).isEmpty)
            let body = try jsonObject(try await api.request(client, "/api/settings"))
            #expect(jsonValue(body, "secrets.remote") as? [String: Bool] == ["set": false])
        }
        #expect(api.settings.storedSecrets.isEmpty)
    }

    @Test("an unknown secret key is 404 and stores nothing")
    func unknownSecretKey() async throws {
        let api = SignedInAPI()
        try await api.run { client in
            for (method, json) in [(HTTPRequest.Method.put, #"{"value":"x"}"#), (.delete, nil)] {
                for name in ["llm", "OPENROUTER", "openrouter_api_key"] {
                    let response = try await api.request(client, "/api/settings/secrets/\(name)", method: method, json: json)
                    #expect(response.status == .notFound, "\(method) \(name)")
                    #expect(bodyText(response) == #"{"error":"not_found"}"#)
                }
            }
        }
        #expect(api.settings.storedSecrets.isEmpty)
    }

    @Test("testing the key runs in the app, and is refused offline with the app's wording")
    func keyTest() async throws {
        let api = SignedInAPI()
        api.settings.keyTestWillReturn(KeyTestResult(ok: true, message: "The key works. Free tier."))
        try await api.run { client in
            let missing = try await api.request(client, "/api/settings/secrets/openrouter/test", method: .post)
            #expect(missing.status == .ok)
            #expect(try jsonObject(missing)["ok"] as? Bool == false)

            _ = try await api.request(
                client, "/api/settings/secrets/openrouter", method: .put, json: #"{"value":"\#(syntheticSecret)"}"#)
            let works = try await api.request(client, "/api/settings/secrets/openrouter/test", method: .post)
            #expect(works.status == .ok)
            #expect(bodyText(works) == #"{"message":"The key works. Free tier.","ok":true}"#
                || bodyText(works) == #"{"ok":true,"message":"The key works. Free tier."}"#)
            #expect(!bodyText(works).contains(syntheticSecret))

            let other = try await api.request(client, "/api/settings/secrets/deepgram/test", method: .post)
            #expect(other.status == .notFound)

            api.backend.setOnline(false)
            let offline = try await api.request(client, "/api/settings/secrets/openrouter/test", method: .post)
            #expect(offline.status == .conflict)
            let body = try jsonObject(offline)
            #expect(body["error"] as? String == "offline")
            #expect(body["message"] as? String == "Offline — testing the key needs internet.")
        }
        #expect(api.settings.keyTestCalls == 2)
    }
}
