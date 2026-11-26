import Foundation
import Observation
import Testing

@testable import CallCapture

@Observable @MainActor
private final class Counter {
    var value = 0
    var other = ""
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ServerEvent] = []
    func append(_ event: ServerEvent) { lock.withLock { events.append(event) } }
    var all: [ServerEvent] { lock.withLock { events } }
    var documents: Int { all.filter { if case .liveDocument = $0 { true } else { false } }.count }
    var partials: [ServerEvent] { all.filter { if case .partial = $0 { true } else { false } } }
}

@MainActor
@Suite struct ChangeWatcherTests {
    @Test func reportsEachNewValue() async {
        let counter = Counter()
        var seen: [Int] = []
        let watcher = ChangeWatcher(read: { counter.value }, onChange: { seen.append($0) })
        counter.value = 1
        #expect(await eventually { await MainActor.run { seen == [1] } })
        counter.value = 2
        #expect(await eventually { await MainActor.run { seen == [1, 2] } })
        counter.other = "untracked by read"
        try? await Task.sleep(for: .milliseconds(30))
        #expect(seen == [1, 2])
        watcher.stop()
        counter.value = 3
        try? await Task.sleep(for: .milliseconds(30))
        #expect(seen == [1, 2])
    }

    @Test func throttleCoalescesABurst() async {
        var fired = 0
        let throttle = TrailingThrottle(interval: .milliseconds(40)) { fired += 1 }
        for _ in 0..<20 { throttle.signal() }
        #expect(await eventually { await MainActor.run { fired == 1 } })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(fired == 1, "no extra run without a new signal")
        throttle.signal()
        #expect(await eventually { await MainActor.run { fired == 2 } })
    }
}

@MainActor
@Suite struct LiveEventWatcherTests {
    private static func meeting(_ id: String = "S1") throws -> LiveMeetingModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = LiveMeetingModel()
        try model.begin(
            sessionID: id, title: "Sync", audioPath: dir.appendingPathComponent("\(id).wav").path,
            speechLanguage: "en", notesLanguage: "en",
            configuration: LiveNotesConfiguration(
                enabled: false, baseURL: URL(string: "http://127.0.0.1:1")!, apiKey: "", model: ""))
        return model
    }

    nonisolated private static func turn(_ index: Int) -> LiveTurn {
        LiveTurn(id: "t\(index)", source: .mic, start: Double(index), end: Double(index) + 0.5,
                 text: "Line \(index)", language: "en")
    }

    @Test func turnsAndDocumentChangesArePublished() async throws {
        let model = try Self.meeting()
        let log = EventLog()
        let watcher = LiveEventWatcher(model: { model }, post: log.append, interval: .milliseconds(40))
        defer { watcher.stop() }
        for index in 0..<10 { model.ingest(Self.turn(index)) }
        #expect(await eventually { log.all.contains(.liveTurn(Self.turn(9))) })
        #expect(await eventually { log.documents >= 1 })
        let turns = log.all.compactMap { if case .liveTurn(let turn) = $0 { turn.id } else { nil } }
        #expect(turns == (0..<10).map { "t\($0)" }, "every turn once, in arrival order")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.documents <= 2, "a burst of edits is one or two refreshes, not ten")
        #expect(log.all.contains(.liveDocument(sessionID: "S1")))
    }

    @Test func partialsAreThrottledButTheLastOneArrives() async throws {
        let model = try Self.meeting()
        let log = EventLog()
        let watcher = LiveEventWatcher(model: { model }, post: log.append, interval: .milliseconds(40))
        defer { watcher.stop() }
        for length in 1...30 { model.updatePartial(source: .system, text: String(repeating: "a", count: length)) }
        #expect(await eventually { log.partials.last == .partial(source: "system", text: String(repeating: "a", count: 30)) })
        #expect(log.partials.count <= 3)
    }

    @Test func aNewMeetingIsFollowed() async throws {
        var current = try Self.meeting("S1")
        let log = EventLog()
        let watcher = LiveEventWatcher(model: { current }, post: log.append, interval: .milliseconds(20))
        defer { watcher.stop() }
        current.end()
        let next = try Self.meeting("S2")
        current = next
        // The watcher only re-reads `model` when something it tracks changes.
        next.ingest(Self.turn(1))
        #expect(await eventually { log.all.contains(.liveDocument(sessionID: "S2")) })
        #expect(await eventually { log.all.contains(.liveTurn(Self.turn(1))) })
    }
}
