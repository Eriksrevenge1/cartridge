// Cartridge's home: every game as a cartridge on a shelf, the chosen one's world behind it (its art or a scene from it, slowly moving), its label at the right with
// Play, and its music. Scrolling down (or down on a controller) raises the game's page over the art: its screenshots, what it is, how it runs here and, for a Switch
// game, its mods, cheats and Cartridge's pages for it. The rail at the left picks where the games come from. A controller, the keyboard and the mouse all drive it:
//   left / right  the shelf          up / down    the page            A / Return   play          B / Escape  back (the page down, console mode out)
//   Y / O          options           X / F        favourite           L / R / Tab  the rail      Menu / ⌘,   settings
import AppKit
import GameController
import SwiftUI

struct ShellView: View {
    var console = false   // the console-mode window: full screen, B leaves it
    @EnvironmentObject var library: Library
    @EnvironmentObject var pad: GamepadNav
    @EnvironmentObject var builder: Builder
    @ObservedObject private var titles = Titles.shared
    @ObservedObject private var details = DetailsStore.shared
    @ObservedObject private var music = MusicPlayer.shared
    @ObservedObject private var sessions = Sessions.shared
    @ObservedObject private var covers = Covers.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("shell.filter") private var filter = "All"
    @AppStorage("shell.selected") private var selected = ""
    @AppStorage("look.moving") private var moving = true
    @State private var scrollY: CGFloat = 0
    @State private var options: Title?
    @State private var cartridgePages: Title?
    @State private var keys: Any?
    @State private var window: NSWindow?
    /// Cartridge is the app in front: the wallpaper moves only then (60 steps a second cost the window server about a fifth of a core on an M-series Mac)
    @State private var active = true   // its window can be seen

    // MARK: what is on the shelf

