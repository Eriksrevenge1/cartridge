// The library's look: each game's art, its play statistics, and the views that show them (the home grid's tiles and a game page's header).
// A game's art is the player's own image (Choose Cover…, or an image dropped on the game's header: <Application Support>/nxnative/<title ID>/cover.png), else the
// game's own icon: the square key art its control data carries (the app's AppIcon.icns), drawn as a tile, as the console's home menu does. Nothing is fetched from the
// network. Play time is counted while the launcher runs the game (a start from Finder is not seen).
import AppKit
import SwiftUI

// MARK: names

extension Game {
    /// The name without a Switch 2 edition's suffix, which the badge says instead ("Xenoblade Chronicles 2 – Nintendo Switch 2 Edition" → "Xenoblade Chronicles 2")
    var title: String {
        for cut in [" – Nintendo Switch 2 Edition", " - Nintendo Switch 2 Edition", " Nintendo Switch 2 Edition"] where name.hasSuffix(cut) { return String(name.dropLast(cut.count)) }
        return name
    }
    /// A Switch 2 game: its title IDs start with 04
    var isSwitch2: Bool { titleID.hasPrefix("04") }
}

/// A small "Switch 2" label beside a Switch 2 game's name
struct Switch2Badge: View {
    var size: CGFloat = 9
    var body: some View {
        Text("SWITCH 2").font(.system(size: size, weight: .heavy)).tracking(size / 18).padding(.horizontal, size * 0.55).padding(.vertical, size * 0.22)
            .foregroundStyle(.white).background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel("Switch 2 game")
    }
}

// MARK: covers

final class Covers: ObservableObject {
    static let shared = Covers()
    @Published private(set) var version = 0   // bumped when a cover changes, so the views read again
    private var cache: [String: NSImage] = [:]

    static func custom(_ g: Game) -> URL { g.support.appendingPathComponent("cover.png") }

    /// The game's art: the player's cover, else the app's icon at its largest
    func image(_ g: Game) -> NSImage {
        if let i = cache[g.id] { return i }
        let img = NSImage(contentsOf: Covers.custom(g))
            ?? Covers.icon(g)
            ?? g.icon
        cache[g.id] = img
        return img
    }
    /// The app's icon file itself (NSWorkspace's icon is a 32-point rendering with the system's mask)
    static func icon(_ g: Game) -> NSImage? {
        guard let info = NSDictionary(contentsOf: g.contents.appendingPathComponent("Info.plist")), let name = info["CFBundleIconFile"] as? String else { return nil }
        return NSImage(contentsOf: g.contents.appendingPathComponent("Resources").appendingPathComponent(name.hasSuffix(".icns") ? name : name + ".icns"))
    }

