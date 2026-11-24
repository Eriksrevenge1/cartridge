// Every game the library shows: the nxnative apps (Library.swift) and the games other launchers installed (Sources.swift). A Switch game has Cartridge's own pages
// (settings, mods, cheats, controls, saves); another launcher's game starts through that launcher, so its sign-in, updates and cloud saves stay as they are, and
// Cartridge counts its sessions by watching its app start and quit.
import AppKit
import Darwin
import Combine
import Foundation

struct Title: Identifiable, Hashable {
    enum Kind: Hashable { case nx(Game), external(ExternalGame) }
    let kind: Kind

    var id: String { switch kind { case .nx(let g): return "nx:" + g.id; case .external(let e): return e.id } }
    var game: Game? { if case .nx(let g) = kind { return g }; return nil }
    var external: ExternalGame? { if case .external(let e) = kind { return e }; return nil }
    var name: String { game?.title ?? external?.name ?? "" }
    /// Where it comes from, as the filter rail and the label show it
    var platform: String {
        if let g = game { return g.isSwitch2 ? "Nintendo Switch 2" : "Nintendo Switch" }
        guard let e = external else { return "" }
        if let r = e.runtime, r == .crossover || r == .whisky { return "\(e.store == r ? "Windows" : e.store.rawValue) · \(r.rawValue)" }
        return e.store.rawValue
    }
    /// Only Switch games have mods, cheats and Cartridge's own settings
    var hasCartridgePages: Bool { game != nil }
    var app: URL? { game?.url ?? external?.app.map { URL(fileURLWithPath: $0) } }
    var folder: URL? { game.map { $0.url.deletingLastPathComponent() } ?? external?.folder.map { URL(fileURLWithPath: $0) } }
    /// The key play statistics are kept under: a Switch game's title ID (as before), else the id
    var statsKey: String { game?.titleID ?? id }
    var stats: PlayStats {
        var s = Stats.shared.of(key: statsKey)
        if let l = external?.lastPlayed, l > (s.last ?? .distantPast) { s.last = l }
        if let t = external?.seconds, t > s.seconds { s.seconds = t }
        return s
    }
}

final class Titles: ObservableObject {
    static let shared = Titles()
    @Published private(set) var all: [Title] = []
    @Published private(set) var external: [ExternalGame] = []
    @Published var favorites: Set<String> { didSet { store.set(Array(favorites), forKey: "titles.favorites") } }
    @Published var hidden: Set<String> { didSet { store.set(Array(hidden), forKey: "titles.hidden") } }
    /// Running games that are not nxnative apps, by id
    @Published private(set) var runningExternal: Set<String> = []
    private let store = UserDefaults.standard
    private var bag: Set<AnyCancellable> = []
    private var started: [String: Date] = [:]   // started from here, until its app quits

    /// The sources the player turned off (Settings › Library & sources); all are on at first
    static var enabled: Set<Store> {
        let off = Set(UserDefaults.standard.stringArray(forKey: "sources.off") ?? [])
        return Set(Store.allCases.filter { !off.contains($0.rawValue) })
    }
    static func set(_ s: Store, on: Bool) {
        var off = Set(UserDefaults.standard.stringArray(forKey: "sources.off") ?? [])
        if on { off.remove(s.rawValue) } else { off.insert(s.rawValue) }
        UserDefaults.standard.set(Array(off), forKey: "sources.off")
        shared.rescan()
    }

