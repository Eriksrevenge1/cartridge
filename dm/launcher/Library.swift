// The library: the folders the player picked, the nxnative Mac apps in them (an app whose Info.plist has DMTitleID: pack_app.py), and each game's paths, as the app's own
// launcher (dm/mac/launcher.c) uses them. Play starts the app's Contents/MacOS/nxnative with DM_LAUNCHER=0 (docs/frontends.md, Starting a game): the app reads the same saved
// choices, mods.txt and controls files this launcher writes, so a start from Finder plays the same game.
import AppKit
import Foundation

struct Game: Identifiable, Hashable {
    let url: URL
    let titleID: String      // upper case, as the Application Support folder is named
    let name: String
    let version: String
    let bundleID: String

    var id: String { url.path }
    var contents: URL { url.appendingPathComponent("Contents") }
    var dm: URL { contents.appendingPathComponent("Resources/dm") }
    var executable: URL { contents.appendingPathComponent("MacOS/nxnative") }
    static var supportRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/nxnative") }
    var support: URL { Game.supportRoot.appendingPathComponent(titleID) }
    var saveFolder: URL { support.appendingPathComponent("save") }
    var cheatsFolder: URL { support.appendingPathComponent("cheats") }
    var modsFolder: URL { support.appendingPathComponent("mods") }
    var modsList: URL { support.appendingPathComponent("mods.txt") }
    var controlsFile: URL { support.appendingPathComponent("controls.txt") }
    var envFile: URL { support.appendingPathComponent("env.txt") }
    var log: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/nxnative/\(titleID).log") }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    /// This build of the app: its executable's date and size, which every build or rebuild changes
    var buildStamp: String {
        let a = try? FileManager.default.attributesOfItem(atPath: executable.path)
        return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\((a?[.size] as? NSNumber)?.int64Value ?? 0)"
    }

    init?(app: URL) {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let tid = info["DMTitleID"] as? String, !tid.isEmpty else { return nil }
        url = app
        titleID = tid.uppercased()
        name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent
        version = (info["CFBundleShortVersionString"] as? String) ?? ""
        bundleID = (info["CFBundleIdentifier"] as? String) ?? "org.nxnative.\(tid.lowercased())"
    }

    /// The main module's build ID as cheat files name it: its first 16 hex digits, upper case (main.fixups.tsv, "# BUILD_ID")
    var buildID: String? {
        guard let t = try? String(contentsOf: dm.appendingPathComponent("main.fixups.tsv"), encoding: .utf8) else { return nil }
        for line in t.split(separator: "\n", maxSplits: 40) where line.hasPrefix("# BUILD_ID") {
            let hex = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).last.map(String.init) ?? ""
            return hex.count >= 16 ? String(hex.prefix(16)).uppercased() : nil
        }
        return nil
    }

    /// The settings the app offers (launcher.json, dm/games/settings.py)
    func settings() -> [Setting] {
        guard var d = try? Data(contentsOf: dm.appendingPathComponent("launcher.json")) else { return [] }
        d = RepoSettings.shared.refresh(d)
        guard let f = try? JSONDecoder().decode(SettingsFile.self, from: d) else { return [] }
        return f.settings
    }

    /// KEY=VALUE lines of the game's env files (the player's, then the bundle's), as launcher.c reads them: those keys are fixed for the settings
    func envFileValues() -> [String: String] {
        var out: [String: String] = [:]
        for f in [envFile, dm.appendingPathComponent("env.txt")] {
            guard let t = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for raw in t.split(whereSeparator: \.isNewline) {
                let l = raw.trimmingCharacters(in: .whitespaces)
                guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "="), eq != l.startIndex else { continue }
                let k = l[..<eq].trimmingCharacters(in: .whitespaces)
                if out[k] == nil { out[k] = String(l[l.index(after: eq)...]) }
            }
        }
        return out
    }
}

/// What a finished game said: launcher.c's exit codes (docs/frontends.md, Starting a game)
struct GameExit: Identifiable {
    let id = UUID()
    let game: Game
    let status: Int32
    var message: String {
        switch status {
        case 70: return "macOS stopped running the game's GPU work."
        case 134: return "The game stopped with an error (abort)."
        default: return status > 128 ? "The game stopped on signal \(status - 128)." : "The game ended with code \(status)."
        }
    }
}

final class Library: ObservableObject {
    static let shared = Library()   // the app's one library (links reach it too)
    @Published var folders: [URL] = []
    @Published var games: [Game] = []
    @Published var running: Set<String> = []   // game ids
    @Published var lastExit: GameExit?
    /// Games started for the first time since they were built, not yet open: macOS checks a new app's code signature over the whole bundle before it runs, which for a
    /// game of several GB can take minutes (the game page says so while it lasts)
    @Published var verifying: Set<String> = []
    /// What the battery plan changed for each running game (Power.swift), for its page
    @Published var batteryNote: [String: String] = [:]
    private var processes: [String: Process] = [:]
    private let store = UserDefaults.standard

    init() {
        let saved = store.stringArray(forKey: "library.folders")
        let home = FileManager.default.homeDirectoryForCurrentUser
        folders = (saved ?? ["/Applications", home.appendingPathComponent("Applications").path]).map { URL(fileURLWithPath: $0) }
        scan()
    }

    func addFolder(_ u: URL) {
        guard !folders.contains(u) else { return }
        folders.append(u); persist(); scan()
    }
    func removeFolder(_ u: URL) { folders.removeAll { $0 == u }; persist(); scan() }
    private func persist() { store.set(folders.map(\.path), forKey: "library.folders") }

