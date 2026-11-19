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

    var body: some Scene {
        WindowGroup("nxnative Launcher") {
            LibraryView().environmentObject(library).environmentObject(pad)
                .frame(minWidth: 860, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder to Library…") { addFolder(library) }.keyboardShortcut("o")
                Button("Refresh Library") { library.scan() }.keyboardShortcut("r")
            }
        }
        Settings {
            FoldersView().environmentObject(library).frame(width: 520, height: 320)
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

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var pad: GamepadNav
    @State private var selection: String?
    @State private var page: Page = .settings

    private var selected: Game? { library.games.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(library.games) { g in
                    HStack(spacing: 10) {
                        Image(nsImage: g.icon).resizable().frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).lineLimit(2)
                            Text(library.running.contains(g.id) ? "Playing" : g.version).font(.caption).foregroundStyle(library.running.contains(g.id) ? .green : .secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(g.id)
                    .contextMenu {
                        Button("Play") { library.play(g) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([g.url]) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if library.games.isEmpty {
                    VStack(spacing: 12) {
                        Text("No games yet").font(.headline)
                        Text("Add the folder your nxnative Mac apps are in.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Add Folder…") { addFolder(library) }
                    }.padding()
                }
            }
            .toolbar {
                ToolbarItem { Button { addFolder(library) } label: { Label("Add Folder", systemImage: "folder.badge.plus") } }
                ToolbarItem { Button { library.scan() } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers { _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { library.addFolder(u) } } } }
                return true
            }
        } detail: {
            if let g = selected { GameView(game: g, page: $page).id(g.id) }
            else { Text("Pick a game").foregroundStyle(.secondary) }
        }
        .onAppear { if selection == nil { selection = library.games.first?.id }; bindPad() }
        .onChange(of: library.games) { if selected == nil { selection = library.games.first?.id } }
        .alert(item: $library.lastExit) { e in
            Alert(title: Text(e.game.name), message: Text(e.message),
                  primaryButton: .default(Text("Open Log")) { NSWorkspace.shared.open(e.game.log) }, secondaryButton: .cancel(Text("OK")))
        }
    }

    private func bindPad() {
        pad.onMove = { d in
            let ids = library.games.map(\.id); guard !ids.isEmpty else { return }
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: game.icon).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.name).font(.title2.bold())
                    Text("\(game.version.isEmpty ? "" : "Version \(game.version) · ")\(game.titleID)").foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if library.running.contains(game.id) {
                    Button("Stop") { library.stop(game) }.controlSize(.large)
                    Button("Show Game") { library.play(game) }.controlSize(.large)
                } else {
                    Button { library.play(game) } label: { Label("Play", systemImage: "play.fill").padding(.horizontal, 8) }
                        .controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding()
            Picker("", selection: $page) { ForEach(Page.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal).frame(maxWidth: 520)
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
    @State private var pick: URL?
    var body: some View {
        VStack(alignment: .leading) {
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
