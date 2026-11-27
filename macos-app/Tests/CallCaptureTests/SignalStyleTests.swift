import Foundation
import Testing

@testable import CallCapture

/// The popover's signal-room colours mirror the web tokens, and only the bundled
/// latin `.woff2` of each face is registered.
@Suite struct SignalStyleTests {
    private static let tokensCSS = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("web/src/styles/tokens.css")

    /// `--name: #rrggbb;` pairs from `:root`.
    private static func cssTokens() throws -> [String: UInt32] {
        let css = try String(contentsOf: tokensCSS, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"--([a-z-]+):\s*#([0-9a-fA-F]{6})\s*;"#)
        var tokens: [String: UInt32] = [:]
        for match in pattern.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
            guard let name = Range(match.range(at: 1), in: css), let hex = Range(match.range(at: 2), in: css),
                let value = UInt32(css[hex], radix: 16)
            else { continue }
            tokens[String(css[name])] = value
        }
        return tokens
    }

    @Test func paletteMirrorsEveryWebColourToken() throws {
        let css = try Self.cssTokens()
        #expect(css.count >= 17, "parsed \(css.count) tokens from \(Self.tokensCSS.path)")
        #expect(SignalPalette.tokens == css)
    }

    @Test func fontFilesAreTheLatinWoff2OfEachFace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-fonts-\(UUID().uuidString)")
        let assets = dir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = [
            "barlow-condensed-latin-800-normal-BKzMuPgK.woff2",
            "barlow-condensed-latin-800-normal-e9GbPXiK.woff",
            "barlow-condensed-latin-ext-800-normal-DGNyg4u8.woff2",
            "ibm-plex-mono-cyrillic-400-normal-BSMlKf0J.woff2",
            "ibm-plex-mono-latin-500-normal-DSY6xOcd.woff2",
            "instrument-sans-latin-600-normal-B7fBEWYG.woff2",
            "index-DGyIxfwB.css",
            "roboto-latin-400-normal-AAAA.woff2",
        ]
        for name in names { try Data().write(to: assets.appendingPathComponent(name)) }
        let chosen = SignalFonts.fontFiles(in: dir).map(\.lastPathComponent).sorted()
        #expect(chosen == [
            "barlow-condensed-latin-800-normal-BKzMuPgK.woff2",
            "ibm-plex-mono-latin-500-normal-DSY6xOcd.woff2",
            "instrument-sans-latin-600-normal-B7fBEWYG.woff2",
        ])
    }

    @Test func recGlitchIsStillExceptForTwoShortSteps() {
        let loop = 3.2
        #expect(GlitchFrame.at(0) == .rest)
        #expect(GlitchFrame.at(loop * 0.5) == .rest)
        #expect(GlitchFrame.at(loop * 0.87) == .rest)
        #expect(GlitchFrame.at(loop * 0.89) == GlitchFrame(rust: 3, cyan: -2.5, shift: 1, skew: -0.105))
        #expect(GlitchFrame.at(loop * 0.91) == GlitchFrame(rust: -1.5, cyan: 2, shift: -1, skew: 0))
        #expect(GlitchFrame.at(loop * 0.95) == .rest)
        #expect(GlitchFrame.at(loop * 10 + loop * 0.89) != .rest)
    }

    @Test func noWebDirectoryMeansNoFontFiles() {
        #expect(SignalFonts.fontFiles(in: nil).isEmpty)
        #expect(SignalFonts.fontFiles(in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).isEmpty)
    }
}
