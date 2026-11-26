// Settings (⌘,): every option Cartridge has, grouped down the side, each saying what it does. Search filters the groups and rows by their words.
import GameController
import SwiftUI

struct SettingsShell: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var builder: Builder
    @AppStorage("settings.group") private var group = Group.library.rawValue
    @State private var search = ""

    enum Group: String, CaseIterable, Identifiable {
        case library = "Library & sources", sound = "Sound & music", look = "Look", controllers = "Controllers", display = "Display & HDR", battery = "Battery",
             building = "Building", updates = "Engine & updates", about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .library: "square.stack.3d.up.fill"; case .sound: "speaker.wave.2.fill"; case .look: "paintpalette.fill"; case .controllers: "gamecontroller.fill"
            case .display: "sun.max.fill"; case .battery: "battery.75percent"; case .building: "hammer.fill"; case .updates: "arrow.triangle.2.circlepath"; case .about: "info.circle.fill"
            }
        }
        /// One line under the page's title: what the group is for
        var blurb: String {
            switch self {
            case .library: "Where your games are, and the launchers Cartridge reads them from"
            case .sound: "Each game's own music, and the shelf's sounds"
            case .look: "How Cartridge looks and moves"
            case .controllers: "The controllers connected to this Mac"
            case .display: "HDR highlights for each screen"
            case .battery: "Lighter settings while your Mac runs on its battery"
            case .building: "Your keys, Xcode and how games are built"
            case .updates: "New versions of Cartridge and the engine it carries"
            case .about: "This version, and the setup check"
            }
        }
        /// The words its rows use, for search
        var words: String {
            switch self {
            case .library: "games folder library folders sources steam battle.net epic gog heroic itch ubisoft amazon crossover whisky app store mac art details music online hidden rescan"
            case .sound: "music volume fade interface sounds"
            case .look: "appearance dark light moving wallpapers motion menu bar"
            case .controllers: "controller gamepad battery xbox playstation switch"
            case .display: "hdr highlights screen brightness edr native auto"
            case .battery: "battery power 30 fps render scale unplugged"
            case .building: "build keys prod.keys python repository engine pipelines shaders"
            case .updates: "update version channel previous engine check"
            case .about: "version setup licences"
            }
        }
    }
    private var groups: [Group] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? Group.allCases : Group.allCases.filter { $0.rawValue.lowercased().contains(q) || $0.words.contains(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) { LogoMark(left: Brand.cyan, right: Brand.red, size: 30); Text("Settings").font(.custom("Avenir Next", size: 24).weight(.heavy)) }
                    .padding(.horizontal, 10).padding(.bottom, 14)
                TextField("Search settings", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 6).padding(.bottom, 10)
                ForEach(groups) { g in
                    let on = g.rawValue == group
                    Button { group = g.rawValue; UISound.move.play() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: g.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7).fill(on ? AnyShapeStyle(LinearGradient(colors: [Brand.cyan, Brand.red], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.gray.opacity(0.5))))
                            Text(g.rawValue).font(.system(size: 14, weight: on ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color.primary.opacity(0.12) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? AnyShapeStyle(LinearGradient(colors: [Brand.cyan.opacity(0.6), Brand.red.opacity(0.6)], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color.clear), lineWidth: 1))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(14).frame(width: 250).background(.ultraThinMaterial)
            Divider().opacity(0.4)
            ScrollView { page.padding(.horizontal, 30).padding(.vertical, 26).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading) }
        }
        // the shelf's own light (cyan and red over the icon's near-black, a pale paper in light mode), still: the cards sit on it as glass
        .background(HomeBackdrop(hero: nil, moving: false).ignoresSafeArea())
        .onChange(of: search) { if let first = groups.first, !groups.contains(where: { $0.rawValue == group }) { group = first.rawValue } }
    }

    @ViewBuilder private var page: some View {
        let g = Group(rawValue: group) ?? .library
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {   // the page's header: its icon large, its name and what it is for
                Image(systemName: g.symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white).frame(width: 58, height: 58)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(LinearGradient(colors: [Brand.cyan, Brand.red], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: Brand.cyan.opacity(0.35), radius: 14, x: -4, y: 4).shadow(color: Brand.red.opacity(0.3), radius: 14, x: 4, y: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(g.rawValue).font(.custom("Avenir Next", size: 30).weight(.heavy))
                    Text(g.blurb).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)
            switch g {
            case .library: LibrarySettings()
            case .sound: SoundSettings()
            case .look: LookSettings()
            case .controllers: ControllerSettings()
            case .display: HDRSettingsView().formStyle(.grouped).scrollContentBackground(.hidden)
            case .battery: BatterySettingsView().formStyle(.grouped).scrollContentBackground(.hidden)
            case .building: BuildSettingsView().environmentObject(builder).formStyle(.grouped).scrollContentBackground(.hidden)
            case .updates: UpdatesSettingsView().formStyle(.grouped).scrollContentBackground(.hidden)
            case .about: AboutSettings()
            }
        }
    }
}

