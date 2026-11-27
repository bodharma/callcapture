import SwiftUI

/// The signal-room colours, mirroring `web/src/styles/tokens.css` (a test checks
/// that every web token is here with the same value).
enum SignalPalette {
    static let tokens: [String: UInt32] = [
        "void": 0x0f1311,
        "panel": 0x161b17,
        "line": 0x2b352e,
        "line-strong": 0x3a4740,
        "fg": 0xdfe8da,
        "ash": 0x93a08f,
        "signal": 0x8ee3a6,
        "rust": 0xe0805f,
        "amber": 0xe2b45a,
        "panel-raised": 0x1c231e,
        "tape": 0x121714,
        "line-faint": 0x232b25,
        "fg-soft": 0xc7d1c3,
        "fg-mid": 0xb9c4b5,
        "highlight": 0xf2e9e1,
        "meter-off": 0x26302a,
        "rust-hover": 0xf0a184,
    ]

    static let void = color("void")
    static let panel = color("panel")
    static let line = color("line")
    static let lineStrong = color("line-strong")
    static let fg = color("fg")
    static let ash = color("ash")
    static let signal = color("signal")
    static let rust = color("rust")
    static let amber = color("amber")
    static let lineFaint = color("line-faint")
    static let fgSoft = color("fg-soft")
    static let fgMid = color("fg-mid")
    static let highlight = color("highlight")
    static let meterOff = color("meter-off")

    /// Literals the canvas and the web use outside the tokens: the offline box and the
    /// REC mark's cyan split.
    static let amberInk = Color(hex: 0xe7cf9c)
    static let amberWash = Color(hex: 0x1d1a12)
    static let glitchCyan = Color(hex: 0x4fc9d6)

    static func tone(_ tone: SignalTone) -> Color {
        switch tone {
        case .rust: rust
        case .soft: fgMid
        case .amber: amber
        case .signal: signal
        case .ash: ash
        }
    }

    private static func color(_ name: String) -> Color {
        Color(hex: tokens[name] ?? 0xff00ff)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}