    /// The player's own cover for this game, from any image file (stored as PNG beside the game's other choices); nil removes it
    func setCustom(_ g: Game, from src: URL?) {
        let dst = Covers.custom(g)
        if let src, let img = NSImage(contentsOf: src), let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: g.support, withIntermediateDirectories: true)
            try? png.write(to: dst)
        } else if src == nil { try? FileManager.default.removeItem(at: dst) }
        cache[g.id] = nil; accents[g.id] = nil; pairs[g.id] = nil; version += 1
        RecentFile.write(Library.shared.games)
    }
    func hasCustom(_ g: Game) -> Bool { FileManager.default.fileExists(atPath: Covers.custom(g).path) }
    /// A game with no icon of its own (a Switch 2 .nup or a dump packs none) and no cover you chose: the store's artwork becomes its cover by itself, once
    /// (Builder.storeArt: only the title ID goes to nintendo.com). Find Cover… and Choose Cover… still replace it
    private var autoTried = Set<String>()
    func autoCover(_ g: Game) {
        guard !autoTried.contains(g.titleID), !hasCustom(g), Covers.icon(g) == nil else { return }
        autoTried.insert(g.titleID)
        Task { @MainActor in
            guard let art = await Builder.storeArt(g.titleID.lowercased()) else { return }
            if !self.hasCustom(g) { self.setCustom(g, from: art) }
        }
    }

    /// The game page's accent, taken from its art (nil: the art is too grey to have one, so the system's accent stays)
    func accent(_ g: Game) -> Color? {
        if let a = accents[g.id] { return a.map { Color(nsColor: $0) } }
        let a = Covers.accent(of: image(g))
        accents[g.id] = .some(a)
        return a.map { Color(nsColor: $0) }
    }
    private var accents: [String: NSColor?] = [:]
    /// The logo's colours on this game's page (neonPair), the icon's cyan | red for grey art
    func pair(_ g: Game) -> (Color, Color) {
        if let p = pairs[g.id] { return p.map { (Color(nsColor: $0.0), Color(nsColor: $0.1)) } ?? (Brand.cyan, Brand.red) }
        let p = Covers.neonPair(of: image(g)); pairs[g.id] = .some(p)
        return p.map { (Color(nsColor: $0.0), Color(nsColor: $0.1)) } ?? (Brand.cyan, Brand.red)
    }
    private var pairs: [String: (NSColor, NSColor)?] = [:]

    /// The logo's two neon colours for this art (left and right of the cartridge, as the icon's cyan | red): the art's two heaviest vivid hues at least 60° apart,
    /// made bright; the second, when the art has only one, the first turned 150° round the wheel. nil for grey art (the icon's own colours then)
    static func neonPair(of img: NSImage) -> (NSColor, NSColor)? {
        let n = 48
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        img.draw(in: NSRect(x: 0, y: 0, width: n, height: n), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let px = rep.bitmapData else { return nil }
        var weight = [Double](repeating: 0, count: 36), hue = [Double](repeating: 0, count: 36), total = 0.0
        for i in 0..<(n * n) {
            let c = NSColor(deviceRed: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255, blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
            guard px[i * 4 + 3] > 127 else { continue }
            total += 1
            let w = c.saturationComponent * c.brightnessComponent * (c.brightnessComponent > 0.15 ? 1 : 0)
            guard w > 0.08 else { continue }
            let k = min(35, Int(c.hueComponent * 36)); weight[k] += w; hue[k] += c.hueComponent * w
        }
        func near(_ k: Int) -> Double { weight[(k + 35) % 36] + weight[k] + weight[(k + 1) % 36] }
        let order = (0..<36).sorted { near($0) > near($1) }
        guard total > 0, let a = order.first, near(a) / total > 0.03 else { return nil }
        let ha = hue[a] / max(weight[a], 1e-9)
        let neon = { (h: Double) in NSColor(deviceHue: CGFloat(h.truncatingRemainder(dividingBy: 1) + (h < 0 ? 1 : 0)), saturation: 0.82, brightness: 1, alpha: 1) }
        let apart = { (k: Int) -> Bool in let d = abs(k - a) % 36; return min(d, 36 - d) >= 6 }
        if let b = order.first(where: { apart($0) && near($0) / total > 0.015 && weight[$0] > 0 }) {
            let hb = hue[b] / max(weight[b], 1e-9)
            return ha <= hb ? (neon(ha), neon(hb)) : (neon(hb), neon(ha))   // cooler hue on the left, as the icon's cyan
        }
        return (neon(ha), neon(ha + 150.0 / 360))
    }

    /// The art's most present vivid hue: the image at 48×48, each pixel weighted by its saturation times its brightness (greys and near-black count for nothing), hues in
    /// 10° buckets, the heaviest bucket (with its neighbours) averaged. Then made dark enough for white text on it (a Play button), at least 3:1 against white (large text and controls), and kept vivid
    static func accent(of img: NSImage) -> NSColor? {
        let n = 48
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        img.draw(in: NSRect(x: 0, y: 0, width: n, height: n), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let px = rep.bitmapData else { return nil }
        var weight = [Double](repeating: 0, count: 36), sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: 36), total = 0.0
        for i in 0..<(n * n) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255, a = Double(px[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            let c = NSColor(deviceRed: r, green: g, blue: b, alpha: 1)
            let w = c.saturationComponent * c.brightnessComponent * (c.brightnessComponent > 0.15 ? 1 : 0)
            total += 1
            guard w > 0.05 else { continue }
            let k = min(35, Int(c.hueComponent * 36))
            weight[k] += w; sum[k].0 += r * w; sum[k].1 += g * w; sum[k].2 += b * w
        }
        // a bucket and its neighbours, so a hue on a bucket's edge is not split in two
        func near(_ k: Int) -> Double { weight[(k + 35) % 36] + weight[k] + weight[(k + 1) % 36] }
        let best = (0..<36).max { near($0) < near($1) }!
        guard total > 0, near(best) / total > 0.03 else { return nil }
        let c = NSColor(deviceRed: sum[best].0 / weight[best], green: sum[best].1 / weight[best], blue: sum[best].2 / weight[best], alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        s = max(s, 0.45); v = min(max(v, 0.45), 0.85)
        func lum(_ c: NSColor) -> Double {
            func f(_ x: CGFloat) -> Double { let x = Double(x); return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * f(c.redComponent) + 0.7152 * f(c.greenComponent) + 0.0722 * f(c.blueComponent)
        }
        var out = NSColor(deviceHue: h, saturation: s, brightness: v, alpha: 1)
        while 1.05 / (lum(out) + 0.05) < 3 && v > 0.2 { v -= 0.02; out = NSColor(deviceHue: h, saturation: s, brightness: v, alpha: 1) }
        return out
    }
}

// MARK: play statistics

struct PlayStats: Codable { var last: Date?; var seconds: Double = 0 }

final class Stats {
    static let shared = Stats()
    private let store = UserDefaults.standard
    private var all: [String: PlayStats]
    init() {
        all = (store.data(forKey: "play.stats")).flatMap { try? JSONDecoder().decode([String: PlayStats].self, from: $0) } ?? [:]
    }
    func of(_ g: Game) -> PlayStats { all[g.titleID] ?? PlayStats() }
    func played(_ g: Game, from start: Date) {
        var s = of(g); s.last = Date(); s.seconds += max(0, Date().timeIntervalSince(start)); all[g.titleID] = s
        if let d = try? JSONEncoder().encode(all) { store.set(d, forKey: "play.stats") }
    }
    static func describe(_ s: PlayStats) -> String? {
        guard let last = s.last else { return nil }
        let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .full
        let h = Int(s.seconds / 3600), m = Int(s.seconds / 60) % 60
        let time = h > 0 ? "\(h) h \(m) min" : m > 0 ? "\(m) min" : "under a minute"
        return "Played \(time) · last \(rel.localizedString(for: last, relativeTo: Date()))"
    }
}

// MARK: views

/// A game's art filling its frame
struct CoverArt: View {
    let game: Game
    @ObservedObject private var covers = Covers.shared
    var body: some View {
        let _ = covers.version
        Image(nsImage: covers.image(game)).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
    }
}

/// One game in the home grid: its cover, its name and how it was last played. Click opens its page, double-click plays it
struct GameCard: View {
    let game: Game
    let playing: Bool
    var picked = false
    var open: () -> Void
    var play: () -> Void
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay(CoverArt(game: game).scaleEffect(hover ? 1.09 : 1)
                        .animation(hover ? .easeOut(duration: 6) : .easeOut(duration: 0.5), value: hover))   // a slow push in while the pointer rests on it
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(picked || hover ? AnyShapeStyle(LinearGradient(colors: [Covers.shared.pair(game).0, Covers.shared.pair(game).1], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color.white.opacity(0.12)),
                                   lineWidth: picked ? 3 : hover ? 1.5 : 1))   // the game in the banner is ringed in its colours
                if hover || playing {
                    Button(action: play) {
                        Label(playing ? "Playing" : "Play", systemImage: playing ? "gamecontroller.fill" : "play.fill").font(.callout.bold())
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain).background(.ultraThickMaterial, in: Capsule()).padding(10)
                    .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(hover ? 0.35 : 0.15), radius: hover ? 14 : 6, y: hover ? 8 : 3)
            .scaleEffect(hover ? 1.025 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Text(game.title).font(.headline).lineLimit(1); if game.isSwitch2 { Switch2Badge() } }
                Text(Stats.describe(Stats.shared.of(game)) ?? (game.version.isEmpty ? game.titleID : "Version \(game.version)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture(count: 2, perform: play)
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton).accessibilityLabel(game.name)
    }
}

enum LibrarySort: String, CaseIterable, Identifiable { case recent = "Recently Played", name = "Name", time = "Most Played"; var id: String { rawValue } }

/// The library's home: the backdrop, the wordmark, the banner, and every game as a card, filtered by the search and sorted. The banner holds the game
/// picked in the grid (a click on its card: the logo and backdrop take its colours), or the game played last while none is; a double-click plays, the banner's
/// Game Page opens the game's page
struct HomeGrid: View {
    let games: [Game]
    @Binding var selection: String?
    @EnvironmentObject var library: Library
    @EnvironmentObject var builder: Builder
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var active
    @ObservedObject private var covers = Covers.shared
    @State private var picked: String?
    /// The game played last
    private var last: Game? { library.games.filter { Stats.shared.of($0).last != nil }.max { (Stats.shared.of($0).last ?? .distantPast) < (Stats.shared.of($1).last ?? .distantPast) } }
    /// The banner's game: the one picked in the grid, or the game played last while the whole library is listed (not during a search)
    private var hero: Game? {
        if let p = picked, let g = games.first(where: { $0.id == p }) { return g }
        return games.count == library.games.count ? last : nil
    }
    var body: some View {
        let _ = covers.version
        let byRecent = library.games.sorted { (Stats.shared.of($0).last ?? .distantPast) > (Stats.shared.of($1).last ?? .distantPast) }
        let lit = hero ?? byRecent.first
        let pair = lit.map { covers.pair($0) } ?? (Brand.cyan, Brand.red)
        ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .firstTextBaseline) {
                        Wordmark(left: pair.0, right: pair.1)
                        Spacer()
                        Text(library.games.count == 1 ? "1 game" : "\(library.games.count) games").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                    if let h = hero {
                        HeroBanner(game: h, playing: library.running.contains(h.id), continuing: h.id == last?.id, open: { selection = h.id }, play: { library.play(h) })
                            .contextMenu { GameMenu(game: h) }
                            .id(h.id).transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    if games.isEmpty {
                        ContentUnavailableView("No games found", systemImage: "magnifyingglass", description: Text("Nothing in the library matches the search."))
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        Text(hero == nil ? "GAMES" : "YOUR LIBRARY").font(.caption.weight(.heavy)).tracking(2).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 22)], spacing: 26) {
                            ForEach(games) { g in
                                GameCard(game: g, playing: library.running.contains(g.id), picked: g.id == picked,
                                         open: { withAnimation(.easeInOut(duration: 0.35)) { picked = g.id } }, play: { library.play(g) })
                                    .contextMenu { GameMenu(game: g) }
                            }
                        }
                    }
                }
                .padding(28)
        }
        .background { HomeBackdrop(hero: lit, moving: active != .inactive && library.running.isEmpty, left: pair.0, right: pair.1) }
    }
}

