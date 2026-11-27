import AppKit
import OSLog
import SwiftUI

/// The menu bar popover: reads `AppModel` into plain values for `MenuPopover` and
/// routes its actions. Sessions, Settings and the live view open in the local web
/// UI (archive window, browser, live panel); only Diagnostics is a native window.
@available(macOS 14.2, *)
struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    private static let logger = Logger(subsystem: "com.callcapture.app", category: "ContentView")
    /// Recent sessions shown in the popover.
    private static let recentCount = 3

    var body: some View {
        MenuPopover(state: state, choices: choices, actions: actions)
            .onAppear { appModel.refreshAudioDevices() }
    }

    // MARK: State

    private var state: MenuState {
        let model = appModel
        let settings = model.settingsManager
        let recording = model.state == .recording
        let button = RecordingButton.current(
            state: model.state, transition: model.recordingTransition, livePreparing: model.liveMeeting.isPreparing)
        let liveInUse = recording && model.liveMeetingEnabled
        let document = model.liveMeeting.model.document
        let online = model.connectivity.isOnline
        var state = MenuState()
        state.recording = recording
        state.headerWord = MenuText.header(state: model.state, transition: model.recordingTransition)
        state.button = button
        state.recordLabel = MenuText.recordLabel(button, stopMakesNotes: settings.autoProcessOnStop)
        state.channels = MenuText.channels(
            recording: recording, microphoneOn: recording ? model.liveMicrophoneEnabled : model.includeMicrophone,
            micName: micName, outputName: outputName,
            live: liveInUse ? MenuText.LiveRuntime(running: model.liveMeeting.isRunning, status: model.liveMeeting.status) : nil)
        state.deviceNote = MenuText.deviceNote(followsSystem: model.selectedOutputUID == nil && model.selectedMicUID == nil)
        state.serverUp = model.localServerPort != nil
        state.offlineLine = online ? nil : MenuText.offlineLine(engine: settings.defaultEngine, provider: settings.llmProvider)
        state.notice = model.state == .idle ? model.notice : nil
        state.problem = model.state == .error ? model.lastError : nil
        state.processing = model.state == .transcribing ? model.pythonBridge.progress : nil
        state.recordingTitle = model.sessionManager.currentSession?.title ?? "Recording"
        state.recordingStartedAt = model.sessionManager.currentSession?.startedAt
        if liveInUse {
            state.liveNow = MenuText.nowOn(
                topics: document.topics, currentTopicID: document.currentTopicID, lastTurn: document.turns.last)
            state.spendLine = document.liveNotesUsage.map(LiveNotesUsageText.line)
        }
        state.live = liveSetup(online: online)
        state.devices = DeviceLists(
            outputs: model.outputDevices, inputs: model.inputDevices,
            defaultOutputName: model.defaultOutputDevice?.name ?? "Unavailable",
            defaultInputName: model.defaultInputDevice?.name ?? "Unavailable")
        state.recent = model.sessionManager.recentSessions
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(Self.recentCount)
            .map { MenuText.recentRow($0, calendar: .current) }
        return state
    }

    private var micName: String {
        let model = appModel
        let chosen = model.selectedMicUID.flatMap { uid in model.inputDevices.first { $0.uid == uid } }
        return (chosen ?? model.defaultInputDevice)?.name ?? "No microphone found"
    }

    private var outputName: String {
        let model = appModel
        let chosen = model.selectedOutputUID.flatMap { uid in model.outputDevices.first { $0.uid == uid } }
        return (chosen ?? model.defaultOutputDevice)?.name ?? "No output found"
    }

    private func liveSetup(online: Bool) -> LiveSetup {
        let settings = appModel.settingsManager
        let memosOffline = settings.llmProvider == .openrouter && !online
        let caption: String
        if memosOffline {
            caption = "Offline — automatic memos need internet. Local transcript and manual notes work offline."
        } else if appModel.automaticLiveMemos {
            caption = settings.llmProvider == .openrouter
                ? "Committed transcript goes to OpenRouter · \(settings.model(for: .live)). No speech is uploaded."
                : "Committed transcript goes to the configured LLM server · \(settings.model(for: .live))."
        } else {
            caption = "Manual notes and local transcript only."
        }
        return LiveSetup(
            modelName: settings.whisperModel.rawValue, preparing: appModel.liveMeeting.isPreparing,
            downloadBlocked: NetworkPolicy.downloadBlockReason(isOnline: online),
            memosOffline: memosOffline, memosCaption: caption)
    }

    // MARK: Choices and actions

    private var choices: MenuChoices {
        @Bindable var model = appModel
        return MenuChoices(
            recordingType: $model.selectedRecordingType, speech: $model.selectedSpeechLanguage,
            notes: $model.selectedNotesLanguage, liveEnabled: $model.liveMeetingEnabled,
            automaticMemos: $model.automaticLiveMemos, includeMicrophone: $model.includeMicrophone,
            outputUID: $model.selectedOutputUID, micUID: $model.selectedMicUID)
    }

    private var actions: MenuActions {
        let model = appModel
        return MenuActions(
            record: {
                Task { @MainActor in
                    await model.toggleRecording()
                    // A live meeting opens its floating panel, as the old Live Meeting window did.
                    if model.state == .recording && model.liveMeetingEnabled { model.showLivePanel() }
                }
            },
            cancelProcessing: { model.cancelTranscription() },
            downloadLiveModel: {
                model.liveMeeting.prepareModel(bridge: model.pythonBridge, modelName: model.settingsManager.whisperModel.rawValue)
            },
            cancelLiveDownload: { model.liveMeeting.cancel() },
            openArchive: { path in model.showArchiveWindow(path: path) },
            openBrowser: {
                if let url = model.webLoginURL(path: "/sessions") { NSWorkspace.shared.open(url) }
            },
            openLivePanel: { model.showLivePanel() },
            openDiagnostics: {
                Self.logger.info("Opening the Diagnostics window")
                // A menu bar app isn't active, so the window would open behind other apps.
                openWindow(id: "diagnostics")
                NSApplication.shared.activate(ignoringOtherApps: true)
            },
            quit: {
                Self.logger.info("Quit requested from popover")
                // Triggers applicationWillTerminate -> teardownForExit.
                NSApplication.shared.terminate(nil)
            })
    }
}
