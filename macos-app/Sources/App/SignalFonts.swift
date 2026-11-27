import AppKit
import CoreText
import OSLog
import SwiftUI

/// The signal-room faces for the native popover, taken from the web UI's bundled
/// fontsource files (OFL) so no font is fetched or duplicated in the repo.
///
/// Each face ships split by script (latin, latin-ext, cyrillic, …) under one
/// PostScript name, so only the `-latin-` `.woff2` of each weight is registered;
/// other scripts (Cyrillic titles) fall back through CoreText's cascade. A face
/// that didn't register falls back to SF Pro (condensed for display) or SF Mono.
enum SignalFonts {
    private static let families = ["barlow-condensed", "instrument-sans", "ibm-plex-mono"]
    private static let logger = Logger(subsystem: "com.callcapture.app", category: "SignalFonts")

    /// `<family>-latin-<weight>-normal-<hash>.woff2` files under `<web>/assets`.
    static func fontFiles(in webDirectory: URL?) -> [URL] {
        guard let assets = webDirectory?.appendingPathComponent("assets", isDirectory: true),
            let names = try? FileManager.default.contentsOfDirectory(atPath: assets.path)
        else { return [] }
        return names.filter(isLatinWoff2).sorted().map { assets.appendingPathComponent($0) }
    }

    private static func isLatinWoff2(_ name: String) -> Bool {
        guard name.hasSuffix(".woff2") else { return false }
        return families.contains { family in
            let prefix = family + "-latin-"
            guard name.hasPrefix(prefix) else { return false }
            let parts = name.dropFirst(prefix.count).split(separator: "-", maxSplits: 2)
            return parts.count == 3 && parts[0].allSatisfy(\.isNumber) && parts[1] == "normal"
        }
    }

    /// Registers the bundled faces for this process. Call once at launch, before any view.
    @discardableResult
    static func registerBundled(webDirectory: URL? = defaultWebDirectory()) -> Int {
        var count = 0
        for url in fontFiles(in: webDirectory) {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                count += 1
            } else {
                let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown"
                logger.error("Font \(url.lastPathComponent, privacy: .public) not registered: \(reason, privacy: .public)")
            }
        }
        logger.info("Registered \(count) bundled fonts; missing faces use system fonts")
        return count
    }

    // MARK: Faces

    /// Barlow Condensed: brand, buttons, timer and topic titles.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        let name =
            switch weight {
            case .semibold: "BarlowCondensed-SemiBold"
            case .bold: "BarlowCondensed-Bold"
            default: "BarlowCondensed-ExtraBold"
            }
        return available(name) ? .custom(name, size: size) : .system(size: size, weight: weight).width(.condensed)
    }

    /// Instrument Sans: reading text.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name =
            switch weight {
            case .medium: "InstrumentSans-Medium"
            case .semibold, .bold, .heavy, .black: "InstrumentSans-SemiBold"
            default: "InstrumentSans-Regular"
            }
        return available(name) ? .custom(name, size: size) : .system(size: size, weight: weight)
    }

    /// IBM Plex Mono: machine readouts (channels, timecodes, costs).
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = weight == .regular ? "IBMPlexMono-Regular" : "IBMPlexMono-Medium"
        return available(name) ? .custom(name, size: size) : .system(size: size, weight: weight, design: .monospaced)
    }

    private static func available(_ name: String) -> Bool {
        NSFont(name: name, size: 12) != nil
    }
}
