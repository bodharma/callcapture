import SwiftUI

/// Full speaker-labelled transcript with click-to-seek playback of the session audio.
@available(macOS 14.2, *)
struct TranscriptPlayerView: View {
    /// Lines with the worker's original labels; `names` maps them for display.
    let lines: [TranscriptLine]
    let names: SpeakerNames
    let audioPath: String
    let focusTime: Double?
    /// The system tap captures every process, so playback during a recording would be recorded.
    let playbackBlocked: Bool
    let onRename: (_ label: String, _ name: String) -> Void

    @State private var player = SessionAudioPlayer()
    @State private var renamingLabel: String?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(lines.indices, id: \.self) { index in
                            row(index).id(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 160, maxHeight: 380)
                .onAppear { scrollToFocus(proxy) }
                .onChange(of: focusTime) { _, time in
                    guard let time else { return }
                    player.seek(to: time, play: false)
                    scrollToFocus(proxy)
                }
            }
        }
        .onAppear {
            player.load(path: audioPath, lines: lines)
            if let focusTime { player.seek(to: focusTime, play: false) }
        }
        .onDisappear { player.pause() }
        .onChange(of: playbackBlocked) { _, blocked in
            if blocked { player.pause() }
        }
        // `presenting:` hands the label to the actions, so Save works whatever order
        // SwiftUI clears `renamingLabel` in when the alert dismisses.
        .alert("Rename speaker", isPresented: Binding(
            get: { renamingLabel != nil },
            set: { if !$0 { renamingLabel = nil } }
        ), presenting: renamingLabel) { label in
            TextField("Name", text: $newName)
            Button("Save") { onRename(label, newName) }
            Button("Cancel", role: .cancel) {}
        } message: { label in
            Text("Applies to this session's transcript, insights, search and exports. "
                 + "Leave empty to restore \"\(label)\".")
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle()
            } label: {
                Label(player.isPlaying ? "Pause" : "Play",
                      systemImage: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(playbackBlocked || !player.isLoaded)

            PlaybackClock(player: player)

            Spacer()

            Picker("Speed", selection: $player.rate) {
                ForEach(SessionAudioPlayer.rates, id: \.self) { rate in
                    Text("\(rate, specifier: "%g")×").tag(rate)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        if playbackBlocked {
            Text("Playback is off while recording, so it isn't captured into the new recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let error = player.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        let line = lines[index]
        let stamp = TranscriptDocument.timestamp(line.start)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(stamp) { player.seek(to: line.start, play: true) }
                .buttonStyle(.link)
                .font(.caption.monospacedDigit())
                .disabled(playbackBlocked || !player.isLoaded)
                .help("Play from \(stamp)")
            if let label = line.speaker {
                Button(names.display(label) ?? label) {
                    newName = names.display(label) == label ? "" : (names.display(label) ?? "")
                    renamingLabel = label
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .help("Rename \(label)")
            }
            Text(line.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(player.currentLine == index ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let focusTime, let index = TranscriptDocument.lineIndex(at: focusTime, in: lines) else { return }
        // Lazy rows need one layout pass before they can be scrolled to.
        DispatchQueue.main.async { proxy.scrollTo(index, anchor: .center) }
    }
}

/// Isolated so only the clock redraws on every playback tick.
@available(macOS 14.2, *)
private struct PlaybackClock: View {
    let player: SessionAudioPlayer

    var body: some View {
        Text("\(TranscriptDocument.timestamp(player.currentTime)) / \(TranscriptDocument.timestamp(player.duration))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// Whole note text (no preview cut-off), inline Markdown rendered, line breaks kept.
@available(macOS 14.2, *)
struct NoteTextView: View {
    let text: String

    var body: some View {
        ScrollView {
            Group {
                if let rendered = try? AttributedString(
                    markdown: text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(rendered)
                } else {
                    Text(text)
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 120, maxHeight: 380)
    }
}
