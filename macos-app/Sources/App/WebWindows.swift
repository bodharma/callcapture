import AppKit
import OSLog
import WebKit

/// Builds the login URL for an app path, or nil while the local server is not
/// running (so callers never hand out a port-0 URL).
typealias LoginURLProvider = @MainActor (String) -> URL?

/// One non-persistent data store for every native web host in this app run:
/// cookies never reach disk, and server sessions die with the app anyway.
@MainActor
private let sharedWebDataStore = WKWebsiteDataStore.nonPersistent()

private let webHostLogger = Logger(subsystem: "com.callcapture.app", category: "WebHost")

/// Navigation and download policy shared by the archive window and live panel.
@MainActor
final class WebHostDelegate: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    private let ownPort: @MainActor () -> Int?

    init(ownPort: @escaping @MainActor () -> Int?) {
        self.ownPort = ownPort
    }

    /// Only the app's own loopback origin may load in the web view.
    func isOwnOrigin(_ url: URL) -> Bool {
        guard let port = ownPort(), url.scheme == "http", url.port == port,
            let host = url.host
        else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        // about:blank and similar internal loads are not network navigations.
        if url.scheme == "about" { return decisionHandler(.allow) }
        if !isOwnOrigin(url) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
        if disposition?.hasPrefix("attachment") == true || !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        completionHandler(panel.runModal() == .OK ? panel.url : nil)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        webHostLogger.error("Download failed: \(error.localizedDescription)")
    }
}

/// Creates the configured web view both hosts embed.
@MainActor
private func makeWebView(delegate: WebHostDelegate) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = sharedWebDataStore
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = delegate
    return webView
}

/// The archive window: one reusable NSWindow hosting the local web UI.
@MainActor
final class WebWindowController {
    private let loginURL: LoginURLProvider
    private let delegate: WebHostDelegate
    private var window: NSWindow?
    private var webView: WKWebView?

    init(loginURL: @escaping LoginURLProvider, ownPort: @escaping @MainActor () -> Int?) {
        self.loginURL = loginURL
        self.delegate = WebHostDelegate(ownPort: ownPort)
    }

    func show(path: String) {
        guard let url = loginURL(path) else {
            webHostLogger.error("Archive window requested while the local server is not running")
            return
        }
        let window = window ?? makeWindow()
        webView?.load(URLRequest(url: url))
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let webView = makeWebView(delegate: delegate)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "CallCapture"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        self.webView = webView
        self.window = window
        return window
    }
}

/// The floating live panel: a compact-layout web view above other windows.
@MainActor
final class LivePanelController {
    private let loginURL: LoginURLProvider
    private let delegate: WebHostDelegate
    private var panel: NSPanel?
    private var webView: WKWebView?

    init(loginURL: @escaping LoginURLProvider, ownPort: @escaping @MainActor () -> Int?) {
        self.loginURL = loginURL
        self.delegate = WebHostDelegate(ownPort: ownPort)
    }

    func show() {
        guard let url = loginURL("/live?compact=1") else {
            webHostLogger.error("Live panel requested while the local server is not running")
            return
        }
        let panel = panel ?? makePanel()
        webView?.load(URLRequest(url: url))
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let webView = makeWebView(delegate: delegate)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "CallCapture Live"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // ScreenCaptureKit on macOS 15.4+ ignores sharingType (Apple documents no
        // public API that prevents capture), so this only hides the panel from
        // legacy capture APIs. It is not a promise of privacy from screen sharing.
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = webView
        panel.center()
        self.webView = webView
        self.panel = panel
        return panel
    }
}
