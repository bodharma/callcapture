import Foundation
import GRDB
import OSLog

/// Which port the loopback server binds. It tries the port it had last time first, so a
/// browser tab left open across a restart reaches the new run and is told to sign in
/// again (401) instead of meeting a refused connection forever; if that port is taken,
/// any free port.
enum ServerPortChoice {
    /// Saved values outside this range (privileged or invalid) are ignored.
    static let usablePorts = 1024...65535

    /// `attempt(port)` binds and returns the bound port; `attempt(0)` lets the OS choose.
    static func bind(preferring saved: Int?, attempt: (Int) async throws -> Int) async throws -> Int {
        if let saved, usablePorts.contains(saved), let bound = try? await attempt(saved) {
            return bound
        }
        return try await attempt(0)
    }
}

/// The last bound port, kept in the settings table with the app's other small state.
/// Not a user setting: `SettingsManager` never loads it, so it is not in `GET /api/settings`
/// and changing it posts no `settings` event.
struct ServerPortStore: Sendable {
    static let key = "last_server_port"
    private static let logger = Logger(subsystem: "com.callcapture.app", category: "LocalServer")

    let database: AppDatabase

    func load() -> Int? {
        do {
            let value = try database.dbPool.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [Self.key])
            }
            return value.flatMap { Int($0) }
        } catch {
            Self.logger.error("Couldn't read the last server port: \(error.localizedDescription)")
            return nil
        }
    }

    func save(_ port: Int) {
        do {
            try database.dbPool.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                    arguments: [Self.key, String(port)])
            }
        } catch {
            Self.logger.error("Couldn't save the server port: \(error.localizedDescription)")
        }
    }
}
