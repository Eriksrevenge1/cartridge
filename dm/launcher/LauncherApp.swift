// nxnative Launcher: a library of the nxnative Mac apps the player built, with each game's settings, mods, cheats, controls and saves, and Play. Built by scripts/build_launcher.py.
// It writes only what each app reads by itself (docs/frontends.md): the saved choices in the app's preferences, mods.txt, the cheat files, the controls files and the cloud
// saves folder, so a game started from Finder or the Dock plays as it does from here. A controller drives the library: up and down pick a game, A plays it, L and R change the page.
import AppKit
import GameController
import SwiftUI

@main
struct LauncherApp: App {
    @StateObject private var library = Library()
    @StateObject private var pad = GamepadNav()
    @StateObject private var builder = Builder()
    @StateObject private var devices = Devices()
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some Scene {
        WindowGroup("nxnative Launcher") {
            LibraryView().environmentObject(library).environmentObject(pad).environmentObject(builder)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { builder.library = library; builder.devices = devices; devices.builder = builder; appearance.apply() }
                .onChange(of: appearance) { appearance.apply() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder to Library…") { addFolder(library) }.keyboardShortcut("o")
                Button("Refresh Library") { library.scan() }.keyboardShortcut("r")
            }
        }
        Window("Build Games", id: "build") {
            BuildView().environmentObject(builder).frame(minWidth: 820, minHeight: 520)
                .onAppear { builder.library = library; builder.devices = devices; devices.builder = builder }
        }
        Window("Install on iPhone or iPad", id: "devices") {
            DevicesView().environmentObject(devices).frame(minWidth: 780, minHeight: 480)
                .onAppear { devices.builder = builder }
        }
        Settings {
            TabView {
                FoldersView().environmentObject(library).tabItem { Label("Library", systemImage: "books.vertical") }
                BuildSettingsView().environmentObject(builder).tabItem { Label("Building", systemImage: "hammer") }
            }
            .frame(width: 560, height: 400)
        }
    }
}

func addFolder(_ library: Library) {
    let p = NSOpenPanel()
    p.canChooseDirectories = true; p.canChooseFiles = true; p.allowedContentTypes = [.application, .folder]
    p.message = "Choose a folder that holds nxnative games (or one game's app)"
    if p.runModal() == .OK, let u = p.url { library.addFolder(u) }
}

enum Page: String, CaseIterable, Identifiable {
    case settings = "Settings", mods = "Mods", cheats = "Cheats", controls = "Controls", saves = "Saves"
    var id: String { rawValue }
}