/// The actions every place that shows a game offers on a right click
struct GameMenu: View {
    let game: Game
    @EnvironmentObject var library: Library
    @EnvironmentObject var builder: Builder
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(library.running.contains(game.id) ? "Show Game" : "Play") { library.play(game) }
        Button("Rebuild") { rebuildGame(game, builder: builder) { openWindow(id: "build") } }.disabled(library.running.contains(game.id))
        Button("Add Update or DLC…") { updateGame(game, builder: builder) { openWindow(id: "build") } }.disabled(library.running.contains(game.id))
        Divider()
        Button("Find Cover…") { CoverFinder.shared.open(game) }
        Button("Choose Cover…") { chooseCover(game) }
        if Covers.shared.hasCustom(game) { Button("Remove Custom Cover") { Covers.shared.setCustom(game, from: nil) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.url]) }
        if let root = GamesFolder.root, !GamesFolder.contains(game.url) {
            Button("Move into Games Folder") { moveIntoGamesFolder(game, root: root, library: library, builder: builder) }.disabled(library.running.contains(game.id))
        }
    }
}

/// A library game's files (its source, the script's folders, the app) moved into the games folder, Rebuild's source following them
func moveIntoGamesFolder(_ g: Game, root: URL, library: Library, builder: Builder) {
    let src = builder.rebuildRequest(for: g)?.source
    let parts = GamesFolder.parts(of: g, source: src)
    let a = NSAlert(); a.messageText = "Move \(g.title) into \(root.lastPathComponent)?"
    a.informativeText = "These move into a folder of their own there:\n" + parts.map { "• " + $0.lastPathComponent }.joined(separator: "\n")
    a.addButton(withTitle: "Move"); a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn, GamesFolder.confirmCopy(parts, to: root) else { return }
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            let n = try GamesFolder.move(g, source: src)
            DispatchQueue.main.async { if let n { builder.setSource(g.titleID, to: n) }; library.scan() }
        } catch {
            DispatchQueue.main.async { library.scan(); let e = NSAlert(); e.messageText = "\(g.title) could not be moved"; e.informativeText = error.localizedDescription; e.runModal() }
        }
    }
}

