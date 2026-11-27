import Foundation
import Testing

@testable import CallCapture

/// `LiveWorkerProcess.wait` with its inputs in a fixed order: no subprocess, no timing.
@Suite struct LiveWorkerWaitTests {
    /// Answers the condition from a script, one value per call (the last one repeats).
    private final class Script: @unchecked Sendable {
        private var answers: [Bool]
        private(set) var calls = 0
        init(_ answers: [Bool]) { self.answers = answers }
        func next() -> Bool {
            calls += 1
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }

    private static let healthy: () -> (failure: String?, cancelled: Bool) = { (nil, false) }

    /// Regression for the "concurrently finished workers" flake: `finish()` waits for
    /// `!isRunning`; the worker exited between the condition check and the running check.
    @Test func aWorkerThatFinishesBetweenTheChecksIsNotAFailure() async throws {
        let condition = Script([false, true])
        try await LiveWorkerProcess.wait(
            timeout: 5, condition: condition.next, state: Self.healthy, isRunning: { false }, sleep: {})
        #expect(condition.calls == 2)
    }

    @Test func aWorkerThatExitsWithWorkOutstandingIsStillReported() async throws {
        await #expect(throws: LiveWorkerError.self) {
            try await LiveWorkerProcess.wait(
                timeout: 5, condition: { false }, state: Self.healthy, isRunning: { false }, sleep: {})
        }
    }

    @Test func aReportedFailureWinsOverTheExit() async throws {
        do {
            try await LiveWorkerProcess.wait(
                timeout: 5, condition: { false }, state: { ("Model missing", false) }, isRunning: { false }, sleep: {})
            Issue.record("Expected the worker's failure")
        } catch LiveWorkerError.unavailable(let message) {
            #expect(message == "Model missing")
        }
    }

    @Test func aRunningWorkerTimesOut() async throws {
        var clock = Date(timeIntervalSince1970: 0)
        await #expect(throws: LiveWorkerError.self) {
            try await LiveWorkerProcess.wait(
                timeout: 1, condition: { false }, state: Self.healthy, isRunning: { true },
                sleep: { clock.addTimeInterval(0.6) }, now: { clock })
        }
    }
}