    /// The rail's choices: All, each source that has games here, Favorites, Not played yet
    private var filters: [(String, String)] {
        var out = [("All", "square.grid.2x2.fill")]
        // a store's tab for its games, and a bottle's tab (CrossOver, Whisky) for every game in one, whichever launcher installed it
        let kinds = Set(titles.all.map(kind)).union(titles.all.compactMap { t in t.external?.runtime.flatMap { $0 == .crossover || $0 == .whisky ? $0.rawValue : nil } })
        for (k, sym) in [("Switch", "gamecontroller.fill"), ("Steam", "cloud.fill"), ("Battle.net", "bolt.fill"), ("Epic Games", "e.square.fill"), ("GOG", "g.square.fill"),
                         ("itch.io", "i.square.fill"), ("Ubisoft Connect", "u.square.fill"), ("Amazon Games", "a.square.fill"), ("Heroic", "h.square.fill"),
                         ("CrossOver", "wineglass.fill"), ("Whisky", "wineglass"), ("App Store", "bag.fill"), ("Mac", "macwindow")] where kinds.contains(k) { out.append((k, sym)) }
        out.append(("Favorites", "heart.fill")); out.append(("Not played yet", "sparkles"))
        return out
    }
    private func kind(_ t: Title) -> String {
        if t.game != nil { return "Switch" }
        guard let e = t.external else { return "" }
        if e.store == .crossover || e.store == .whisky { return e.store.rawValue }
        return e.store.rawValue
    }
    /// The shelf: the games the rail picks, the played ones first (most recent first), then the rest by name
    @State private var shelf: [Title] = []
    private func makeShelf() -> [Title] {
        let list = titles.all.filter { !titles.hidden.contains($0.id) }.filter { t in
            switch filter {
            case "All": return true
            case "Favorites": return titles.favorites.contains(t.id)
            case "Not played yet": return t.stats.last == nil
            default: return kind(t) == filter || (filter == "CrossOver" && t.external?.runtime == .crossover) || (filter == "Whisky" && t.external?.runtime == .whisky)
            }
        }
        return list.sorted { a, b in
            let la = a.stats.last ?? .distantPast, lb = b.stats.last ?? .distantPast
            return la != lb ? la > lb : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    private var current: Title? { shelf.first { $0.id == selected } ?? shelf.first }
    private var index: Int { current.flatMap { c in shelf.firstIndex { $0.id == c.id } } ?? 0 }
    private var sheet: Double { min(1, max(0, Double(scrollY) / 500)) }

    // MARK: the screen

    var body: some View {
        let _ = details.version, _ = covers.version
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Wallpaper(title: current, moving: moving && active && !reduceMotion && library.running.isEmpty && titles.runningExternal.isEmpty, dim: sheet)
                    .frame(width: geo.size.width, height: geo.size.height)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            home(geo.size).frame(width: geo.size.width, height: geo.size.height).id("home")
                            if let t = current { GamePage(title: t, play: { play(t) }, options: { showOptions(t) }, pages: { cartridgePages = t }).id("page") }
                        }
                        .frame(width: geo.size.width)
                    }
                    .scrollIndicators(.hidden)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in scrollY = y }
                    .onChange(of: pageRequest) { if let r = pageRequest { withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(r, anchor: .top) }; pageRequest = nil } }
                }
                rail.opacity(1 - sheet).padding(.leading, 28).frame(maxHeight: .infinity)
                topLine.opacity(1 - sheet)
                cards.frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                hints.frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
            }
            .frame(width: geo.size.width, height: geo.size.height).clipped()
        }
        .background(Color.black)
        .background(WindowFinder { w in
            guard window !== w else { return }
            window = w
            if let w { active = w.occlusionState.contains(.visible) }
            if console, let w { ConsoleWindow.fullScreen(w) }
        })
        .ignoresSafeArea()
        .sheet(item: $options) { t in OptionsPanel(title: t, close: { options = nil }, pages: { options = nil; cartridgePages = t },
                                                       rebuild: { all in
                                                           options = nil
                                                           // after the sheet is gone: a rebuild with no source asks for one in an open panel
                                                           DispatchQueue.main.async {
                                                               if all { rebuildAll(library.games, library: library, builder: builder) { openWindow(id: "build") } }
                                                               else if let g = t.game { rebuildGame(g, builder: builder) { openWindow(id: "build") } }
                                                           }
                                                       }) }
        .sheet(item: $cartridgePages) { t in
            if let g = t.game {
                CartridgePages(game: g, close: { cartridgePages = nil }).environmentObject(library).environmentObject(builder).frame(minWidth: 900, minHeight: 680)
            }
        }
        .onAppear { shelf = makeShelf(); attach(); choose(current, sound: false); for t in titles.all { details.ensure(t) } }
        .onDisappear { detach() }
        .onReceive(Timer.publish(every: 180, on: .main, in: .common).autoconnect()) { _ in if active, sheet < 0.5, let t = current { details.nextWall(t) } }
        // the wallpaper moves while its window can be seen, in front or not (Cartridge on one screen while another app is used): only a covered or minimised
        // window stops it, which is when its drawing would be wasted
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { n in
            if let w = n.object as? NSWindow, w === window { active = w.occlusionState.contains(.visible) }
        }
        .onChange(of: filter) { shelf = makeShelf(); if !shelf.contains(where: { $0.id == selected }) { choose(shelf.first) } }
        .onChange(of: titles.all.map(\.id)) { shelf = makeShelf(); if current?.id != selected { choose(current, sound: false) }; for t in titles.all { details.ensure(t) } }
        .onChange(of: titles.favorites) { if filter == "Favorites" { shelf = makeShelf() } }
        .onChange(of: titles.hidden) { shelf = makeShelf() }
        .onChange(of: library.running) { shelf = makeShelf() }
    }
    @State private var pageRequest: String?

    private func home(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let t = current { LabelPanel(title: t, track: music.now, play: { play(t) }, options: { showOptions(t) }, more: { pageRequest = "page" })
                    .padding(.top, 130).frame(width: size.width - 56, height: size.height, alignment: .topTrailing).frame(width: size.width, alignment: .leading)
                    .opacity(1 - sheet).id(t.id).transition(.opacity) }
            Shelf(titles: shelf, selected: current?.id, choose: { choose($0) }, play: { play($0) }, add: { openWindow(id: "build") })
                .padding(.bottom, 70).frame(width: size.width, height: size.height, alignment: .bottom)
                .opacity(1 - sheet)
            if shelf.isEmpty {
                VStack(spacing: 12) {
                    Text(titles.all.isEmpty ? "No games yet" : "Nothing here").font(.custom("Avenir Next", size: 40).weight(.heavy))
                    Text(titles.all.isEmpty ? "Build a Switch game, or install one with Steam, Battle.net, Epic, GOG or CrossOver." : "Choose another source on the left.").font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                }.foregroundStyle(.white).frame(width: size.width, height: size.height)
            }
        }
    }

    private var topLine: some View {
        HStack(alignment: .center) {
            TimelineView(.periodic(from: .now, by: 15)) { tl in
                HStack(spacing: 12) {
                    Text(tl.date, format: .dateTime.hour().minute()).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 14)
                    Text(tl.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    if let c = GCController.current {
                        Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 14)
                        Image(systemName: "gamecontroller.fill").font(.system(size: 13))
                        if let b = c.battery { Text("\(Int(b.batteryLevel * 100))%").font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.7)) }
                    }
                }
                .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            }
            Spacer()
            HStack(spacing: 16) {
                if console { Button { leave() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Leave console mode (Esc, or B)") }
                else { Button { openSettings() } label: { Image(systemName: "gearshape.fill") }.buttonStyle(.plain).help("Settings (⌘,)") }
                Wordmark(size: 13)
            }.font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.leading, 110).padding(.trailing, 48).padding(.top, console ? 28 : 40)
    }

    private var rail: some View {
        VStack(spacing: 10) {
            ForEach(filters, id: \.0) { f in
                let on = f.0 == filter
                Button { filter = f.0; UISound.move.play() } label: {
                    Image(systemName: f.1).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(on ? 1 : 0.7)).frame(width: 46, height: 46)
                        .background(Circle().fill(on ? AnyShapeStyle(LinearGradient(colors: [Brand.cyan, Brand.red], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(.white.opacity(0.06))))
                }
                .buttonStyle(.plain).help(f.0)
                .overlay(alignment: .leading) {
                    if on { Text(f.0.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(2).foregroundStyle(.white).fixedSize().offset(x: 58).allowsHitTesting(false) }
                }
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 8)
        .background(Capsule().fill(.black.opacity(0.35))).overlay(Capsule().strokeBorder(.white.opacity(0.1)))
    }

    /// A session that just ended, and the build that runs, at the top left under the clock
    private var cards: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = sessions.last {
                Card {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.quick == nil ? "SESSION ENDED" : "CLOSED RIGHT AFTER STARTING").font(.system(size: 11, weight: .heavy)).tracking(2)
                                .foregroundStyle(s.quick == nil ? .white.opacity(0.55) : Color.orange)
                            Text(s.title).font(.system(size: 18, weight: .bold))
                            if let r = s.quick {
                                Text("It most likely doesn't run in \(r).").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                            } else {
                                Text("\(Stats.duration(s.seconds)) this session · \(Stats.duration(s.total)) in total").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                }
                .task(id: s.id) { try? await Task.sleep(for: .seconds(s.quick == nil ? 6 : 10)); withAnimation { if sessions.last?.id == s.id { sessions.last = nil } } }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if let j = builder.jobs.first(where: { $0.state == .running }) { BuildCard(job: j).onTapGesture { openWindow(id: "build") } }
        }
        .padding(.top, 96).padding(.leading, 110)
        .opacity(1 - sheet)
    }

    private var hints: some View {
        let pad = GCController.current?.extendedGamepad
        // over the page, the hints sit on a dark band so the page's content does not run under them
        func sym(_ b: GCControllerButtonInput?, _ fallback: String) -> String { b?.sfSymbolsName ?? fallback }
        return HStack(spacing: 26) {
            Hint(sym: sym(pad?.buttonY, "y.circle.fill"), key: "O", text: "Options")
            Hint(sym: sym(pad?.buttonX, "x.circle.fill"), key: "F", text: current.map { titles.favorites.contains($0.id) } == true ? "Unfavorite" : "Favorite")
            Hint(sym: "arrow.down.circle.fill", key: "↓", text: sheet > 0.5 ? "More" : "Game page")
            Hint(sym: sym(pad?.buttonA, "a.circle.fill"), key: "↩", text: current.map { titles.isRunning($0) } == true ? "Resume" : "Play")
        }
        .padding(.trailing, 56).padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 40)
        .background(LinearGradient(colors: [.clear, Brand.ink.opacity(0.95 * sheet)], startPoint: .top, endPoint: .center))
        .opacity(0.9)
    }

    // MARK: acting

    private func choose(_ t: Title?, sound: Bool = true) {
        guard let t else { MusicPlayer.shared.stop(); return }
        if t.id != selected, sound { UISound.move.play() }
        selected = t.id
        details.ensure(t)
        let id = t.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if selected == id, scrollY < 200 || true { MusicPlayer.shared.play(t) } }
        for n in shelf.drop(while: { $0.id != id }).prefix(3) { details.ensure(n) }   // the next ones ready before they are chosen
    }
    private func move(_ d: Int) {
        let s = shelf
        guard !s.isEmpty else { return }
        choose(s[max(0, min(s.count - 1, index + d))])
    }
    private func play(_ t: Title, _ source: String = "click") { UISound.select.play(); MusicPlayer.shared.pause(); titles.play(t, from: source) }
    private func showOptions(_ t: Title) { UISound.select.play(); options = t }
    private func favorite() { if let t = current { titles.toggleFavorite(t); UISound.select.play() } }
    private func nextFilter(_ d: Int) {
        let f = filters.map(\.0), i = f.firstIndex(of: filter) ?? 0
        filter = f[(i + d + f.count) % f.count]; UISound.move.play()
    }
    private func back() {
        if sheet > 0.05 { pageRequest = "home"; UISound.back.play() } else if console { leave() }
    }
    private func leave() {
        UISound.back.play()
        guard let w = window, w.styleMask.contains(.fullScreen) else { dismissWindow(id: "console"); return }
        w.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismissWindow(id: "console") }
    }

    private func attach() {
        let route = GamepadNav.Route(
            move: { d in d > 0 ? (pageRequest = "page") : back() },
            moveX: { d in if sheet < 0.5 { move(d) } },
            page: nextFilter,
            play: { if let t = current { play(t, "controller A") } },
            back: back,
            menu: { openSettings() },
            home: { if let t = shelf.first(where: { titles.isRunning($0) }) { titles.play(t) } },
            option: { if let t = current { showOptions(t) } },
            fav: favorite)
        if console { pad.push(route); Router.shared.consoleOpen = true; Router.shared.leaveConsole = leave } else { pad.setBase(route) }
        Router.shared.attach(openWindow)
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.window === window, e.window?.attachedSheet == nil, !(e.window?.firstResponder is NSTextView) else { return e }
            switch e.keyCode {
            case 123: if sheet < 0.5 { move(-1); return nil }
            case 124: if sheet < 0.5 { move(1); return nil }
            case 125: if sheet < 0.05 { pageRequest = "page"; return nil }
            case 126: if sheet > 0.05 && scrollY < 900 { back(); return nil }
            case 36, 76: if !e.isARepeat, let t = current { play(t, "Return key"); return nil }
            case 53: back(); return nil
            case 48: nextFilter(e.modifierFlags.contains(.shift) ? -1 : 1); return nil
            default:
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "f" where e.modifierFlags.intersection([.command, .option, .control]).isEmpty: favorite(); return nil
                case "o" where e.modifierFlags.intersection([.command, .option, .control]).isEmpty: if let t = current { showOptions(t) }; return nil
                default: break
                }
            }
            return e
        }
    }
    private func detach() {
        if console { pad.pop(); Router.shared.consoleOpen = false; Router.shared.leaveConsole = {} }
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }
}

