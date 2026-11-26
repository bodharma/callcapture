import Foundation
import Testing
@testable import CallCapture

@Suite("Connectivity gating")
struct ConnectivityGatingTests {
    @Test("only cloud transcription is blocked offline")
    func networkBlockReason() {
        #expect(NetworkPolicy.blockReason(engine: "remote", isOnline: false) == ConnectivityMonitor.offlineReason)
        #expect(NetworkPolicy.blockReason(engine: "remote", isOnline: true) == nil)
        #expect(NetworkPolicy.blockReason(engine: "local_whisper", isOnline: false) == nil)
    }

    @Test("auto-process waits for cloud, runs local Whisper offline, and needs no internet for a local LLM")
    func autoProcessDecision() {
        #expect(NetworkPolicy.decision(engine: "remote", provider: .openrouter, isOnline: true) == .transcribe)
        #expect(NetworkPolicy.decision(engine: "local_whisper", provider: .openrouter, isOnline: true) == .transcribe)
        #expect(NetworkPolicy.decision(engine: "remote", provider: .openrouter, isOnline: false) == .wait(NetworkPolicy.cloudWaitMessage))
        #expect(NetworkPolicy.decision(engine: "remote", provider: .local, isOnline: false) == .wait(NetworkPolicy.cloudWaitMessage))
        #expect(NetworkPolicy.decision(engine: "local_whisper", provider: .openrouter, isOnline: false) == .transcribeOffline)
        #expect(NetworkPolicy.decision(engine: "local_whisper", provider: .local, isOnline: false) == .transcribe)
    }

    @Test("offline transcription tells the worker to skip the LLM; online and local-LLM runs do not")
    func offlineEnvironment() {
        #expect(NetworkPolicy.decision(engine: "local_whisper", provider: .openrouter, isOnline: false).workerEnvironment == ["LLM_OFFLINE": "1"])
        #expect(NetworkPolicy.Decision.transcribe.workerEnvironment.isEmpty)
    }

    @MainActor
    @Test("the monitor reports what it is told and starts online")
    func monitorState() {
        let monitor = ConnectivityMonitor(startMonitoring: false)
        #expect(monitor.isOnline)
        monitor.setOnline(false)
        #expect(!monitor.isOnline)
        monitor.setOnline(true)
        #expect(monitor.isOnline)
    }
}
