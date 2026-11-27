import SwiftUI

/// Everything the popover shows, read from `AppModel` by `ContentView`. Plain values,
/// so the layout renders without the app (previews, screenshots).
struct MenuState {
    /// True while capture runs: the recording layout replaces the ready one.
    var recording = false
    var headerWord = "idle"
    var button = RecordingButton.current(state: .idle, transition: nil, livePreparing: false)
    var recordLabel = "Start recording"
    var channels: [MenuChannel] = []
    var deviceNote = MenuText.deviceNote(followsSystem: true)
    var serverUp = true
    var offlineLine: String?
    var notice: String?
    var problem: String?
    /// 0…1 while a session is being processed.
    var processing: Double?
    var recordingTitle = "Recording"
    var recordingStartedAt: Date?
    var liveNow: MenuLiveNow?
    var spendLine: String?
    var live = LiveSetup()
    var devices = DeviceLists()
    var recent: [MenuRecentRow] = []
}

/// The live map setup shown under its toggle (the wording the old popover used).
struct LiveSetup {
    var modelName = "base"
    var preparing = false
    /// Why the live model can't be downloaded now (offline); nil when it can.
    var downloadBlocked: String?
    var memosOffline = false
    var memosCaption = "Manual notes and local transcript only."
    /// The live controller's status ("Local model base is ready", a download failure, …).
    var status = "Local speech is off"
}

struct DeviceLists {
    var outputs: [AudioDeviceInfo] = []
    var inputs: [AudioDeviceInfo] = []
    var defaultOutputName = "Unavailable"
    var defaultInputName = "Unavailable"
}

/// Two-way choices for this meeting, bound to `AppModel`.
struct MenuChoices {
    var recordingType: Binding<RecordingType>
    var speech: Binding<SpokenLanguage>
    var notes: Binding<SpokenLanguage>
    var liveEnabled: Binding<Bool>
    var automaticMemos: Binding<Bool>
    var includeMicrophone: Binding<Bool>
    var outputUID: Binding<String?>
    var micUID: Binding<String?>
}

struct MenuActions {
    var record: @MainActor () -> Void = {}
    var cancelProcessing: @MainActor () -> Void = {}
    var downloadLiveModel: @MainActor () -> Void = {}
    var cancelLiveDownload: @MainActor () -> Void = {}
    /// Shows a web path (`/sessions`, `/sessions/<id>`, `/settings`) in the archive window.
    var openArchive: @MainActor (String) -> Void = { _ in }
    var openBrowser: @MainActor () -> Void = {}
    var openLivePanel: @MainActor () -> Void = {}
    var openDiagnostics: @MainActor () -> Void = {}
    var quit: @MainActor () -> Void = {}
}

/// The signal-room menu bar popover, after the canvas "Menu bar · ready" and
/// "Menu bar · recording" boards.
struct MenuPopover: View {
    let state: MenuState
    let choices: MenuChoices
    let actions: MenuActions
    @State private var showDevices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.recording { recordingLayout } else { readyLayout }
            MenuEntries(serverUp: state.serverUp, actions: actions)
            MenuFooter(actions: actions)
        }
        .padding(16)
        .frame(width: 360, alignment: .topLeading)
        .foregroundStyle(SignalPalette.fg)
        .font(SignalFonts.body(13))
        .background { ZStack { SignalPalette.void; Scanlines() } }
        .environment(\.colorScheme, .dark)
        .tint(SignalPalette.rust)
    }

    @ViewBuilder private var readyLayout: some View {
        MenuReadyHeader(word: state.headerWord)
        ChannelsCard(channels: state.channels, note: state.deviceNote, changeTitle: showDevices ? "Done" : "Change") {
            showDevices.toggle()
        }
        if showDevices { DevicePickers(devices: state.devices, choices: choices) }
        RecordControl(state: state, record: actions.record)
        if let progress = state.processing { ProcessingBlock(progress: progress, cancel: actions.cancelProcessing) }
        MeetingFields(choices: choices)
        if choices.liveEnabled.wrappedValue {
            LiveSetupBlock(setup: state.live, automaticMemos: choices.automaticMemos, actions: actions)
        }
        MenuNotices(state: state)
        RecentList(rows: state.recent, enabled: state.serverUp) { actions.openArchive(MenuText.sessionPath($0)) }
    }

    @ViewBuilder private var recordingLayout: some View {
        MenuRecordingHeader(title: state.recordingTitle)
        RecordingClock(startedAt: state.recordingStartedAt, channelCount: state.channels.contains { $0.detail == "microphone off" } ? 1 : 2)
        ChannelsCard(channels: state.channels, note: "Unplugging a device in use may interrupt audio.", changeTitle: nil) {}
        if let now = state.liveNow { NowOnBlock(now: now) }
        if let spend = state.spendLine {
            Text(spend).font(SignalFonts.mono(11)).foregroundStyle(SignalPalette.ash)
        }
        MenuNotices(state: state)
        RecordControl(state: state, record: actions.record)
    }
}