// MARK: pieces

/// The chosen game's art across the window, drifting slowly, darker as the page rises. Core Animation draws and moves it (WallLayer): SwiftUI does nothing per
/// frame, so the drift runs at the screen's rate and costs next to nothing
struct Wallpaper: View {
    let title: Title?
    let moving: Bool
    let dim: Double
    @ObservedObject private var details = DetailsStore.shared
    var body: some View {
        let _ = details.version
        ZStack {
            Color.black
            WallLayer(image: title.flatMap { details.wallCG($0) }, game: title?.id ?? "", key: title.flatMap { details.wallName($0) } ?? "", moving: moving)
            if let t = title, details.wallCG(t) == nil { NoArtBackdrop(title: t) }
            LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.16), .init(color: .clear, location: 0.55),
                                   .init(color: .black.opacity(0.8), location: 1)], startPoint: .top, endPoint: .bottom)
            Color.black.opacity(0.6 * dim)
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// A layer showing the art, filling the view, drifting slowly (a pan back and forth over 80 s); a new picture cross-fades in. The drift is stepped by a display
/// link at 60 frames a second (20 showed its steps), only while its window can be seen, not left to an endless Core Animation animation: macOS composites the window at the screen's full rate for as long as such an
/// animation runs (120 Hz here: a third of the window server's time for a picture that moves a point a second)
struct WallLayer: NSViewRepresentable {
    let image: CGImage?
    let game: String
    let key: String
    let moving: Bool
    final class View: NSView {
        let art = CALayer()
        var key = ""
        var game = ""
        private var link: CADisplayLink?
        private var t0 = CACurrentMediaTime()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            art.contentsGravity = .resizeAspectFill
            art.minificationFilter = .trilinear
            art.actions = ["transform": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(art)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            art.frame = bounds.insetBy(dx: -30, dy: -12)   // room for the drift
            CATransaction.commit()
        }
        func drift(_ on: Bool) {
            if on, link == nil {
                let l = displayLink(target: self, selector: #selector(step))
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 48, maximum: 60, preferred: 60)
                l.add(to: .main, forMode: .common)
                link = l
            } else if !on, let l = link { l.invalidate(); link = nil }
        }
        @objc private func step(_ l: CADisplayLink) {
            let p = sin((CACurrentMediaTime() - t0) * .pi / 40)   // -1 … 1, a full swing in 80 s
            CATransaction.begin(); CATransaction.setDisableActions(true)
            art.transform = CATransform3DMakeTranslation(CGFloat(24 * p), CGFloat(-8 * p), 0)
            CATransaction.commit()
        }
        override func viewDidMoveToWindow() { if window == nil { drift(false) } }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ v: View, context: Context) {
        if v.key != key || v.game != game {
            let fade = CATransition(); fade.type = .fade; fade.duration = v.game == game ? 2.5 : 0.6   // the game's next wallpaper slowly, another game's quickly
            v.art.add(fade, forKey: "fade")
            v.art.contents = image
            v.key = image == nil ? "" : key; v.game = game
        } else if v.art.contents == nil, let image { v.art.contents = image }
        v.drift(moving)
    }
}

