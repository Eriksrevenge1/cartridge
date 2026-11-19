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
    private static func icon(_ g: Game) -> NSImage? {
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
        cache[g.id] = nil; version += 1
    }
    func hasCustom(_ g: Game) -> Bool { FileManager.default.fileExists(atPath: Covers.custom(g).path) }
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
    var open: () -> Void
    var play: () -> Void
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay(CoverArt(game: game))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

/// The library's home: every game as a card, filtered by the search and sorted
struct HomeGrid: View {
    let games: [Game]
    @Binding var selection: String?
    @EnvironmentObject var library: Library
    @EnvironmentObject var builder: Builder
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ScrollView {
            if games.isEmpty {
                ContentUnavailableView("No games found", systemImage: "magnifyingglass", description: Text("Nothing in the library matches the search."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 22)], spacing: 26) {
                ForEach(games) { g in
                    GameCard(game: g, playing: library.running.contains(g.id), open: { selection = g.id }, play: { library.play(g) })
                        .contextMenu { GameMenu(game: g) }
                }
            }
            .padding(24)
        }
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
        Button("Choose Cover…") { chooseCover(game) }
        if Covers.shared.hasCustom(game) { Button("Remove Custom Cover") { Covers.shared.setCustom(game, from: nil) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.url]) }
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