/// The sidebar's first row: the home grid, not a game
let homeID = "home"

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var pad: GamepadNav
    @EnvironmentObject var builder: Builder
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String? = homeID
    @State private var page: Page = .settings
    @State private var search = ""
    @AppStorage("library.sort") private var sort: LibrarySort = .recent

    private var selected: Game? { library.games.first { $0.id == selection } }
    /// The games the search and the sort leave, in order
    private var shown: [Game] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let f = q.isEmpty ? library.games : library.games.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.titleID.localizedCaseInsensitiveContains(q) }
        switch sort {
        case .name: return f
        case .recent: return f.sorted { (Stats.shared.of($0).last ?? .distantPast) > (Stats.shared.of($1).last ?? .distantPast) }
        case .time: return f.sorted { Stats.shared.of($0).seconds > Stats.shared.of($1).seconds }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("All Games", systemImage: "square.grid.2x2").tag(homeID)
                Section("Games") {
                    ForEach(shown) { g in
                        HStack(spacing: 10) {
                            Color.clear.frame(width: 34, height: 34).overlay(CoverArt(game: g)).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.title).lineLimit(1)
                                if library.running.contains(g.id) { Text("Playing").font(.caption).foregroundStyle(.green) }
                            }
                        }
                        .padding(.vertical, 1)
                        .tag(g.id)
                        .contextMenu { GameMenu(game: g) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 270)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers { _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { library.addFolder(u) } } } }
                return true
            }
        } detail: {
            Group {
                if library.games.isEmpty {
                    ContentUnavailableView {
                        Label("No games yet", systemImage: "gamecontroller")
                    } description: {
                        Text("Build a game from its NSP folder, dump folder or .nup, or add the folder your nxnative Mac apps are in.")
                    } actions: {
                        Button("Build a Game…") { openWindow(id: "build") }.buttonStyle(.borderedProminent)
                        Button("Add Folder…") { addFolder(library) }
                    }
                } else if let g = selected { GameView(game: g, page: $page).id(g.id) }
                else { HomeGrid(games: shown, selection: $selection) }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Picker("Sort By", selection: $sort) { ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline)
                    } label: { Label("Sort: \(sort.rawValue)", systemImage: "arrow.up.arrow.down") }
                    .help("Sort the games: \(sort.rawValue)")
                }
                ToolbarItem {
                    Menu {
                        Button("Build a Game…") { openWindow(id: "build") }
                        Button("Rebuild All Games") { rebuildAll(library.games, library: library, builder: builder) { openWindow(id: "build") } }
                            .disabled(library.games.isEmpty)
                    } label: { Label("Build", systemImage: "hammer") } primaryAction: { openWindow(id: "build") }
                    .help("Build a game (click), or rebuild every game after an nxnative update (hold)")
                }
                ToolbarItem { Button { openWindow(id: "devices") } label: { Label("Install on iPhone or iPad", systemImage: "iphone.and.arrow.forward") } }
                ToolbarItem { Button { addFolder(library) } label: { Label("Add Folder", systemImage: "folder.badge.plus") } }
                ToolbarItem { Button { library.scan() } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search games")
        .onChange(of: search) { if !search.isEmpty && selected != nil { selection = homeID } }
        .onChange(of: library.games) { if selection != homeID && selected == nil { selection = homeID } }
        .onAppear { bindPad() }
        .alert(item: $library.lastExit) { e in
            Alert(title: Text(e.game.name), message: Text(e.message),
                  primaryButton: .default(Text("Open Log")) { NSWorkspace.shared.open(e.game.log) }, secondaryButton: .cancel(Text("OK")))
        }
    }

    private func bindPad() {
        pad.onMove = { d in
            let ids = [homeID] + shown.map(\.id)
            let i = selection.flatMap { ids.firstIndex(of: $0) } ?? 0
            selection = ids[max(0, min(ids.count - 1, i + d))]
        }
        pad.onPage = { d in
            let all = Page.allCases, i = all.firstIndex(of: page) ?? 0
            page = all[(i + d + all.count) % all.count]
        }
        pad.onPlay = { if let g = selected { library.play(g) } }
    }
}

struct GameView: View {
    let game: Game
    @Binding var page: Page
    @EnvironmentObject var library: Library
    @EnvironmentObject var builder: Builder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            GameHeader(game: game) {
                Button("Rebuild") { rebuildGame(game, builder: builder) { openWindow(id: "build") } }
                    .controlSize(.large).disabled(library.running.contains(game.id))
                    .help(builder.rebuildRequest(for: game).map { "Build this game again from \($0.source.path): after a game update or a newer nxnative" }
                          ?? "Build this game again: choose its NSP folder, dump folder or .nup")
                if library.running.contains(game.id) {
                    Button("Stop") { library.stop(game) }.controlSize(.large)
                    Button("Show Game") { library.play(game) }.controlSize(.large).buttonStyle(.borderedProminent)
                } else {
                    Button { library.play(game) } label: { Label("Play", systemImage: "play.fill").padding(.horizontal, 10) }
                        .controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [.command])
                }
            }
            Picker("", selection: $page) { ForEach(Page.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal).frame(maxWidth: 520).padding(.top, 4)
            Divider().padding(.top, 8)
            switch page {
            case .settings: GameSettingsView(game: game)
            case .mods: ModsView(game: game)
            case .cheats: CheatsView(game: game)
            case .controls: ControlsView(game: game)
            case .saves: SavesView(game: game)
            }
        }
    }
}