/// A game's cover: a Switch game's (Covers.swift), else the details' cover or the app's icon
struct CoverImage: View {
    let title: Title
    @ObservedObject private var details = DetailsStore.shared
    var body: some View {
        let _ = details.version
        if let g = title.game { CoverArt(game: g) }
        else if let i = details.image(title, details.details(title)?.cover) {
            let aspect = i.size.width / max(i.size.height, 1)
            if abs(aspect - 1) < 0.12 { Image(nsImage: i).resizable().interpolation(.high).aspectRatio(contentMode: .fill) }
            else {
                // a tall box or a wide banner: all of it, over a soft copy of itself filling the square, so its name is not cut off
                // (the soft copy is an overlay of a clear square, so a tall picture filling it does not make the square tall)
                Color.clear
                    .overlay(Image(nsImage: i).resizable().aspectRatio(contentMode: .fill).blur(radius: 18).saturation(1.2).opacity(0.8))
                    .overlay(Image(nsImage: i).resizable().interpolation(.high).aspectRatio(contentMode: .fit).shadow(color: .black.opacity(0.5), radius: 6))
                    .clipped()
            }
        }
        else if let app = title.app { Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().aspectRatio(contentMode: .fit).padding(12) }
        else { ZStack { Brand.lift; Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.6)) } }
    }
}

