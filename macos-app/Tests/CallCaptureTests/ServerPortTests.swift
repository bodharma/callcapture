import Foundation
import Testing

@testable import CallCapture

/// The loopback server tries the port it had last time first, so a browser tab left open
/// across a restart reaches the new run and gets 401 (sign in again) instead of a refused
/// connection. No sockets: the bind is injected.
@Suite struct ServerPortTests {
    private struct Taken: Error {}

    /// Records each attempted port; `taken` ports fail, port 0 binds to `ephemeral`.
    private final class Binder: @unchecked Sendable {
        private(set) var attempts: [Int] = []
        let taken: Set<Int>
        let ephemeral: Int
        init(taken: Set<Int> = [], ephemeral: Int = 61_234) { (self.taken, self.ephemeral) = (taken, ephemeral) }

        func bind(_ port: Int) throws -> Int {
            attempts.append(port)
            if taken.contains(port) { throw Taken() }
            return port == 0 ? ephemeral : port
        }
    }

    @Test func theSavedPortIsTriedFirst() async throws {
        let binder = Binder()
        let port = try await ServerPortChoice.bind(preferring: 50_123) { try binder.bind($0) }
        #expect(port == 50_123)
        #expect(binder.attempts == [50_123])
    }

    @Test func aTakenSavedPortFallsBackToAnyFreePort() async throws {
        let binder = Binder(taken: [50_123])
        let port = try await ServerPortChoice.bind(preferring: 50_123) { try binder.bind($0) }
        #expect(port == 61_234)
        #expect(binder.attempts == [50_123, 0])
    }

    @Test(arguments: [nil, 0, 80, 1023, 65_536, -1] as [Int?])
    func noUsableSavedPortBindsAnyFreePort(saved: Int?) async throws {
        let binder = Binder()
        let port = try await ServerPortChoice.bind(preferring: saved) { try binder.bind($0) }
        #expect(port == 61_234)
        #expect(binder.attempts == [0])
    }

    @Test func aFailedFallbackIsReported() async throws {
        let binder = Binder(taken: [50_123, 0])
        await #expect(throws: Taken.self) {
            try await ServerPortChoice.bind(preferring: 50_123) { try binder.bind($0) }
        }
    }

    @Test func theStoreKeepsThePortAcrossRuns() throws {
        let path = NSTemporaryDirectory() + "cc-port-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try AppDatabase(path: path)
        #expect(ServerPortStore(database: database).load() == nil)
        ServerPortStore(database: database).save(50_123)
        #expect(ServerPortStore(database: try AppDatabase(path: path)).load() == 50_123)
    }

    @Test func theStoredPortIsNotASetting() throws {
        let path = NSTemporaryDirectory() + "cc-port-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try AppDatabase(path: path)
        let settings = SettingsManager(database: database, credentialStore: InMemoryCredentialStore())
        let before = SettingsDTO(settings: settings, catalog: nil, isOnline: true, downloads: [:])
        ServerPortStore(database: database).save(50_123)
        let reloaded = SettingsManager(database: database, credentialStore: InMemoryCredentialStore())
        #expect(SettingsDTO(settings: reloaded, catalog: nil, isOnline: true, downloads: [:]) == before)
    }
}
