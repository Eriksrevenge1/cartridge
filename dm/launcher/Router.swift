// Links into Cartridge (its Info.plist names the cartridge scheme, scripts/build_launcher.py):
//   cartridge://console[?game=<title ID>]  console mode: the shelf full screen, on that game: a tap of Home in a game opens it (dm/host/front_mac.m home_tap), the game going on behind it
//   cartridge://play?game=<title ID>       plays the game (or brings it forward), for a link anywhere. Cartridge stays behind it: brought forward, its
//                                          window covered the game's fullscreen space when both are on one screen
// The app delegate takes the links, so SwiftUI opens no new library window for them; the library view hands the router its openWindow.
import AppKit
import SwiftUI

final class Router: ObservableObject {
    static let shared = Router()
    /// The game the shelf should choose (title ID), set by a link; the shelf reads it when it changes
    @Published var focus: String?
    var openWindow: OpenWindowAction?
    /// Console mode is the shelf's own window full screen, not a window of its own (there were two homes, the shelf and a full-screen copy of it). ShellView
    /// names its window here and keeps consoleOpen as the window enters and leaves full screen
    weak var home: NSWindow?
    @Published var consoleOpen = false
    private var pendingConsole = false

    func handle(_ u: URL) {
        guard u.scheme?.lowercased() == "cartridge" else { return }
        let game = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "game" }?.value?.uppercased()
        switch u.host?.lowercased() {
        case "console": NSApp.activate(ignoringOtherApps: true); focus = game; showConsole()
        case "play": if let game { play(game) }
        default: NSLog("Cartridge: unknown link %@", u.absoluteString)
        }
    }
    /// A link can start Cartridge: the library may still be scanning, so the game is looked for again for a few seconds
    private func play(_ tid: String, tries: Int = 20) {
        if let g = Library.shared.games.first(where: { $0.titleID == tid }) { Library.shared.play(g); return }
        if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.play(tid, tries: tries - 1) } }
        else { NSLog("Cartridge: no game %@ in the library", tid) }
    }
    /// The shelf forward and full screen (⇧⌘K, the menu bar, a link). With no shelf window yet (Cartridge starting, or its window closed) it opens one, which
    /// goes full screen as it appears (homeAppeared)
    func showConsole() {
        NSApp.activate(ignoringOtherApps: true)
        guard let w = home, w.isVisible || w.isMiniaturized else { pendingConsole = true; openWindow?(id: "library"); return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        ConsoleWindow.fullScreen(w)
    }
    /// The shelf full screen leaves it (⇧⌘K again, Escape or B on the shelf's top)
    func leaveConsole() { if let w = home, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) } }
    func toggleConsole() { consoleOpen ? leaveConsole() : showConsole() }
    /// The shelf's window is known
    func homeAppeared(_ w: NSWindow) {
        home = w; consoleOpen = w.styleMask.contains(.fullScreen)
        if pendingConsole { pendingConsole = false; ConsoleWindow.fullScreen(w) }
    }
    /// The library's window appeared: it can open windows now
    func attach(_ o: OpenWindowAction) { openWindow = o }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) { DevSnapshot.start() }
    /// cartridge:// links are taken here, as the Apple Event, and not through application(_:open:): AppKit's own handler gave each link to SwiftUI's scenes first,
    /// which closed and reordered the shelf's window (dropping it out of full screen, console mode) or opened another window. Set before launching ends, so a
    /// link that starts Cartridge arrives here too
    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(getURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    @objc func getURL(_ e: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        if let s = e.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let u = URL(string: s) { Router.shared.handle(u) }
    }
}