/// A game as a cartridge: a dark shell with a stepped, ribbed top and its cover as the label
struct CartridgeShape: View {
    let title: Title?
    var width: CGFloat = 118
    var lit = 0.0
    var body: some View {
        let w = width, h = w * 1.18
        let shell = UnevenRoundedRectangle(topLeadingRadius: w * 0.07, bottomLeadingRadius: w * 0.1, bottomTrailingRadius: w * 0.1, topTrailingRadius: w * 0.07, style: .continuous)
        ZStack(alignment: .top) {
            shell.fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: w * 0.04, style: .continuous).fill(Color(white: 0.28)).frame(width: w * 0.84, height: h * 0.16).offset(y: -h * 0.035)
            VStack(spacing: h * 0.022) { ForEach(0..<4, id: \.self) { _ in Capsule().fill(.black.opacity(0.35)).frame(width: w * 0.7, height: h * 0.012) } }.offset(y: h * 0.012)
            Group {
                if let title { CoverImage(title: title) }
                else { ZStack { Color(white: 0.16); Image(systemName: "plus").font(.system(size: w * 0.3, weight: .light)).foregroundStyle(.white.opacity(0.8)) } }
            }
            .frame(width: w * 0.84, height: w * 0.84).clipShape(RoundedRectangle(cornerRadius: w * 0.05, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: w * 0.05, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .offset(y: h * 0.2)
        }
        .frame(width: w, height: h)
        .overlay(shell.strokeBorder(LinearGradient(colors: [Brand.cyan, Brand.red], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3).opacity(lit))
        // a blurred shadow costs the window server a pass every frame the wallpaper moves under it: only the chosen cartridge glows, the others sit on a solid edge
        .background(alignment: .bottom) { shell.fill(.black.opacity(0.55)).frame(width: w, height: h).offset(y: 5) }
        .shadow(color: Brand.cyan.opacity(0.5 * lit), radius: lit > 0 ? 26 : 0, y: 6)
    }
}

struct Shelf: View {
    let titles: [Title]
    let selected: String?
    let choose: (Title) -> Void
    let play: (Title) -> Void
    let add: () -> Void
    @ObservedObject private var all = Titles.shared
    var body: some View {
        GeometryReader { geo in ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 24) {
                    item(nil)
                    ForEach(titles) { t in item(t).id(t.id) }
                }
                // room after the last cartridge to bring it to the middle too, so its name never sits under the label's music line at the right
                .padding(.leading, 140).padding(.trailing, max(140, geo.size.width / 2 - 72)).padding(.top, 60).padding(.bottom, 12)
                .background(alignment: .bottom) {
                    // the ledge the cartridges stand on, lit in the brand's two colours
                    Capsule().fill(LinearGradient(colors: [Brand.cyan.opacity(0), Brand.cyan.opacity(0.7), Brand.red.opacity(0.7), Brand.red.opacity(0)], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 2).shadow(color: Brand.cyan.opacity(0.6), radius: 14).padding(.horizontal, 60)
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: selected) { if let s = selected { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(s, anchor: .center) } } }
            .onAppear { if let s = selected { proxy.scrollTo(s, anchor: .center) } }
        } }
        .frame(height: 260)
    }
    private func item(_ t: Title?) -> some View {
        let on = t?.id == selected && t != nil
        return CartridgeShape(title: t, width: on ? 144 : 118, lit: on ? 1 : 0)
            .overlay(alignment: .top) {   // the name above the chosen one, taking no room on the shelf
                if on { Text(t?.name ?? "").font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1).fixedSize().offset(y: -28).shadow(color: .black.opacity(0.6), radius: 6) }
            }
                .overlay(alignment: .topTrailing) {
                    if let t, all.isRunning(t) { Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white, .green).offset(x: 6, y: -6) }
                    else if t?.game?.isSwitch2 == true { Text("2").font(.system(size: 12, weight: .black)).foregroundStyle(.white).frame(width: 20, height: 20).background(Circle().fill(Brand.red)).offset(x: 6, y: -6) }
                }
        .offset(y: on ? -30 : 0)
        .animation(.spring(duration: 0.35, bounce: 0.25), value: on)
        .contentShape(Rectangle())
        .onTapGesture { if let t { choose(t) } else { add() } }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if let t { play(t) } })   // Shelf's own play: a double-click
        .help(t?.name ?? "Build a Switch game")
        .accessibilityElement(children: .ignore).accessibilityLabel(t?.name ?? "Add a game").accessibilityAddTraits(.isButton)
    }
}

