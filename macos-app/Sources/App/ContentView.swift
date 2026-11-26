import SwiftUI
import AppKit
import OSLog

/// Main popover content displayed from the menu bar icon.
/// Shows recording status, control button, last session info,
/// and a link to the diagnostics window.
@available(macOS 14.2, *)
struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "ContentView"
    )

    /// Opens a window scene and brings the app to the foreground.
    ///
    /// A menu bar (`LSUIElement`) app is not the active application, so
    /// `openWindow` alone creates the window *behind* other apps with no
    /// focus — it looks like nothing happened. Activating fixes that.
    private func showWindow(_ id: String) {
        Self.logger.info("Opening window '\(id)'")
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some View {
        @Bindable var appModel = appModel
        return VStack(spacing: 16) {
            statusHeader
            if appModel.state == .idle || appModel.state == .error {
                devicePickers(appModel: appModel)
            }
            if appModel.state == .recording {
                Text("Device choices apply when recording starts. Unplugging an active device may interrupt audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if appModel.liveMeetingEnabled {
                Button("Open Live Meeting") { showWindow("live-meeting") }
                    .buttonStyle(.bordered)
                Text(appModel.liveMeeting.status).font(.caption2).foregroundStyle(.secondary)
            }
            recordButton
            transcriptionProgress
            lastSessionInfo
            Divider()
            sessionsButton
            settingsButton
            diagnosticsButton
            Divider()
            quitButton
        }
        .padding()
        .frame(width: 280)
        .onAppear { appModel.refreshAudioDevices() }
    }

    /// Output (speaker) and microphone selection, shown before recording.
    @ViewBuilder
    private func devicePickers(appModel: AppModel) -> some View {
        @Bindable var appModel = appModel
        VStack(spacing: 6) {
            Picker("Type", selection: $appModel.selectedRecordingType) {
                ForEach(RecordingType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            Picker("Output", selection: $appModel.selectedOutputUID) {
                Text("System Default (\(appModel.defaultOutputDevice?.name ?? "Unavailable"))")
                    .tag(String?.none)
                ForEach(appModel.outputDevices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            Picker("Speech", selection: $appModel.selectedSpeechLanguage) {
                ForEach(SpokenLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Notes", selection: $appModel.selectedNotesLanguage) {
                ForEach(SpokenLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Local live meeting", isOn: $appModel.liveMeetingEnabled)
                .toggleStyle(.checkbox)
            if appModel.liveMeetingEnabled {
                Text("Speech stays on this Mac. Model: \(appModel.settingsManager.whisperModel.rawValue). Auto/mixed speech is experimental and may omit or mistranscribe words. Choose English or Ukrainian when possible; recording and manual notes remain available.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button(appModel.liveMeeting.isPreparing ? "Downloading model…" : "Download live model") {
                    appModel.liveMeeting.prepareModel(bridge: appModel.pythonBridge,
                                                     modelName: appModel.settingsManager.whisperModel.rawValue)
                }.disabled(appModel.liveMeeting.isPreparing)
                if appModel.liveMeeting.isPreparing {
                    Button("Cancel download") { appModel.liveMeeting.cancel() }
                }
                Toggle("Automatic memos", isOn: $appModel.automaticLiveMemos).toggleStyle(.checkbox)
                if appModel.automaticLiveMemos {
                    Text(appModel.settingsManager.llmProvider == .openrouter
                         ? "Committed transcript goes to OpenRouter · \(appModel.settingsManager.model(for: .live)). No speech is uploaded."
                         : "Committed transcript goes to the configured LLM server · \(appModel.settingsManager.model(for: .live)).")
                        .font(.caption2).foregroundStyle(.secondary)
                } else { Text("Manual notes and local transcript only.").font(.caption2).foregroundStyle(.secondary) }
            }
            Toggle("Include Microphone", isOn: $appModel.includeMicrophone)
                .toggleStyle(.checkbox)
            if appModel.includeMicrophone {
                Picker("Mic", selection: $appModel.selectedMicUID) {
                    Text("System Default (\(appModel.defaultInputDevice?.name ?? "Unavailable"))")
                        .tag(String?.none)
                    ForEach(appModel.inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .font(.caption)
    }

    @ViewBuilder
    private var statusHeader: some View {
        HStack {
            Image(systemName: appModel.menuBarIconName)
                .font(.title2)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        Button {
            Task {
                await appModel.toggleRecording()
                if appModel.state == .recording && appModel.liveMeetingEnabled { showWindow("live-meeting") }
            }
        } label: {
            Label(
                appModel.state == .recording ? "Stop Recording" : "Start Recording",
                systemImage: appModel.state == .recording ? "stop.circle.fill" : "record.circle"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(appModel.state == .recording ? .red : .accentColor)
        .disabled(appModel.state == .transcribing || appModel.liveMeeting.isPreparing || appModel.recordingTransitionInProgress)
    }

    @ViewBuilder
    private var lastSessionInfo: some View {
        if let title = appModel.lastSessionTitle,
           let date = appModel.lastSessionDate {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last Session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline)
                // Static recorded-at time + fixed duration. Do NOT use
                // `style: .relative` here — it auto-ticks every second and
                // reads as a recording timer that never stopped.
                Text(lastSessionSubtitle(date: date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let error = appModel.lastError, appModel.state == .error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var transcriptionProgress: some View {
        if appModel.state == .transcribing {
            VStack(spacing: 8) {
                ProgressView(value: appModel.pythonBridge.progress)
                    .progressViewStyle(.linear)
                Text("Transcribing...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(role: .cancel) {
                    appModel.cancelTranscription()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var sessionsButton: some View {
        Button {
            showWindow("sessions")
        } label: {
            Label("View Sessions", systemImage: "list.bullet.rectangle")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var settingsButton: some View {
        Button {
            showWindow("settings")
        } label: {
            Label("Settings", systemImage: "gear")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var diagnosticsButton: some View {
        Button {
            showWindow("diagnostics")
        } label: {
            Label("Diagnostics", systemImage: "stethoscope")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var quitButton: some View {
        Button {
            Self.logger.info("Quit requested from popover")
            // Triggers applicationWillTerminate -> teardownForExit, which
            // releases audio capture and any running worker process.
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit CallCapture", systemImage: "power")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q", modifiers: .command)
    }

    /// Static subtitle for the last session: recorded time + fixed duration.
    private func lastSessionSubtitle(date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if let duration = appModel.lastSessionDuration {
            return "Recorded \(time) · \(formattedDuration(duration))"
        }
        return "Recorded \(time)"
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var statusColor: Color {
        switch appModel.state {
        case .idle: .secondary
        case .recording: .red
        case .transcribing: .orange
        case .error: .red
        }
    }

    private var statusText: String {
        switch appModel.state {
        case .idle: "Ready"
        case .recording: "Recording..."
        case .transcribing: "Transcribing..."
        case .error: "Error"
        }
    }
}