    /// The apps in each folder and its subfolders (three levels: a build folder holds <title ID>_build/…/<Game>.app), not inside other apps; a folder that is itself an app counts too
    func scan() {
        let fm = FileManager.default
        var found: [String: Game] = [:]
        for folder in folders {
            if folder.pathExtension == "app", let g = Game(app: folder) { found[g.id] = g; continue }
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in e {
                if e.level > 3 { e.skipDescendants(); continue }
                guard u.pathExtension == "app" else { continue }
                e.skipDescendants()
                if let g = Game(app: u) { found[g.id] = g }
            }
        }
        games = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        NX2AppleImport.run(games)
        RecentFile.write(games)   // the widget's list
    }

    /// Starts the game: its own launcher, without its settings window, so this launcher's choices apply as they are saved
    func play(_ g: Game) {
        guard !running.contains(g.id) else { NSRunningApplication.runningApplications(withBundleIdentifier: g.bundleID).first?.activate(); return }
        // started from Finder or the Dock (a tap of Home in it opens console mode): bring it forward rather than start it twice
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: g.bundleID).first { other.activate(); return }
        let p = Process()
        p.executableURL = g.executable
        var env = ProcessInfo.processInfo.environment
        env["DM_LAUNCHER"] = "0"
        // the screen chosen in its settings (ScreenSection), for an app whose launcher does not read display.screen yet; an env file's DM_SCREEN still wins there
        if env["DM_SCREEN"] == nil, let s = UserDefaults(suiteName: g.bundleID)?.string(forKey: "display.screen"), !s.isEmpty, g.envFileValues()["DM_SCREEN"] == nil { env["DM_SCREEN"] = s }
        let battery = BatteryPlan().overrides(for: g)   // lighter settings on battery (Power.swift)
        env.merge(battery) { _, b in b }
        batteryNote[g.id] = BatteryPlan.describe(battery)
        if let d = batteryNote[g.id] { NSLog("Cartridge: %@ %@", g.title, d) }
        p.environment = env
        let started = Date()
        if isFirstStart(g) { verifying.insert(g.id) }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                Stats.shared.played(g, from: started)   // before running changes, so the views that redraw read the new time
                RecentFile.write(self.games)
                self.running.remove(g.id); self.processes[g.id] = nil; self.verifying.remove(g.id); self.batteryNote[g.id] = nil
                let s = proc.terminationReason == .uncaughtSignal ? 128 + proc.terminationStatus : proc.terminationStatus
                if s != 0 { self.lastExit = GameExit(game: g, status: s) }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        do {
            try p.run()
            processes[g.id] = p; running.insert(g.id)
            handFocus(to: g)
        } catch {
            lastExit = GameExit(game: g, status: -1)
            NSLog("Cartridge: cannot start %@: %@", g.executable.path, error.localizedDescription)
        }
    }
    /// Since macOS 14 an app started in the background may not take the focus from the app in front, here Cartridge: the game's own activate was refused, so it opened behind
    /// Cartridge, its fullscreen space hidden where both share a screen, and macOS gave it a covered window's display link. So Cartridge yields to it once it is running
    /// The game is looked for until it is running, for as long as its process lives while macOS checks a new build (that can outlast any fixed count of tries)
    private func handFocus(to g: Game, tries: Int = 40) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: g.bundleID).first, app.isFinishedLaunching {
            if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
            app.activate()
            if verifying.remove(g.id) != nil || isFirstStart(g) { store.set(g.buildStamp, forKey: "started.\(g.id)") }
            return
        }
        guard tries > 0 || verifying.contains(g.id), running.contains(g.id) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.handFocus(to: g, tries: tries - 1) }
    }
    /// This build of the game has not been started from here yet (a new build, or a rebuild): its first start waits for macOS to check it
    func isFirstStart(_ g: Game) -> Bool { store.string(forKey: "started.\(g.id)") != g.buildStamp }
    func stop(_ g: Game) { processes[g.id]?.terminate() }   // SIGTERM: launcher.c forwards it to the host
}

/// The settings list as nxnative has it now (dm/games/settings.tsv in the repository Cartridge was built from): each row's label, note and needs replace those an app was
/// packed with, so a reworded setting or a new dependency (Frame generation only at 60 fps) shows without rebuilding every game. Which rows a game has, their values and
/// defaults stay the app's own: those depend on the game and on what its host can take
final class RepoSettings {
    static let shared = RepoSettings()
    private var rows: [String: (label: String, note: String, needs: String?)] = [:]
    private init() {
        let repo = UserDefaults.standard.string(forKey: "build.repo") ?? (Bundle.main.infoDictionary?["DMRepo"] as? String ?? "")
        guard !repo.isEmpty, let t = try? String(contentsOfFile: repo + "/dm/games/settings.tsv", encoding: .utf8) else { return }
        for line in t.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 7 else { continue }
            let meta = c.count > 8 ? c[8] : ""
            let needs = meta.split(separator: ";").map(String.init).first { $0.hasPrefix("needs=") }.map { String($0.dropFirst(6)) }
            rows[c[0]] = (c[6], c.count > 7 ? c[7] : "", needs)
        }
    }
    func refresh(_ data: Data) -> Data {
        guard !rows.isEmpty, var top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = top["settings"] as? [[String: Any]] else { return data }
        top["settings"] = list.map { r -> [String: Any] in
            guard let env = r["env"] as? String, let now = rows[env] else { return r }
            var o = r; o["label"] = now.label; o["note"] = now.note
            if let n = now.needs { o["needs"] = n } else { o.removeValue(forKey: "needs") }
            return o
        }
        return (try? JSONSerialization.data(withJSONObject: top)) ?? data
    }
}