/// The chosen game's label: its logo or name, where it comes from, a line about it, its numbers, Play, and its music
struct LabelPanel: View {
    let title: Title
    let track: Track?
    let play: () -> Void
    let options: () -> Void
    let more: () -> Void
    @ObservedObject private var details = DetailsStore.shared
    @ObservedObject private var titles = Titles.shared
    var body: some View {
        let d = details.details(title), s = title.stats
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(title.game != nil ? Brand.red : Brand.cyan).frame(width: 8, height: 8)
                HStack(spacing: 8) {
                    Text(title.platform.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(2).foregroundStyle(.white.opacity(0.8))
                    // a bottle game's Wine rating (ProtonDB), so a game that will not run there says so before Play
                    if let c = DetailsStore.shared.details(title)?.compat {
                        Text(c == "borked" ? "WON'T RUN IN WINE" : c.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(1.5)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(["platinum": Color(white: 0.75), "gold": .yellow, "silver": .gray, "bronze": .orange][c] ?? .red).opacity(0.85))
                            .foregroundStyle(.black)
                    }
                }
            }
            if let logo = details.logo(title) {
                Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(maxWidth: 400, maxHeight: 160).frame(width: 400, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 14)
            } else {
                Text(title.name).font(.custom("Avenir Next", size: 34).weight(.heavy)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6).frame(width: 400, alignment: .leading)
            }
            if let about = d?.about { Text(Self.firstSentence(about)).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(3).frame(width: 400, alignment: .leading) }
            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 12) {
                GridRow { stat("PLAYED", s.seconds > 0 ? Stats.duration(s.seconds) : "Not yet"); stat("LAST", s.last.map { $0.formatted(.relative(presentation: .named)) } ?? "—") }
                GridRow { stat(title.game != nil ? "VERSION" : "FROM", title.game?.version ?? title.external?.store.rawValue ?? ""); stat("RELEASED", d?.released.map(Self.year) ?? "—") }
            }
            Button(action: play) {
                HStack(spacing: 14) {
                    Image(systemName: "play.fill").font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(titles.isRunning(title) ? "Resume" : "Play").font(.system(size: 20, weight: .bold))
                        Text(next).font(.system(size: 12, weight: .medium)).opacity(0.6)
                    }
                    Spacer()
                }
                .foregroundStyle(.black).padding(.horizontal, 22).frame(width: 400, height: 60)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
            }
            .buttonStyle(.plain).keyboardShortcut(.return, modifiers: [.command])
            HStack(spacing: 10) {
                if titles.isRunning(title) { round("stop.fill", "Stop") { UISound.back.play(); titles.stop(title) } }
                round("slider.horizontal.3", "Options", options)
                round(titles.favorites.contains(title.id) ? "heart.fill" : "heart", "Favorite") { titles.toggleFavorite(title) }
                round("arrow.down", "Game page", more)
                if let f = title.folder { round("folder", "Show", { NSWorkspace.shared.activateFileViewerSelecting([title.app ?? f]) }) }
            }
            if let track { player(track) }
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.black.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
    }
    /// What Play does
    private var next: String {
        guard let e = title.external else { return title.game.map { Library.shared.isFirstStart($0) ? "First start since its build" : "Plays here" } ?? "" }
        if let r = e.runtime, r == .crossover || r == .whisky { return "Opens in \(r.rawValue)\(e.bottle.map { " · \($0)" } ?? "")" }
        switch e.launch { case .app: return "Opens the app"; default: return "Opens through \(e.store == .heroic ? "Heroic" : e.runtime == .heroic ? "Heroic" : e.store.rawValue)" }
    }
    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k).font(.system(size: 10, weight: .heavy)).tracking(2).foregroundStyle(.white.opacity(0.5))
            Text(v).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
        }
    }
    private func round(_ sym: String, _ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: sym).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).frame(width: 46, height: 46).background(Circle().fill(.white.opacity(0.12)))
                Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }.frame(width: 92)
        }.buttonStyle(.plain)
    }
    private func player(_ t: Track) -> some View {
        HStack(spacing: 12) {
            EqualizerBars().frame(width: 76, height: 24)
            Text(t.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14).frame(width: 400, height: 50)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
    }
    static func firstSentence(_ s: String) -> String {
        guard let r = s.range(of: #"[.!?](\s|$)"#, options: .regularExpression), s.distance(from: s.startIndex, to: r.lowerBound) > 30 else { return s }
        return String(s[...r.lowerBound])
    }
    static func year(_ s: String) -> String { s.range(of: #"\d{4}"#, options: .regularExpression).map { String(s[$0]) } ?? s }
}

struct Card<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        content.foregroundStyle(.white).padding(16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.14)))
    }
}

