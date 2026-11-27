import SwiftUI

/// "CALLCAPTURE" with the small status word (idle, starting, processing, error).
struct MenuReadyHeader: View {
    let word: String

    var body: some View {
        HStack {
            Text("Callcapture").font(SignalFonts.display(22)).tracking(0.4).textCase(.uppercase)
            Spacer()
            HStack(spacing: 6) {
                Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 8, height: 8)
                Text(word).font(SignalFonts.mono(11.5)).foregroundStyle(color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(word)")
        }
    }

    private var color: Color {
        switch word {
        case "error": SignalPalette.rust
        case "processing", "starting", "stopping": SignalPalette.fgMid
        default: SignalPalette.ash
        }
    }
}

/// The REC mark and the session being recorded.
struct MenuRecordingHeader: View {
    let title: String

    var body: some View {
        HStack {
            RecMark()
            Spacer()
            Text(title).font(SignalFonts.body(12)).foregroundStyle(SignalPalette.ash).lineLimit(1)
        }
    }
}

/// The running time since capture started, with the channel count beside it.
struct RecordingClock: View {
    let startedAt: Date?
    let channelCount: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .bottom) {
                Text(MenuText.elapsed(startedAt.map { context.date.timeIntervalSince($0) } ?? 0))
                    .font(SignalFonts.display(72))
                    .monospacedDigit()
                    .accessibilityLabel("Recording time")
                Spacer()
                Text(channelCount == 1 ? "1 channel" : "\(channelCount) channels")
                    .font(SignalFonts.mono(11))
                    .foregroundStyle(SignalPalette.ash)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// ch.1 You / ch.2 Remote with their device or status text (no level meters).
struct ChannelsCard: View {
    let channels: [MenuChannel]
    let note: String
    /// "Change" or "Done" for the device pickers; nil while recording.
    let changeTitle: String?
    let change: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(channels) { channel in
                    GridRow {
                        Text(channel.id).font(SignalFonts.mono(11)).foregroundStyle(SignalPalette.ash)
                            .frame(width: 34, alignment: .leading)
                        Text(channel.name).font(SignalFonts.body(13, weight: .semibold))
                            .frame(width: 58, alignment: .leading)
                        Text(channel.detail).font(SignalFonts.body(13)).foregroundStyle(SignalPalette.fgMid)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            HStack(spacing: 4) {
                Text(note)
                if let changeTitle {
                    Button(changeTitle, action: change).buttonStyle(SignalLinkButtonStyle())
                }
            }
            .font(SignalFonts.body(12))
            .foregroundStyle(SignalPalette.ash)
        }
        .padding(12)
        .background(SignalPalette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SignalPalette.line, lineWidth: 1))
    }
}

/// Record or Stop, by the shared `RecordingButton` rule, with its reason when disabled.
struct RecordControl: View {
    let state: MenuState
    let record: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(state.recordLabel, action: record)
                .buttonStyle(SignalRecordButtonStyle(stops: state.button.action == .stopping))
                .disabled(!state.button.enabled)
            if let reason = state.button.reason {
                Text(reason).font(SignalFonts.body(12)).foregroundStyle(SignalPalette.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Processing progress and the menu's Cancel (the web's refusal text points here).
struct ProcessingBlock: View {
    let progress: Double
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: min(max(progress, 0), 1)).progressViewStyle(.linear).tint(SignalPalette.signal)
            HStack {
                Text("Processing the recording…").font(SignalFonts.mono(11)).foregroundStyle(SignalPalette.ash)
                Spacer()
                Button("Cancel processing", action: cancel)
                    .buttonStyle(SignalLinkButtonStyle())
                    .font(SignalFonts.body(12, weight: .semibold))
            }
        }
    }
}

/// The amber offline line, the app's notice and the last error.
struct MenuNotices: View {
    let state: MenuState

    var body: some View {
        if let offline = state.offlineLine {
            Text(offline)
                .font(SignalFonts.body(12))
                .lineSpacing(2)
                .foregroundStyle(SignalPalette.amberInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(SignalPalette.amberWash)
                .overlay(alignment: .leading) { Rectangle().fill(SignalPalette.amber).frame(width: 2) }
        }
        if let notice = state.notice {
            Text(notice).font(SignalFonts.body(12)).foregroundStyle(SignalPalette.fgSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let problem = state.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(SignalFonts.body(12)).foregroundStyle(SignalPalette.rust)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The live map's current topic and the last committed line.
struct NowOnBlock: View {
    let now: MenuLiveNow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Now on").font(SignalFonts.body(12)).foregroundStyle(SignalPalette.ash)
            Text(now.topic).font(SignalFonts.display(24, weight: .bold)).lineLimit(2)
            if let quote = now.quote {
                Text("“\(quote)”").font(SignalFonts.body(13)).lineSpacing(3).foregroundStyle(SignalPalette.fgSoft)
                    .lineLimit(4)
            } else {
                Text("Listening for speech.").font(SignalFonts.body(13)).foregroundStyle(SignalPalette.ash)
            }
            if let source = now.source {
                Text(source).font(SignalFonts.mono(11)).foregroundStyle(SignalPalette.ash)
            }
        }
        .padding(.horizontal, 2)
    }
}