func chooseCover(_ g: Game) {
    let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.message = "Choose a picture for \(g.name) (a wide one looks best)"
    if p.runModal() == .OK, let u = p.url { Covers.shared.setCustom(g, from: u) }
}

/// A game page's header: the cover across the page, fading into the window, with the game's name, its statistics and its actions on it. An image dropped on it becomes the cover
struct GameHeader<Actions: View>: View {
    let game: Game
    @ViewBuilder var actions: Actions
    @Environment(\.colorScheme) private var scheme
    @State private var dropping = false
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(height: 230)
                .overlay(CoverArt(game: game).blur(radius: 40).saturation(1.3).opacity(0.9))
                .clipped()
                .overlay(LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.65), Color(nsColor: .windowBackgroundColor)],
                                        startPoint: .init(x: 0.5, y: 0.25), endPoint: .bottom))
                .overlay(dropping ? RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).padding(4) : nil)
            Wordmark(left: Covers.shared.pair(game).0, right: Covers.shared.pair(game).1, size: 15)
                .padding(.leading, 22).padding(.top, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(alignment: .bottom, spacing: 16) {
                Color.clear.frame(width: 150, height: 150).overlay(CoverArt(game: game))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(game.title).font(.largeTitle.bold()).lineLimit(2).minimumScaleFactor(0.6)
                        if game.isSwitch2 { Switch2Badge() }
                    }
                    Text("\(game.version.isEmpty ? "" : "Version \(game.version) · ")\(game.titleID)").foregroundStyle(.secondary).textSelection(.enabled)
                    if let s = Stats.describe(Stats.shared.of(game)) { Text(s).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                HStack(spacing: 10) { actions }
            }
            .padding(.horizontal, 22).padding(.bottom, 14)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            providers.first?.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { Covers.shared.setCustom(game, from: u) } } }
            return true
        }
        .contextMenu {
            Button("Find Cover…") { CoverFinder.shared.open(game) }
            Button("Choose Cover…") { chooseCover(game) }
            if Covers.shared.hasCustom(game) { Button("Remove Custom Cover") { Covers.shared.setCustom(game, from: nil) } }
        }
    }
}

// MARK: appearance

enum Appearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    func apply() { NSApp.appearance = self == .system ? nil : NSAppearance(named: self == .light ? .aqua : .darkAqua) }
}
