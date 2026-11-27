import SwiftUI

/// One choice in a popover menu.
struct ChoiceOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }
}

/// A plain-text menu showing the current choice; picking one sets the binding.
struct ChoiceMenu<Value: Hashable>: View {
    let title: String
    let selection: Binding<Value>
    let options: [ChoiceOption<Value>]

    var body: some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(options) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(options.first { $0.value == selection.wrappedValue }?.label ?? "Choose…")
                .font(SignalFonts.body(13))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

private struct FieldLabel: View {
    let text: String
    var body: some View { Text(text).foregroundStyle(SignalPalette.ash).frame(width: 96, alignment: .leading) }
}

/// This meeting: kind, speech and notes languages, and the live map toggle.
struct MeetingFields: View {
    let choices: MenuChoices

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                FieldLabel(text: "Kind")
                ChoiceMenu(title: "Kind", selection: choices.recordingType,
                           options: RecordingType.allCases.map { ChoiceOption(value: $0, label: $0.displayName) })
            }
            GridRow {
                FieldLabel(text: "Speech")
                ChoiceMenu(title: "Speech language", selection: choices.speech, options: Self.languages)
            }
            GridRow {
                FieldLabel(text: "Notes in")
                ChoiceMenu(title: "Notes language", selection: choices.notes, options: Self.languages)
            }
            GridRow {
                FieldLabel(text: "Live map")
                HStack {
                    Text(choices.liveEnabled.wrappedValue ? "Speech on this Mac" : "Off")
                        .font(SignalFonts.body(12)).foregroundStyle(SignalPalette.fgMid)
                    Spacer()
                    Toggle("Live map", isOn: choices.liveEnabled)
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(SignalPalette.signal)
                }
            }
        }
        .font(SignalFonts.body(13))
        .padding(.horizontal, 2)
    }

    private static let languages = SpokenLanguage.allCases.map { ChoiceOption(value: $0, label: $0.displayName) }
}

/// Output and microphone choices, behind "Change" (a nil choice follows the Mac).
struct DevicePickers: View {
    let devices: DeviceLists
    let choices: MenuChoices

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                FieldLabel(text: "Output")
                ChoiceMenu(title: "Output device", selection: choices.outputUID,
                           options: Self.options(devices.outputs, defaultName: devices.defaultOutputName))
            }
            GridRow {
                FieldLabel(text: "Microphone")
                Toggle("Include microphone", isOn: choices.includeMicrophone)
                    .toggleStyle(.switch).controlSize(.mini).tint(SignalPalette.signal)
                    .font(SignalFonts.body(12))
            }
            if choices.includeMicrophone.wrappedValue {
                GridRow {
                    FieldLabel(text: "Mic")
                    ChoiceMenu(title: "Microphone device", selection: choices.micUID,
                               options: Self.options(devices.inputs, defaultName: devices.defaultInputName))
                }
            }
        }
        .font(SignalFonts.body(13))
        .padding(.horizontal, 2)
    }

    private static func options(_ list: [AudioDeviceInfo], defaultName: String) -> [ChoiceOption<String?>] {
        [ChoiceOption(value: nil, label: "System default (\(defaultName))")]
            + list.map { ChoiceOption(value: $0.uid, label: $0.name) }
    }
}

/// The live map's local model download and automatic memos, with the old popover's wording.
struct LiveSetupBlock: View {
    let setup: LiveSetup
    let automaticMemos: Binding<Bool>
    let actions: MenuActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("Speech stays on this Mac. Model: \(setup.modelName). Auto/mixed speech is experimental and may omit or mistranscribe words. Choose English or Ukrainian when possible; recording and manual notes remain available.")
            HStack(spacing: 10) {
                Button(setup.preparing ? "Downloading model…" : "Download live model", action: actions.downloadLiveModel)
                    .buttonStyle(SignalOutlineButtonStyle(height: 30))
                    .disabled(setup.preparing || setup.downloadBlocked != nil)
                if setup.preparing {
                    Button("Cancel download", action: actions.cancelLiveDownload)
                        .buttonStyle(SignalLinkButtonStyle()).font(SignalFonts.body(12, weight: .semibold)).fixedSize()
                }
            }
            if let blocked = setup.downloadBlocked, !setup.preparing { caption(blocked) }
            Toggle("Automatic memos", isOn: automaticMemos)
                .toggleStyle(.switch).controlSize(.mini).tint(SignalPalette.signal)
                .font(SignalFonts.body(12))
                .disabled(setup.memosOffline)
            caption(setup.memosCaption)
        }
        .padding(.leading, 104)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(SignalFonts.body(11.5)).foregroundStyle(SignalPalette.ash)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The last few sessions; each opens in the archive window.
struct RecentList: View {
    let rows: [MenuRecentRow]
    let enabled: Bool
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("Nothing recorded yet.").font(SignalFonts.body(12)).foregroundStyle(SignalPalette.ash).padding(.vertical, 7)
            }
            ForEach(rows) { row in
                Button { open(row.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.date).font(SignalFonts.mono(11)).foregroundStyle(SignalPalette.ash)
                            .frame(width: 44, alignment: .leading)
                        Text(row.title).font(SignalFonts.body(13)).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.state).font(SignalFonts.mono(11)).foregroundStyle(SignalPalette.tone(row.tone))
                    }
                    .padding(.vertical, 7).padding(.horizontal, 2)
                    .overlay(alignment: .bottom) {
                        Rectangle().stroke(SignalPalette.lineFaint, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(height: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SignalLinkButtonStyle(color: SignalPalette.fg))
                .disabled(!enabled)
                .accessibilityLabel("\(row.title), \(row.state), \(row.date)")
                .accessibilityHint("Opens the session in the archive window")
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(SignalPalette.line).frame(height: 1) }
    }
}

/// Open archive / Settings / Open in browser / Open live panel: disabled, with the
/// reason, until the local server is running.
struct MenuEntries: View {
    let serverUp: Bool
    let actions: MenuActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Open archive") { actions.openArchive("/sessions") }.buttonStyle(SignalOutlineButtonStyle())
                Button { actions.openArchive("/settings") } label: {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(SignalPalette.fgMid)
                }
                .buttonStyle(SignalOutlineButtonStyle())
                .frame(width: 36)
                .accessibilityLabel("Settings")
                .help("Settings")
            }
            HStack(spacing: 8) {
                Button("Open in browser", action: actions.openBrowser).buttonStyle(SignalOutlineButtonStyle(height: 32))
                Button("Open live panel", action: actions.openLivePanel).buttonStyle(SignalOutlineButtonStyle(height: 32))
            }
            if !serverUp {
                Text("Local server isn't running.").font(SignalFonts.body(12)).foregroundStyle(SignalPalette.ash)
            }
        }
        .disabled(!serverUp)
    }
}

/// Diagnostics (native window) and Quit.
struct MenuFooter: View {
    let actions: MenuActions

    var body: some View {
        HStack {
            Button("Diagnostics", action: actions.openDiagnostics)
            Spacer()
            Button("Quit CallCapture", action: actions.quit).keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(SignalLinkButtonStyle(color: SignalPalette.ash))
        .font(SignalFonts.body(12))
    }
}
