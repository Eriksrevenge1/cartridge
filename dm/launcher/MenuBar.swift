// Cartridge in the menu bar: the games played last, to start one without the library's window, and console mode. Shown while Cartridge runs; Settings › Library turns it off.
import AppKit
import SwiftUI

struct MenuBarMenu: View {
    @EnvironmentObject var library: Library
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var covers = Covers.shared

    /// The games played most recently, newest first (five at most); a library nothing was played from yet shows its first games by name
    private var recent: [Game] {
        let played = library.games.filter { Stats.shared.of($0).last != nil }
            .sorted { (Stats.shared.of($0).last ?? .distantPast) > (Stats.shared.of($1).last ?? .distantPast) }
        return Array((played.isEmpty ? library.games : played).prefix(5))
    }

    var body: some View {
        let _ = covers.version
        Section(recent.isEmpty ? "No games in the library" : "Recently Played") {
            ForEach(recent) { item($0) }
        }
        if library.games.count > recent.count {
            Menu("All Games") { ForEach(library.games) { item($0) } }
        }
        Divider()
        Button("Console Mode") { Router.shared.showConsole() }
        Button("Open Library") { openLibrary() }
        Divider()
        Button("Quit Cartridge") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func item(_ g: Game) -> some View {
        Button { library.play(g) } label: {
            Label { Text(library.running.contains(g.id) ? "\(g.title) (playing)" : g.title) } icon: { Image(nsImage: thumb(g)) }
        }
    }
    /// The game's art at menu size
    private func thumb(_ g: Game) -> NSImage {
        let src = covers.image(g), s = NSSize(width: 18, height: 18)
        return NSImage(size: s, flipped: false) { r in
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).addClip()
            src.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
    /// The library's window to the front, or a new one when it was closed
    private func openLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("library") == true && $0.isVisible }) { w.makeKeyAndOrderFront(nil) }
        else { openWindow(id: "library") }
    }
}
