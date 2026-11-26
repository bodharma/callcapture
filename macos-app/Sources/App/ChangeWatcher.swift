import Foundation
import Observation

/// Re-arms `withObservationTracking` after every change: `track` reads the observed
/// properties, `changed` runs on the main actor after any of them changed (several
/// changes in one turn of the main actor arrive as one call).
@MainActor
final class ObservationLoop {
    private let track: @MainActor () -> Void
    private let changed: @MainActor () -> Void
    private var stopped = false

    init(track: @escaping @MainActor () -> Void, changed: @escaping @MainActor () -> Void) {
        self.track = track
        self.changed = changed
        arm()
    }

    func stop() { stopped = true }

    private func arm() {
        guard !stopped else { return }
        withObservationTracking { track() } onChange: { [weak self] in
            // Called before the new value is stored, on the mutating thread.
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.arm()
                self.changed()
            }
        }
    }
}

/// Calls `onChange` with each new value of `read` (main-actor observable state only).
@MainActor
final class ChangeWatcher<Value: Equatable> {
    private var loop: ObservationLoop?
    private var last: Value

    init(read: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        last = read()
        loop = ObservationLoop(track: { _ = read() }) { [weak self] in
            guard let self else { return }
            let value = read()
            guard value != self.last else { return }
            self.last = value
            onChange(value)
        }
    }

    func stop() { loop?.stop() }
}

/// Runs `action` at most once per `interval`, after the first `signal` of a window;
/// signals during the wait fold into that run, so the last change is always delivered.
@MainActor
final class TrailingThrottle {
    private let interval: Duration
    private let action: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    init(interval: Duration, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    func signal() {
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self, interval] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.action()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
