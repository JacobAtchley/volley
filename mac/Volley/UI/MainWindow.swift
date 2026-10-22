import AppKit
import SwiftUI

/// The messages window. Owned by AppKit so both the menu and a notification click can open it;
/// SwiftUI's `openWindow` is only reachable from a view that's on screen.
@MainActor
enum MainWindow {
    private static var window: NSWindow?

    static func show(session: PhoneSession, threadId: Int64? = nil) {
        if let threadId { session.open(threadId: threadId) }
        let w = window ?? make(session)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private static func make(_ session: PhoneSession) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Volley"
        w.contentViewController = NSHostingController(rootView: MessagesView(session: session))
        w.contentMinSize = NSSize(width: 760, height: 480)
        w.isReleasedWhenClosed = false
        if !w.setFrameUsingName("VolleyMain") { w.center() }
        w.setFrameAutosaveName("VolleyMain")
        return w
    }
}
