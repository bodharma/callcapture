@testable import CallCapture

/// Test-owned credentials; never reads the user's Keychain.
final class InMemoryCredentialStore: CredentialStore {
    var values: [String: String]
    var deniesReads = false
    private(set) var reads: [String] = []
    private(set) var writes: [(account: String, value: String)] = []

    init(_ values: [String: String] = [:]) { self.values = values }

    func load(for account: String) -> String {
        reads.append(account)
        return deniesReads ? "" : values[account, default: ""]
    }

    func save(_ value: String, for account: String) {
        writes.append((account, value))
        values[account] = value.isEmpty ? nil : value
    }
}