    init() {
        favorites = Set(store.stringArray(forKey: "titles.favorites") ?? [])
        hidden = Set(store.stringArray(forKey: "titles.hidden") ?? [])
        Library.shared.$games.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.merge() }.store(in: &bag)
        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.didLaunchApplicationNotification).merge(with: ws.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: DispatchQueue.main).sink { [weak self] n in self?.appChanged(n) }.store(in: &bag)
        rescan()
    }

    /// Reads the launchers again, off the main thread (their folders can sit on a slow drive)
    func rescan() {
        let on = Titles.enabled
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Sources.scan(.mac, enabled: on)
            DispatchQueue.main.async { self.external = found; self.merge(); self.refreshRunning() }
        }
    }

    private func merge() {
        let nx = Library.shared.games.map { Title(kind: .nx($0)) }
        all = (nx + external.map { Title(kind: .external($0)) }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: play

    func isRunning(_ t: Title) -> Bool {
        if let g = t.game { return Library.shared.running.contains(g.id) || !NSRunningApplication.runningApplications(withBundleIdentifier: g.bundleID).isEmpty }
        return runningExternal.contains(t.id)
    }

    func play(_ t: Title, from source: String = "") {
        NSLog("Cartridge: play %@ (%@)", t.name, source.isEmpty ? "unknown input" : source)
        guard let e = t.external else { if let g = t.game { Library.shared.play(g) }; return }
        if let a = runningApp(of: e) { a.activate(); return }
        started[e.id] = Date()
        switch e.launch {
        case .url(let s): if let u = URL(string: s) { NSWorkspace.shared.open(u) }
        case .app(let p): NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: p), configuration: NSWorkspace.OpenConfiguration())
        case .process(let exe, let args): run(exe, args)
        // the bottle by its path, which cxstart takes as it is (CXBottle.pm find_bottle): a bottle on another drive, or two bottles of one name, start right
        case .crossover(let bottle, let args): run(Places.mac.cxstart, ["--bottle", bottle, "--"] + args); watchBottle(e)
        case .whisky(let exe):
            if let whisky = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.isaacmarovitz.Whisky") {
                NSWorkspace.shared.open([URL(fileURLWithPath: exe)], withApplicationAt: whisky, configuration: NSWorkspace.OpenConfiguration())
            }
            watchBottle(e)
        }
    }

    /// A bottle's game is a Wine process, not an app the workspace reports, so after Play its processes are looked for by the game's folder in their command
    /// lines (Wine shows the Windows path, C:\...\<folder>\game.exe). The launcher it goes through (Steam in the bottle) can take a while to start it, so the
    /// watch waits up to three minutes for it to appear; once it has, its session ends when no process of it is left. A game that closes within 15 seconds of
    /// starting most likely does not run in Wine (a missing Windows component; ProtonDB's "borked"), and the card says so instead of counting a session.
    private func watchBottle(_ e: ExternalGame) {
        guard let f = e.folder, case let name = URL(fileURLWithPath: f).lastPathComponent.lowercased(), !name.isEmpty else { return }
        let marks = ["\\" + name + "\\", "/" + name + "/"]
        DispatchQueue.global(qos: .utility).async {
            let asked = Date()
            var seen: Date?
            while true {
                Thread.sleep(forTimeInterval: 3)
                let up = Titles.commandLines().contains { c in marks.contains { c.contains($0) } }
                if up, seen == nil {
                    seen = Date()
                    DispatchQueue.main.async { self.runningExternal.insert(e.id); self.started[e.id] = Date() }
                }
                if seen == nil, Date().timeIntervalSince(asked) > 180 { DispatchQueue.main.async { self.started[e.id] = nil }; return }
                if let s = seen, !up {
                    let secs = Date().timeIntervalSince(s)
                    DispatchQueue.main.async {
                        self.runningExternal.remove(e.id); self.started[e.id] = nil
                        let t = Title(kind: .external(e))
                        if secs < 15 { Sessions.shared.quickExit(t) }
                        else { Stats.shared.played(key: t.statsKey, from: s); Sessions.shared.ended(t, seconds: secs) }
                    }
                    return
                }
            }
        }
    }
    /// Every process's command line, lowercased
    static func commandLines() -> [String] {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axww", "-o", "command="]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).lowercased().split(separator: "\n").map(String.init)
    }
    private func run(_ exe: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        do { try p.run() } catch { NSLog("Cartridge: cannot start %@: %@", exe, error.localizedDescription) }
    }

    /// The running app that is this game: its app, an app inside its folder (a launcher's game starts its own executable there), or for a bottle's game, Wine
    /// running in that bottle (CrossOver names its processes by the program, so the folder decides)
    func runningApp(of e: ExternalGame) -> NSRunningApplication? { NSWorkspace.shared.runningApplications.first { owns(e, $0) } }
    private func owns(_ e: ExternalGame, _ a: NSRunningApplication) -> Bool {
        guard let p = (a.bundleURL ?? a.executableURL)?.standardizedFileURL.path else { return false }
        if let app = e.app, p == URL(fileURLWithPath: app).standardizedFileURL.path { return true }
        if let f = e.folder.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }), f.count > 1, p.hasPrefix(f + "/") { return true }
        return false
    }
    private func refreshRunning() { runningExternal = Set(external.filter { runningApp(of: $0) != nil }.map(\.id)) }
    /// An app started or quit: a game that quits had a session, counted from when it started
    private func appChanged(_ n: Notification) {
        guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        for e in external where owns(e, a) {
            if n.name == NSWorkspace.didLaunchApplicationNotification {
                runningExternal.insert(e.id)
                if started[e.id] == nil { started[e.id] = a.launchDate ?? Date() }
            } else if runningApp(of: e) == nil {
                runningExternal.remove(e.id)
                let from = started.removeValue(forKey: e.id) ?? a.launchDate ?? Date()
                let t = Title(kind: .external(e))
                Stats.shared.played(key: t.statsKey, from: from)
                Sessions.shared.ended(t, seconds: Date().timeIntervalSince(from))
            }
        }
    }

    /// Ends the game: a Switch game through the launcher that started it (SIGTERM, which it forwards to the host), else its app wherever it was started from
    /// (Finder, the Dock, an earlier Cartridge), and as a last resort any process running its executable; another launcher's game by quitting its app
    func stop(_ t: Title) {
        if let g = t.game {
            Library.shared.stop(g)
            for a in NSRunningApplication.runningApplications(withBundleIdentifier: g.bundleID) { a.terminate() }
            let exe = g.executable.standardizedFileURL.path
            for pid in Titles.pids(running: exe) { kill(pid, SIGTERM) }
        } else if let e = t.external {
            runningApp(of: e)?.terminate()
        }
    }
    /// The processes whose executable is this file
    static func pids(running path: String) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size)))
        var out: [pid_t] = []
        var p = [CChar](repeating: 0, count: 4096)
        for pid in buf.prefix(max(0, n)) where pid > 0 {
            if proc_pidpath(pid, &p, UInt32(p.count)) > 0, String(cString: p) == path { out.append(pid) }
        }
        return out
    }

    func toggleFavorite(_ t: Title) { if favorites.contains(t.id) { favorites.remove(t.id) } else { favorites.insert(t.id) } }
    func toggleHidden(_ t: Title) { if hidden.contains(t.id) { hidden.remove(t.id) } else { hidden.insert(t.id) } }
}

/// A session that just ended, for the card the home shows for a few seconds
final class Sessions: ObservableObject {
    static let shared = Sessions()
    struct Ended: Identifiable, Equatable { let id = UUID(); let title: String; let titleID: String; let seconds: Double; let total: Double; var quick: String? = nil }
    @Published var last: Ended?
    func ended(_ t: Title, seconds: Double) {
        guard seconds >= 10 else { return }
        last = Ended(title: t.name, titleID: t.id, seconds: seconds, total: t.stats.seconds)
    }
    /// A bottle's game that closed right after it started: what runs it, for the card
    func quickExit(_ t: Title) {
        last = Ended(title: t.name, titleID: t.id, seconds: 0, total: t.stats.seconds, quick: t.external?.runtime?.rawValue ?? "Wine")
    }
}
