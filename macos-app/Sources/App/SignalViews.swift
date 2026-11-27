import SwiftUI

/// Faint horizontal scanlines over the oxide ground (1 px every 3 px, as the canvas).
struct Scanlines: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(SignalPalette.fg.opacity(0.03)))
                y += 3
            }
        }
        .accessibilityHidden(true)
    }
}

/// Outlined secondary button: transparent with a strong line, as the canvas's "Open archive".
struct SignalOutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SignalFonts.body(13, weight: .semibold))
            .foregroundStyle(SignalPalette.fg)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(configuration.isPressed ? SignalPalette.panel : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SignalPalette.lineStrong, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The big Record/Stop button: rust fill to start, an outlined light frame to stop.
struct SignalRecordButtonStyle: ButtonStyle {
    let stops: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return HStack(spacing: 10) {
            if stops {
                Rectangle().fill(SignalPalette.fg).frame(width: 11, height: 11)
            } else {
                Circle().fill(SignalPalette.void).frame(width: 12, height: 12)
            }
            configuration.label
        }
        .font(SignalFonts.display(22))
        .tracking(0.6)
        .textCase(.uppercase)
        .foregroundStyle(stops ? SignalPalette.fg : SignalPalette.void)
        .frame(maxWidth: .infinity, minHeight: stops ? 50 : 52)
        .background(stops ? Color.clear : (configuration.isPressed ? SignalPalette.highlight : SignalPalette.rust), in: shape)
        .overlay { if stops { shape.strokeBorder(SignalPalette.fg, lineWidth: 1.5) } }
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A plain text link in rust, for "Change" and the footer.
struct SignalLinkButtonStyle: ButtonStyle {
    var color: Color = SignalPalette.rust
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? SignalPalette.highlight : color)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The REC mark: a chromatic split (rust right, cyan left) that jitters now and then,
/// after the web's `rec-glitch` keyframes. The only glitch in the native UI; with
/// Reduce Motion the static split stays and nothing moves.
struct RecMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(SignalPalette.rust).frame(width: 10, height: 10)
            if reduceMotion {
                split(GlitchFrame.rest)
            } else {
                TimelineView(.periodic(from: .now, by: 0.064)) { context in
                    split(GlitchFrame.at(context.date.timeIntervalSinceReferenceDate))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording")
    }

    private func split(_ frame: GlitchFrame) -> some View {
        let label = Text("REC").font(SignalFonts.display(20)).tracking(1.6)
        return ZStack {
            label.foregroundStyle(SignalPalette.glitchCyan).offset(x: frame.cyan)
            label.foregroundStyle(SignalPalette.rust).offset(x: frame.rust)
            label.foregroundStyle(SignalPalette.highlight)
        }
        .offset(x: frame.shift)
        .transformEffect(CGAffineTransform(a: 1, b: 0, c: frame.skew, d: 1, tx: 0, ty: 0))
    }
}

/// One frame of the REC jitter: a 3.2 s loop, still except for 88–92% (`steps(1, end)`
/// in the web keyframes holds each step until the next one).
struct GlitchFrame: Equatable {
    let rust: CGFloat
    let cyan: CGFloat
    let shift: CGFloat
    let skew: CGFloat

    static let rest = GlitchFrame(rust: 1.5, cyan: -1.5, shift: 0, skew: 0)

    static func at(_ time: TimeInterval) -> GlitchFrame {
        let phase = time.truncatingRemainder(dividingBy: 3.2) / 3.2
        switch phase {
        case 0.88..<0.90: return GlitchFrame(rust: 3, cyan: -2.5, shift: 1, skew: -0.105)  // skewX(-6deg)
        case 0.90..<0.92: return GlitchFrame(rust: -1.5, cyan: 2, shift: -1, skew: 0)
        default: return rest
        }
    }
}
