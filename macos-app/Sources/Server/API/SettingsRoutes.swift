import Foundation
import HTTPTypes
import Hummingbird

/// `/api/settings/*`.
///
/// | Route | Answer |
/// |---|---|
/// | `GET /api/settings` | `SettingsDTO` |
/// | `PATCH /api/settings` | partial `{"<pane>": {"<setting>": value}}` → updated `SettingsDTO`; 400 `invalid` and nothing saved on any problem |
/// | `POST /api/settings/costs/reset` | pricing defaults restored → `SettingsDTO` |
/// | `PUT /api/settings/secrets/:key` | `{"value": "…"}` → 204, never echoed |
/// | `DELETE /api/settings/secrets/:key` | 204, key removed |
/// | `POST /api/settings/secrets/openrouter/test` | `{"ok", "message"}`; 409 `offline` |
/// | `POST /api/settings/models/:kind/download` | 202 `{"started": true}`; 409 `offline` / `busy` |
///
/// Unknown secret keys and download kinds are 404. Secret values are never logged:
/// the secret routes answer their own errors instead of going through `APIResponse.from`.
func addSettingsRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.get("api/settings") { _, _ in
        await apiResult { APIResponse.json(try await backend.settingsSnapshot()) }
    }
    router.patch("api/settings") { request, _ in
        let patch: SettingsPatch
        do {
            let data = try await RequestBody.data(request, limit: SettingsValidation.maxBodyBytes)
            patch = try SettingsValidation.patch(from: data)
        } catch let invalid as SettingsInvalid {
            return invalidResponse(invalid.message, key: invalid.key)
        } catch {
            return invalidResponse("Send at most 16 KB of settings as a JSON object.")
        }
        return await apiResult { await changed(backend, APIResponse.json(try await backend.updateSettings(patch))) }
    }
    router.post("api/settings/costs/reset") { _, _ in
        await apiResult { await changed(backend, APIResponse.json(try await backend.resetCosts())) }
    }
    addSecretRoutes(to: router, backend: backend)
    addModelDownloadRoutes(to: router, backend: backend)
}

private func addSecretRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.put("api/settings/secrets/:key") { request, context in
        guard let key = secretKey(context) else { return APIResponse.notFound() }
        let body: SecretBody
        do {
            body = try await RequestBody.decode(SecretBody.self, from: request, limit: SecretBody.maxBytes)
        } catch {
            return invalidResponse(#"Send {"value": "<the key>"}. To remove a key, use DELETE."#)
        }
        let value = body.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return invalidResponse("The key can't be empty. To remove a key, use Remove.") }
        guard !SettingsValidation.hasControlCharacters(value) else {
            return invalidResponse("The key can't contain line breaks or other control characters.")
        }
        return await changed(backend, await secretResult { try await backend.setSecret(key, value: value) })
    }
    router.delete("api/settings/secrets/:key") { _, context in
        guard let key = secretKey(context) else { return APIResponse.notFound() }
        return await changed(backend, await secretResult { try await backend.setSecret(key, value: "") })
    }
    router.post("api/settings/secrets/:key/test") { _, context in
        guard secretKey(context) == .openrouter else { return APIResponse.notFound() }
        guard await backend.isOnline() else {
            return APIResponse.error(.conflict, "offline", message: NetworkPolicy.keyTestOfflineReason)
        }
        return await apiResult { APIResponse.json(try await backend.testOpenRouterKey()) }
    }
}

private func addModelDownloadRoutes(to router: Router<BasicRequestContext>, backend: any AppBackend) {
    router.post("api/settings/models/:kind/download") { _, context in
        guard let kind = context.parameters.get("kind").flatMap(ModelDownloadKind.init(rawValue:)) else {
            return APIResponse.notFound()
        }
        if let reason = NetworkPolicy.downloadBlockReason(isOnline: await backend.isOnline()) {
            return APIResponse.error(.conflict, "offline", message: reason)
        }
        return await apiResult {
            try await backend.startModelDownload(kind)
            return await changed(backend, APIResponse.json(StartedDTO(), status: .accepted))
        }
    }
}

/// Tells every open page to refetch settings after a change that succeeded.
private func changed(_ backend: any AppBackend, _ response: Response) async -> Response {
    if (200..<300).contains(response.status.code) { await backend.events.publish(.settings) }
    return response
}

func invalidResponse(_ message: String, key: String? = nil) -> Response {
    APIResponse.error(.badRequest, "invalid", message: message, key: key)
}

private func secretKey(_ context: BasicRequestContext) -> SecretKey? {
    context.parameters.get("key").flatMap(SecretKey.init(rawValue:))
}

/// 204 on success; errors are answered without logging anything about the request.
private func secretResult(_ work: () async throws -> Void) async -> Response {
    do {
        try await work()
        return APIResponse.noContent()
    } catch BackendError.unavailable {
        return APIResponse.from(BackendError.unavailable)
    } catch {
        return APIResponse.error(.internalServerError, "failed", message: "The key could not be saved.")
    }
}

private struct SecretBody: Decodable {
    static let maxBytes = 8 * 1024
    let value: String
}
