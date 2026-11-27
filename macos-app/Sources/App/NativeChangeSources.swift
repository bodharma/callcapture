import Foundation

/// Event sources for state the native windows and the menu change directly.
@MainActor
enum NativeChangeSources {
    /// Posts `settings` whenever anything `GET /api/settings` reports changes, whoever
    /// changed it (settings window, menu, API). Secrets count only as set / not set.
    static func settings(
        _ manager: SettingsManager, post: @escaping @Sendable (ServerEvent) -> Void
    ) -> ChangeWatcher<SettingsDTO> {
        ChangeWatcher(read: { SettingsDTO(settings: manager, catalog: nil, isOnline: true, downloads: [:]) }) { _ in
            post(.settings)
        }
    }
}