/// A group of rows in a rounded box, under a small heading
struct SettingsBox<C: View>: View {
    let title: String
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(2).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.14), Color.primary.opacity(0.04)], startPoint: .top, endPoint: .bottom)))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }
}

/// One setting: what it is, what it does, and its control
struct SettingsRow<C: View>: View {
    let title: String
    var note: String = ""
    var icon: String? = nil   // an SF Symbol in a small tile before the title
    @ViewBuilder var control: C
    var body: some View {
        HStack(spacing: 16) {
            if let icon {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.18)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if !note.isEmpty { Text(note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1).padding(.leading, 14) }
    }
}

struct LibrarySettings: View {
    @ObservedObject private var titles = Titles.shared
    @AppStorage("details.online") private var online = true
    @State private var off = Set(UserDefaults.standard.stringArray(forKey: "sources.off") ?? [])
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FolderSettings()
            SettingsBox(title: "Sources") {
                ForEach(Store.allCases, id: \.self) { s in
                    let n = titles.external.filter { $0.store == s || $0.runtime == s }.count
                    SettingsRow(title: s.rawValue, note: note(s, n), icon: symbol(s)) {
                        Toggle("", isOn: Binding(get: { !off.contains(s.rawValue) }, set: { on in
                            if on { off.remove(s.rawValue) } else { off.insert(s.rawValue) }
                            Titles.set(s, on: on)
                        })).labelsHidden().toggleStyle(.switch)
                    }
                }
                SettingsRow(title: "Look for games again", note: "\(titles.all.count) games on the shelf") { Button("Rescan") { titles.rescan(); Library.shared.scan() } }
            }
            SettingsBox(title: "Online") {
                SettingsRow(title: "Find art, details and music online", note: "Official art, screenshots, descriptions and trailer music, by title ID, app ID or game name only; kept on this Mac") {
                    Toggle("", isOn: $online).labelsHidden().toggleStyle(.switch)
                }
            }
            if !titles.hidden.isEmpty {
                SettingsBox(title: "Hidden from the shelf") {
                    ForEach(titles.all.filter { titles.hidden.contains($0.id) }) { t in
                        SettingsRow(title: t.name, note: t.platform) { Button("Show") { titles.toggleHidden(t) } }
                    }
                }
            }
        }
    }
    /// The shelf rail's symbol for the store (ShellView.filters), so a source looks the same in both places
    private func symbol(_ s: Store) -> String {
        switch s {
        case .steam: "cloud.fill"; case .battlenet: "bolt.fill"; case .epic: "e.square.fill"; case .gog: "g.square.fill"; case .heroic: "h.square.fill"
        case .itch: "i.square.fill"; case .ubisoft: "u.square.fill"; case .amazon: "a.square.fill"; case .ea: "e.circle.fill"; case .appStore: "bag.fill"
        case .mac: "macwindow"; case .crossover: "wineglass.fill"; case .whisky: "wineglass"
        }
    }
    private func note(_ s: Store, _ n: Int) -> String {
        let what: String
        switch s {
        case .steam: what = "Mac games Steam installed, and Steam's games in CrossOver and Whisky bottles"
        case .battlenet: what = "Games Battle.net installed, here or in a bottle"
        case .epic: what = "Epic Games Launcher's games, here or in a bottle"
        case .gog: what = "GOG games: Mac apps, and GOG Galaxy's in a bottle"
        case .heroic: what = "Heroic's Epic, GOG and Amazon games, and games added to it"
        case .itch: what = "The itch.io app's games"
        case .ubisoft: what = "Ubisoft Connect's games in a bottle"
        case .amazon: what = "Amazon Games' games, in a bottle or through Heroic"
        case .ea: what = "The EA app's games in a bottle"
        case .appStore: what = "Games from the Mac App Store"
        case .mac: what = "Other apps in Applications that call themselves games"
        case .crossover: what = "Games in CrossOver bottles, and the launchers above inside them"
        case .whisky: what = "Games pinned in Whisky bottles, and the launchers above inside them"
        }
        return n > 0 ? "\(what) · \(n) \(n == 1 ? "game" : "games")" : what
    }
}