/// The app's own settings list (launcher.json) on the app's own store: the same rows as its settings window (LauncherRow.swift); a row an env file sets is shown fixed
struct GameSettingsView: View {
    let game: Game
    @StateObject private var m: LauncherModel
    init(game: Game) {
        self.game = game
        var env = game.envFileValues()
        env["DM_ENV_FILE_KEYS"] = env.keys.sorted().joined(separator: " ")
        _m = StateObject(wrappedValue: LauncherModel(game.settings(), defaults: UserDefaults(suiteName: game.bundleID) ?? .standard, environment: env))
    }
    var body: some View {
        Form {
            if m.settings.isEmpty { Text("This app was packed without a settings list.").foregroundStyle(.secondary) }
            ForEach(m.sections, id: \.self) { sec in
                Section(sec) { ForEach(m.rows(in: sec)) { SettingRow(s: $0, m: m) } }
            }
            if !m.settings.isEmpty {
                Section {
                    Button("Reset to Tested Defaults") { m.reset() }.disabled(!m.changed)
                    Text("Choices are saved in the game itself: starting it from Finder uses them too.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: m.values) { m.save() }
    }
}

/// Cloud saves (the cloudSaves.folder key: docs/frontends.md, The cloud saves folder), the save, the log and the player's env.txt
struct SavesView: View {
    let game: Game
    @State private var cloud: String = ""
    private var prefs: UserDefaults? { UserDefaults(suiteName: game.bundleID) }

    var body: some View {
        Form {
            Section("Cloud saves") {
                LabeledContent("Folder", value: cloud.isEmpty ? "Off" : cloud)
                HStack {
                    Button("Choose Folder…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        p.message = "Choose a folder to sync this game's save through (iCloud Drive, for instance). One folder can serve every game."
                        if p.runModal() == .OK, let u = p.url { set(u.path) }
                    }
                    Button("Use for Every Game") { setAll(cloud) }.disabled(cloud.isEmpty)
                    Button("Turn Off") { set("") }.disabled(cloud.isEmpty)
                }
                Text("The save is synced at each start and after the game ends.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Files") {
                Button("Open Save Folder") { open(game.saveFolder) }
                Button("Open Game Folder") { open(game.support) }
                Button("Open Log") { NSWorkspace.shared.open(game.log) }.disabled(!FileManager.default.fileExists(atPath: game.log.path))
                Button("Edit env.txt") {
                    if !FileManager.default.fileExists(atPath: game.envFile.path) {
                        try? FileManager.default.createDirectory(at: game.support, withIntermediateDirectories: true)
                        try? "# KEY=VALUE lines for this game (docs/settings.md, Settings in a file)\n".write(to: game.envFile, atomically: true, encoding: .utf8)
                    }
                    NSWorkspace.shared.open(game.envFile)
                }
                Button("Show App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.url]) }
            }
        }
        .formStyle(.grouped)
        .onAppear { cloud = prefs?.string(forKey: "cloudSaves.folder") ?? "" }
    }
    @EnvironmentObject private var library: Library
    private func set(_ path: String) {
        if path.isEmpty { prefs?.removeObject(forKey: "cloudSaves.folder") } else { prefs?.set(path, forKey: "cloudSaves.folder") }
        cloud = path
    }
    private func setAll(_ path: String) { for g in library.games { UserDefaults(suiteName: g.bundleID)?.set(path, forKey: "cloudSaves.folder") } }
    private func open(_ u: URL) { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); NSWorkspace.shared.open(u) }
}

struct FoldersView: View {
    @EnvironmentObject var library: Library
    @AppStorage("appearance") private var appearance: Appearance = .system
    @State private var pick: URL?
    var body: some View {
        VStack(alignment: .leading) {
            Picker("Appearance", selection: $appearance) { ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 320)
            Divider().padding(.vertical, 4)
            Text("Library folders").font(.headline)
            Text("nxnative Mac apps in these folders (and three levels of subfolders) appear in the library.").font(.footnote).foregroundStyle(.secondary)
            List(selection: $pick) { ForEach(library.folders, id: \.self) { Text($0.path).tag($0) } }
            HStack {
                Button("Add…") { addFolder(library) }
                Button("Remove") { if let p = pick { library.removeFolder(p) } }.disabled(pick == nil)
            }
        }
        .padding()
    }
}

/// A controller in the library (GameController): the D-pad or the left stick moves through the games, A plays, L and R change the page. Only while this app is active:
/// the game, another app, reads its controllers itself
final class GamepadNav: ObservableObject {
    var onMove: ((Int) -> Void)?
    var onPage: ((Int) -> Void)?
    var onPlay: (() -> Void)?
    private var stickLatch: [ObjectIdentifier: Int] = [:]

    init() {
        GCController.shouldMonitorBackgroundEvents = false
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        }
        GCController.controllers().forEach(attach)
    }
    private func act(_ f: () -> Void) { if NSApp.isActive { f() } }
    private func attach(_ c: GCController) {
        guard let g = c.extendedGamepad else { return }
        g.dpad.up.pressedChangedHandler = { [weak self] _, _, p in if p { self?.act { self?.onMove?(-1) } } }
        g.dpad.down.pressedChangedHandler = { [weak self] _, _, p in if p { self?.act { self?.onMove?(1) } } }
        g.leftShoulder.pressedChangedHandler = { [weak self] _, _, p in if p { self?.act { self?.onPage?(-1) } } }
        g.rightShoulder.pressedChangedHandler = { [weak self] _, _, p in if p { self?.act { self?.onPage?(1) } } }
        // A as the host reads it (pad_apple.h): the right face button, which GameController names buttonB on most pads and buttonA on a Nintendo one (by its label)
        let labelled = c.productCategory == "Switch Pro Controller" || c.productCategory.contains("Joy-Con")
        (labelled ? g.buttonA : g.buttonB).pressedChangedHandler = { [weak self] _, _, p in if p { self?.act { self?.onPlay?() } } }
        let id = ObjectIdentifier(c)
        g.leftThumbstick.yAxis.valueChangedHandler = { [weak self] _, v in
            guard let self else { return }
            let d = v > 0.6 ? -1 : v < -0.6 ? 1 : 0
            if d != self.stickLatch[id, default: 0] { self.stickLatch[id] = d; if d != 0 { self.act { self.onMove?(d) } } }
        }
    }
}

/// Rebuild: the source the launcher knows or finds beside the app, else the one the player chooses; prod.keys asked for when NSPs need them
func rebuildGame(_ game: Game, builder: Builder, show: () -> Void) {
    var r = builder.rebuildRequest(for: game)
    if r == nil {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true; p.directoryURL = game.url.deletingLastPathComponent()
        p.message = "Choose \(game.name)'s NSP folder, dump folder or .nup file"
        guard p.runModal() == .OK, let u = p.url else { return }
        let beside = u.pathExtension.lowercased() == "nup" ? u.deletingLastPathComponent() : u, here = game.url.deletingLastPathComponent()
        r = BuildRequest(source: u, target: .mac, outFolder: beside.standardizedFileURL == here.standardizedFileURL ? nil : here)
    }
    guard var req = r, askKeysIfNeeded([req], builder: builder) else { return }
    req.fallbackIcon = Builder.iconPNG(of: game)
    builder.enqueue(req); show()
}

/// Rebuild All Games: every game that is not running and whose source is known or found beside its app, one after the other; the others are named in an alert
func rebuildAll(_ games: [Game], library: Library, builder: Builder, show: () -> Void) {
    var reqs: [BuildRequest] = [], skipped: [String] = []
    for g in games {
        if library.running.contains(g.id) { skipped.append("\(g.name) (playing)"); continue }
        guard var r = builder.rebuildRequest(for: g) else { skipped.append("\(g.name) (its files were not found beside the app: use Rebuild on its page)"); continue }
        r.fallbackIcon = Builder.iconPNG(of: g); reqs.append(r)
    }
    if !reqs.isEmpty, askKeysIfNeeded(reqs, builder: builder) { reqs.forEach(builder.enqueue); show() }
    if !skipped.isEmpty {
        let a = NSAlert(); a.messageText = reqs.isEmpty ? "No game can be rebuilt" : "Rebuilding \(reqs.count) of \(games.count) games"
        a.informativeText = "Not rebuilt:\n" + skipped.joined(separator: "\n"); a.runModal()
    }
}

/// prod.keys, asked for once when any of these builds reads NSPs and none is set; false when the player cancels
func askKeysIfNeeded(_ reqs: [BuildRequest], builder: Builder) -> Bool {
    guard reqs.contains(where: { builder.needsKeys($0.source) }), builder.keys.isEmpty else { return true }
    let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.message = "Choose prod.keys (dumped from your Switch): NSPs need them"
    guard p.runModal() == .OK, let u = p.url else { return false }
    builder.keys = u.path
    return true
}
