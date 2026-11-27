import AppKit
import Foundation
import Testing

@testable import CallCapture

/// Closing the archive window or the live panel drops its page (audio, the events stream,
/// timers) by loading a blank page. No window or web view is built here.
@Suite struct WebHostTeardownTests {
    @Test(arguments: [nil, 54_321] as [Int?])
    func theBlankPageIsAllowedByTheNavigationPolicy(ownPort: Int?) {
        #expect(NavigationDecision.decide(url: WebHostTeardown.blankPage, ownPort: ownPort) == .allow)
        #expect(WebHostTeardown.request.url == WebHostTeardown.blankPage)
    }

    @MainActor @Test func closingTheWindowRunsTheTeardown() {
        var closed = 0
        let observer = WindowCloseObserver { closed += 1 }
        observer.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(closed == 1)
    }
}
