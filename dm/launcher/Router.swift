// Links into Cartridge (its Info.plist names the cartridge scheme, scripts/build_launcher.py):
//   cartridge://console[?game=<title ID>]  console mode, on that game: a tap of Home in a game opens it (dm/host/front_mac.m home_tap), the game going on behind it
//   cartridge://play?game=<title ID>       plays the game (or brings it forward), for a Shortcuts "Open URL" or a link anywhere. Cartridge stays behind it: brought forward, its
//                                          window covered the game's fullscreen space when both are on one screen
// The app delegate takes the links, so SwiftUI opens no new library window for them; the library view hands the router its openWindow.
import AppKit
import SwiftUI

final class Router: ObservableObject {
    static let shared = Router()
    /// The game console mode should show first (title ID), set by a link; console mode reads it as it opens and when it changes
    @Published var focus: String?
    var openWindow: OpenWindowAction?
    /// Console mode is open, and how it leaves (ConsoleView sets both): ⇧⌘K and the Exit button leave through it
    @Published var consoleOpen = false
    var leaveConsole: () -> Void = {}
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
    func showConsole() {
        if consoleOpen { NSApp.windows.first { $0.title == "Console Mode" }?.makeKeyAndOrderFront(nil); return }
        guard let openWindow else { pendingConsole = true; return }   // the app is still starting: once the library's window has appeared
        openWindow(id: "console")
    }
    /// The library's window appeared: it can open windows now
    func attach(_ o: OpenWindowAction) {
        openWindow = o
        if pendingConsole { pendingConsole = false; o(id: "console") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) { for u in urls { Router.shared.handle(u) } }
}
