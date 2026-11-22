import AppKit
import SwiftUI

/// The one dashboard window. Every menu entry shows this window on some tab; closing it only
/// hides it, and the menu-bar item keeps running.
@MainActor
final class DashboardWindow: NSObject, NSWindowDelegate {
    private static var instance: DashboardWindow?

    static func shared(dbPath: String) -> DashboardWindow {
        if let i = instance { return i }
        let i = DashboardWindow(dbPath: dbPath)
        instance = i
        return i
    }

    let model: DashboardModel
    private let window: NSWindow

    private init(dbPath: String) {
        model = DashboardModel(dbPath: dbPath)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "pmon"
        window.contentViewController = NSHostingController(rootView: DashboardView(model: model))
        window.setContentSize(NSSize(width: 1180, height: 800))
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("pmon.dashboard")
        if !window.setFrameUsingName("pmon.dashboard") { window.center() }
    }

    /// Bring the window forward on `tab`, optionally with something selected in it.
    func show(_ tab: DashboardTab, episode: Int64? = nil, latestEpisode: Bool = false, finding: Int64? = nil) {
        if latestEpisode { model.showLatestEpisode() }
        else if let episode { model.showEpisode(episode) }
        else if let finding { model.showFinding(finding) }
        else { model.show(tab) }
        // An accessory app has no Dock icon; become a regular app while the window is open so it
        // can be switched to with Cmd-Tab, and go back when it closes.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !model.visible { model.appeared() } else { model.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        model.disappeared()
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidMiniaturize(_ notification: Notification) { model.disappeared() }
    func windowDidDeminiaturize(_ notification: Notification) { model.appeared() }
}