struct BuildCard: View {
    @ObservedObject var job: BuildJob
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Building \(job.title)").font(.system(size: 16, weight: .bold)).lineLimit(1)
                    Spacer()
                    if let o = job.overall { Text("\(Int(o * 100))%").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.7)) }
                }
                ProgressView(value: job.overall ?? 0).tint(Brand.cyan)
                Text(job.eta.map { "About \(Stats.duration($0)) left · \(job.stage)" } ?? job.stage).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }.frame(width: 380)
        }
    }
}

struct Hint: View {
    let sym: String
    var key: String = ""
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            if GCController.current != nil { Image(systemName: sym).font(.system(size: 18, weight: .semibold)) }
            else if !key.isEmpty { Text(key).font(.system(size: 12, weight: .bold, design: .rounded)).padding(.horizontal, 6).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.6))) }
            Text(text).font(.system(size: 14, weight: .medium))
        }.foregroundStyle(.white.opacity(0.85))
    }
}

/// The window a view is in
struct WindowFinder: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { found(v.window) }; return v }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { found(v.window) } }
}

extension Stats {
    static func duration(_ s: Double) -> String {
        let h = Int(s / 3600), m = Int(s / 60) % 60
        return h > 0 ? "\(h) h \(m) m" : m > 0 ? "\(m) m" : "under a minute"
    }
}

// MARK: options

/// A game's options: what Cartridge can do for it, by controller or pointer
struct OptionsPanel: View {
    let title: Title
    let close: () -> Void
    let pages: () -> Void
    let rebuild: (_ all: Bool) -> Void   // this Switch game, or every one (after a Cartridge update whose engine is newer)
    @State private var choosing = false
    @ObservedObject private var titles = Titles.shared
    @ObservedObject private var details = DetailsStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.name).font(.custom("Avenir Next", size: 26).weight(.heavy))
            Text(title.platform).foregroundStyle(.secondary).padding(.bottom, 8)
            if title.hasCartridgePages { row("slider.horizontal.3", "Settings, mods, cheats, controls and saves", pages) }
            if let g = title.game, !Library.shared.running.contains(g.id) {
                row("hammer", "Rebuild") { rebuild(false) }
                row("hammer.circle", "Rebuild All Switch Games") { rebuild(true) }
            }
            row(titles.favorites.contains(title.id) ? "heart.slash" : "heart", titles.favorites.contains(title.id) ? "Remove from Favorites" : "Add to Favorites") { titles.toggleFavorite(title); close() }
            if let f = title.app ?? title.folder { row("folder", "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]); close() } }
            if let s = details.details(title)?.storePage, let u = URL(string: s) { row("bag", "Store page") { NSWorkspace.shared.open(u); close() } }
            row("photo.on.rectangle", "Choose Wallpaper…") { choosing = true }
            row("eye.slash", "Hide from the shelf") { titles.toggleHidden(title); close() }
            HStack { Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction) }.padding(.top, 8)
        }
        .padding(26).frame(width: 460)
        .sheet(isPresented: $choosing) { WallpaperPicker(title: title, close: { choosing = false; close() }) }
    }
    private func row(_ sym: String, _ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: { UISound.select.play(); action() }) {
            Label(text, systemImage: sym).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.06)))
        }.buttonStyle(.plain)
    }
}

/// A Switch game's own pages (GameView's: settings, mods, cheats, controls, saves, screenshots), over the home
struct CartridgePages: View {
    let game: Game
    let close: () -> Void
    @State private var page: Page = .settings
    var body: some View {
        VStack(spacing: 0) {
            GameView(game: game, page: $page)
            Divider()
            HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.cancelAction).controlSize(.large) }.padding(12)
        }
    }
}

enum ConsoleWindow {
    /// Console mode's window, full screen once it exists; should macOS refuse (another app full screen on this display), it covers the screen instead
    static func fullScreen(_ w: NSWindow) {
        w.backgroundColor = .black; w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.collectionBehavior.insert(.fullScreenPrimary); w.styleMask.insert(.resizable)
        guard !w.styleMask.contains(.fullScreen) else { return }
        w.makeKeyAndOrderFront(nil); w.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if !w.styleMask.contains(.fullScreen), let s = w.screen ?? NSScreen.main { w.setFrame(s.frame, display: true, animate: true) } }
    }
}