/// Where the Switch games are: the games folder, and the folders whose nxnative apps appear on the shelf
struct FolderSettings: View {
    @EnvironmentObject var library: Library
    @AppStorage("games.root") private var gamesRoot = ""
    var body: some View {
        SettingsBox(title: "Where your Switch games are") {
            SettingsRow(title: "Games folder", note: "Each game gets a folder here with its files, its build and its app") {
                Text(gamesRoot.isEmpty ? "Not set" : gamesRoot).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button(gamesRoot.isEmpty ? "Choose…" : "Change…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    p.message = "Choose or make your games folder (on the drive with room for your games)"
                    if p.runModal() == .OK, let u = p.url { GamesFolder.set(u); gamesRoot = u.path }
                }
            }
            ForEach(library.folders, id: \.self) { f in
                SettingsRow(title: f.lastPathComponent, note: f.path + " · its apps and three levels of folders in it") { Button("Remove") { library.removeFolder(f) } }
            }
            SettingsRow(title: "Add a library folder", note: "Switch game apps in it appear on the shelf") { Button("Add…") { addFolder(library) } }
        }
    }
}

struct SoundSettings: View {
    @AppStorage("music.on") private var music = true
    @AppStorage("music.volume") private var volume = 0.6
    @AppStorage("music.fade") private var fade = 1
    @AppStorage("sounds.on") private var sounds = true
    @AppStorage("sounds.volume") private var soundVolume = 0.4
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsBox(title: "Music") {
                SettingsRow(title: "Game music on game pages", note: "Each game plays its own music while it is chosen; quiet while a game runs") {
                    Toggle("", isOn: $music).labelsHidden().toggleStyle(.switch).onChange(of: music) { if !music { MusicPlayer.shared.stop() } }
                }
                SettingsRow(title: "Music volume") { Slider(value: $volume, in: 0...1).frame(width: 220); Text("\(Int(volume * 100))%").monospacedDigit().frame(width: 40) }
                SettingsRow(title: "Fade between games", note: "How long one game's music takes to give way to the next") {
                    Picker("", selection: $fade) { Text("Quick").tag(0); Text("Gentle").tag(1); Text("Slow").tag(2) }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
            }
            SettingsBox(title: "Interface") {
                SettingsRow(title: "Interface sounds", note: "A soft sound as you move, choose and go back") { Toggle("", isOn: $sounds).labelsHidden().toggleStyle(.switch) }
                SettingsRow(title: "Interface volume") {
                    Slider(value: $soundVolume, in: 0...1) { editing in if !editing { UISound.move.play() } }.frame(width: 220)
                    Text("\(Int(soundVolume * 100))%").monospacedDigit().frame(width: 40)
                }
            }
        }
    }
}

struct LookSettings: View {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("look.moving") private var moving = true
    @AppStorage("menuBar") private var menuBar = true
    var body: some View {
        SettingsBox(title: "Cartridge") {
            SettingsRow(title: "Appearance", note: "Settings and windows; the home is always dark") {
                Picker("", selection: $appearance) { ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    .onChange(of: appearance) { appearance.apply() }
            }
            SettingsRow(title: "Moving wallpapers", note: "The art behind each game pans slowly (still while a game runs, and with Reduce Motion)") { Toggle("", isOn: $moving).labelsHidden().toggleStyle(.switch) }
            SettingsRow(title: "Show Cartridge in the menu bar", note: "Recent games and console mode") { Toggle("", isOn: $menuBar).labelsHidden().toggleStyle(.switch) }
        }
    }
}

struct ControllerSettings: View {
    @State private var pads = GCController.controllers()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsBox(title: "Connected") {
                if pads.isEmpty { SettingsRow(title: "No controller", note: "Connect one by Bluetooth or USB; the keyboard and mouse work meanwhile") { EmptyView() } }
                ForEach(Array(pads.enumerated()), id: \.offset) { i, c in
                    SettingsRow(title: c.vendorName ?? "Controller", note: c.battery.map { "Battery \(Int($0.batteryLevel * 100))%" } ?? "Wired") { Text("Player \(i + 1)").foregroundStyle(.secondary) }
                }
            }
            SettingsBox(title: "In games") {
                SettingsRow(title: "Buttons, keyboard and mouse", note: "Each Switch game's controls are on its page (Options › Controls), for that game or every game") { EmptyView() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in pads = GCController.controllers() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in pads = GCController.controllers() }
    }
}

struct AboutSettings: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 18) {
            LogoMark(left: Brand.cyan, right: Brand.red, size: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text("cartridge").font(.custom("Avenir Next", size: 34).weight(.heavy))
                Text(verbatim: "Version 1.\(Updates.shared.build)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                Text("Your games, on your Mac, on a shelf.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        SettingsBox(title: "Cartridge") {
            SettingsRow(title: "Version", note: Engine.shared.version.map { "Engine \($0)" } ?? "") { Text(verbatim: "1.\(Updates.shared.build)").monospacedDigit() }
            SettingsRow(title: "Setup check", note: "Xcode, Python, the Metal compiler and your keys") { Button("Open Setup Assistant") { openWindow(id: "setup") } }
        }
        }
    }
}
