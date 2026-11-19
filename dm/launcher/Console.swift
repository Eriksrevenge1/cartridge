// Console mode: the library full screen for the couch, driven by a controller or the keyboard. A row of game tiles over the chosen game's art, its name and play time,
// and the buttons' meanings at the bottom. Left and right (D-pad, stick, arrow keys) choose, A or Return plays, B or Escape leaves. It opens from the toolbar, View ›
// Console Mode (⇧⌘K) or a controller's Menu button in the library, and while it is open the controller drives it alone (GamepadNav routes to the front handlers). It leaves
// by B, Escape, ⇧⌘K again or its Exit button.
import AppKit
import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var pad: GamepadNav
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var router = Router.shared
    @State private var index = 0
    @State private var keys: Any?   // the key monitor: Escape leaves even when no view has the focus
    @FocusState private var focused: Bool

    /// The running games first (a tap of Home in one opens console mode on it), then the most recently played
    private var games: [Game] {
        library.games.sorted {
            let r0 = isRunning($0), r1 = isRunning($1)
            return r0 != r1 ? r0 : (Stats.shared.of($0).last ?? .distantPast) > (Stats.shared.of($1).last ?? .distantPast)
        }
    }
    /// Started here, or from Finder or the Dock
    private func isRunning(_ g: Game) -> Bool { library.running.contains(g.id) || !NSRunningApplication.runningApplications(withBundleIdentifier: g.bundleID).isEmpty }
    /// The game a link asked for (cartridge://console?game=…), once
    private func takeFocus() {
        guard let tid = router.focus else { return }
        router.focus = nil
        if let i = games.firstIndex(where: { $0.titleID == tid }) { index = i }
    }
    private var current: Game? { games.indices.contains(index) ? games[index] : nil }

    var body: some View {
        GeometryReader { geo in
            let tile = min(300, max(160, geo.size.height * 0.26))
            ZStack {
                Color.black
                if let g = current {
                    CoverArt(game: g).frame(width: geo.size.width, height: geo.size.height).clipped()
                        .blur(radius: 70).saturation(1.4).opacity(0.55).id(g.id).transition(.opacity)
                }
                LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 0) {
                    topBar.padding(.horizontal, 48).padding(.top, 32)
                    Spacer()
                    if games.isEmpty {
                        Text("No games in the library").font(.title).foregroundStyle(.white.opacity(0.7))
                    } else {
                        row(tile: tile)
                        info.padding(.top, 28).padding(.horizontal, 64)
                    }
                    Spacer()
                    hints.padding(.bottom, 36)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.22), value: index)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear {
            focused = true
            pad.push(GamepadNav.Route(move: { _ in }, moveX: move, page: { _ in }, play: play, back: leave, menu: leave))
            takeFocus()
            fullScreen()
            router.consoleOpen = true; router.leaveConsole = leave
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard e.window?.title == "Console Mode" else { return e }
                switch e.keyCode {
                case 53: leave(); return nil                 // Escape
                case 123: move(-1); return nil               // left
                case 124: move(1); return nil                // right
                case 36, 76: play(); return nil              // Return, Enter
                default: return e
                }
            }
        }
        .onChange(of: router.focus) { takeFocus(); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
        .onDisappear {
            pad.pop(); router.consoleOpen = false; router.leaveConsole = {}
            if let keys { NSEvent.removeMonitor(keys) }; keys = nil
        }
    }

    private var topBar: some View {
        HStack {
            Label("Cartridge", systemImage: "gamecontroller.fill").font(.title3.bold()).foregroundStyle(.white.opacity(0.85))
            Spacer()
            TimelineView(.periodic(from: .now, by: 15)) { t in
                Text(t.date, style: .time).font(.title3.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            }
            Button(action: leave) {
                Label("Exit", systemImage: "xmark").font(.title3.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 8)
                    .foregroundStyle(.white).background(.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain).padding(.leading, 20).help("Leave console mode (Esc, B on a controller, or ⇧⌘K)")
        }
    }

    private func row(tile: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 28) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { i, g in
                        let on = i == index
                        Color.clear.frame(width: tile, height: tile).overlay(CoverArt(game: g))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white, lineWidth: on ? 5 : 0))
                            .overlay(alignment: .topTrailing) {
                                if isRunning(g) {
                                    Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white, .green).padding(10)
                                }
                            }
                            .shadow(color: .black.opacity(on ? 0.6 : 0.3), radius: on ? 24 : 8, y: on ? 12 : 4)
                            .scaleEffect(on ? 1.12 : 0.92)
                            .opacity(on ? 1 : 0.75)
                            .id(g.id)
                            .onTapGesture(count: 2) { index = i; play() }
                            .onTapGesture { index = i }
                    }
                }
                .padding(.horizontal, 80).padding(.vertical, tile * 0.12)
            }
            .onChange(of: index) { if let g = current { withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(g.id, anchor: .center) } } }
            .onAppear { if let g = current { proxy.scrollTo(g.id, anchor: .center) } }
        }
    }

    private var info: some View {
        VStack(spacing: 10) {
            if let g = current {
                HStack(spacing: 12) {
                    Text(g.title).font(.system(size: 40, weight: .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
                    if g.isSwitch2 { Switch2Badge(size: 14) }
                }
                Text(isRunning(g) ? "Playing now" : Stats.describe(Stats.shared.of(g)) ?? "Not played yet")
                    .font(.title3).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var hints: some View {
        HStack(spacing: 36) {
            hint("a.circle.fill", current.map { isRunning($0) ? "Resume" : "Play" } ?? "Play")
            Button(action: leave) { hint("b.circle.fill", "Back (Esc)") }.buttonStyle(.plain)
            hint("arrow.left.and.right.circle.fill", "Choose")
        }
        .font(.title3).foregroundStyle(.white.opacity(0.85))
    }
    private func hint(_ symbol: String, _ text: String) -> some View { Label(text, systemImage: symbol) }

    private func move(_ d: Int) { guard !games.isEmpty else { return }; index = max(0, min(games.count - 1, index + d)) }
    private func play() { if let g = current { library.play(g) } }
    /// The console's window: SwiftUI names it after the scene's title
    private var window: NSWindow? { NSApp.windows.first { $0.title == "Console Mode" && $0.isVisible } }
    private func leave() {
        guard let w = window, w.styleMask.contains(.fullScreen) else { dismissWindow(id: "console"); return }
        w.toggleFullScreen(nil)   // out of full screen first, then closed once the space animation ends
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismissWindow(id: "console") }
    }
    /// Full screen once the window exists (it does not yet while the view first appears): a few tries, a tenth of a second apart
    private func fullScreen(_ tries: Int = 10) {
        guard let w = window else { if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { fullScreen(tries - 1) } }; return }
        w.backgroundColor = .black; w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.collectionBehavior.insert(.fullScreenPrimary)   // a hidden-title-bar scene's window is not marked able to go full screen
        w.styleMask.insert(.resizable)
        if w.styleMask.contains(.fullScreen) { return }
        w.makeKeyAndOrderFront(nil)
        w.toggleFullScreen(nil)
        // Should macOS still refuse (another app full screen on this display, say), the window covers the screen instead
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if !w.styleMask.contains(.fullScreen), let screen = w.screen ?? NSScreen.main { w.setFrame(screen.frame, display: true, animate: true) }
        }
    }
}