/// For checking the interface without screen recording: with CARTRIDGE_SNAPSHOT=<folder> in its environment, Cartridge writes its key window to
/// <folder>/window-<n>.png every two seconds (and nothing otherwise)
enum DevSnapshot {
    private static var n = 0
    static func note(_ s: String) { if ProcessInfo.processInfo.environment["CARTRIDGE_SNAPSHOT"] != nil { NSLog("Cartridge layout: %@", s) } }
    static func start() {
        guard let dir = ProcessInfo.processInfo.environment["CARTRIDGE_SNAPSHOT"], !dir.isEmpty else { return }
        // CARTRIDGE_FRAME="x y w h" (Cocoa screen coordinates): where the window goes, for a test run on a chosen screen
        if let f = ProcessInfo.processInfo.environment["CARTRIDGE_FRAME"]?.split(separator: " ").compactMap({ Double($0) }), f.count == 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.windows.first(where: \.isVisible)?.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[3]), display: true) }
        }
        // one picture per request: `xcrun swift -e` posting org.nxnative.cartridge.snapshot, or any tool that posts it
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("org.nxnative.cartridge.snapshot"), object: nil, queue: .main) { _ in
            n += 1
            for (i, w) in NSApp.windows.filter({ $0.isVisible && $0.contentView != nil }).enumerated() {
                guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                let name = w.title.isEmpty ? "window\(i)" : w.title.replacingOccurrences(of: "/", with: "-")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%03d-%@.png", n, name)))
            }
        }
    }
}

/// The music player's bars: twelve layers whose heights a display link steps at 20 frames a second (see WallLayer for why not an endless animation)
struct EqualizerBars: NSViewRepresentable {
    final class View: NSView {
        private var bars: [CALayer] = []
        private var link: CADisplayLink?
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for i in 0..<12 {
                let bar = CALayer()
                bar.backgroundColor = NSColor(Brand.cyan).blended(withFraction: Double(i) / 11, of: NSColor(Brand.red))?.cgColor
                bar.cornerRadius = 1.5
                bar.actions = ["bounds": NSNull(), "position": NSNull()]
                layer?.addSublayer(bar); bars.append(bar)
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            link?.invalidate(); link = nil
            guard window != nil else { return }
            let l = displayLink(target: self, selector: #selector(step))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 20, preferred: 20)
            l.add(to: .main, forMode: .common); link = l
        }
        @objc private func step(_ l: CADisplayLink) {
            let t = CACurrentMediaTime(), h = bounds.height
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (i, b) in bars.enumerated() {
                let v = 4 + (h - 4) * abs(sin(t * (2.6 + Double(i % 5) * 0.7) + Double(i) * 0.8))
                b.frame = CGRect(x: CGFloat(i) * 6.5, y: (h - v) / 2, width: 3, height: v)
            }
            CATransaction.commit()
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ v: View, context: Context) {}
}

/// Choose Wallpaper…: every picture the game has (the store's, and for a Switch game the screenshots you took), or one from a file; Automatic goes back to Cartridge's pick
struct WallpaperPicker: View {
    let title: Title
    let close: () -> Void
    @ObservedObject private var details = DetailsStore.shared
    var body: some View {
        let options = details.wallCandidates(title) + (title.game?.screenshots().prefix(12) ?? [])
        let current = details.wallName(title)
        VStack(alignment: .leading, spacing: 14) {
            Text("Wallpaper for \(title.name)").font(.title2.bold())
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(options, id: \.self) { u in
                        AsyncThumb(url: u).frame(height: 135).clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(u.lastPathComponent == current ? Brand.cyan : .clear, lineWidth: 3))
                            .contentShape(Rectangle())
                            .onTapGesture { details.choose(title, wallpaper: u); UISound.select.play() }
                    }
                }
            }
            HStack {
                Button("Choose File…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.message = "Choose a picture for \(title.name)'s wallpaper (wide and large looks best)"
                    if p.runModal() == .OK, let u = p.url { details.choose(title, wallpaper: u) }
                }
                Button("Automatic") { details.choose(title, wallpaper: nil) }.disabled(details.details(title)?.chosenWall == nil)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 820, height: 560)
    }
}

/// A game with no art of its own (none found, or details off): a dark backdrop lit in its cover's colours, never the cover blown up
struct NoArtBackdrop: View {
    let title: Title
    var body: some View {
        let accent = title.game.flatMap { Covers.shared.accent($0) } ?? coverAccent ?? Brand.cyan
        ZStack {
            Brand.ink
            RadialGradient(colors: [accent.opacity(0.55), .clear], center: UnitPoint(x: 0.3, y: 0.35), startRadius: 20, endRadius: 900)
            RadialGradient(colors: [Brand.red.opacity(0.25), .clear], center: UnitPoint(x: 0.85, y: 0.9), startRadius: 20, endRadius: 800)
        }
    }
    private var coverAccent: Color? {
        let d = DetailsStore.shared
        guard let img = d.image(title, d.details(title)?.cover) ?? title.app.map({ NSWorkspace.shared.icon(forFile: $0.path) }) else { return nil }
        return Covers.accent(of: img).map { Color(nsColor: $0) }
    }
}
