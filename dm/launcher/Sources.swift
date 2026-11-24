// The games other launchers installed, read from the files each launcher keeps, never fetched: what the library shows beside the nxnative apps (Titles.swift).
// Each reader takes the folders it reads (a Places), so tests run it on fixture trees (dm/launcher/tests/sources_check.swift). A Windows launcher inside a CrossOver or
// Whisky bottle is read by the same reader through the bottle's drives (WinRoot), and its games start through the bottle. Each format below was checked (2026-11)
// against the code of launchers that read the same files every day: Playnite's library plug-ins, Heroic, Lutris and Whisky's own.
//
//   Steam       steamapps/libraryfolders.vdf, each library's appmanifest_<id>.acf; play time from userdata/<user>/config/localconfig.vdf
//   Battle.net  Agent/product.db (protobuf: each install's uid and folder); last play from Battle.net.config (Mac); started by Battle.net's binary with
//               --exec="launch <product code>" (Playnite's uid → code table)
//   Epic        EpicGamesLauncher/Data/Manifests/*.item (JSON); add-ons, plug-ins and Unreal Engine left out as Playnite does
//   GOG         goggame-<id>.info in a game's folder or app (Mac); HKLM\Software\[Wow6432Node\]GOG.com\Games\<id> in a bottle's registry, or
//               Galaxy's uninstall entry (<id>_is1, publisher GOG.com) and the primary play task of the game's goggame-<id>.info
//   Heroic      legendaryConfig/legendary/installed.json (Epic), gog_store/installed.json, nile_config/nile/installed.json (Amazon), sideload_apps/library.json
//   itch        itch/db/butler.db (SQLite: caves, games, install_locations); started by itch://install?game_id=<id>&launch, the link the itch app handles
//   Ubisoft     HKLM\Software\[Wow6432Node\]Ubisoft\Launcher\Installs\<id> in a bottle's registry
//   Amazon      Amazon Games/Data/Games/Sql/GameInstallInfo.sqlite in a bottle
//   EA app      Program Files\EA Games\<game>\__Installer\installerdata.xml (its offer id) in a bottle, started by origin2://game/launch?offerIds=…
//   CrossOver   ~/Library/Application Support/CrossOver/Bottles/<bottle>: the launchers above inside it, and its other Start menu programs (cxmenu.conf)
//   Whisky      its bottles (its Bottles folder, and the folders BottleVM.plist lists): Metadata.plist info.pins, and the launchers above inside each
//   Mac         apps in /Applications and ~/Applications whose category is a game category; App Store ones carry Contents/_MASReceipt
import Foundation
import SQLite3

enum Store: String, Codable, CaseIterable {
    case steam = "Steam", battlenet = "Battle.net", epic = "Epic Games", gog = "GOG", heroic = "Heroic", itch = "itch.io", ubisoft = "Ubisoft Connect",
         amazon = "Amazon Games", ea = "EA app", appStore = "App Store", mac = "Mac", crossover = "CrossOver", whisky = "Whisky"
}

/// How a game starts
enum Launch: Hashable {
    case url(String)                                   // a launcher's link (steam://, com.epicgames.launcher://, heroic://, itch://)
    case app(String)                                   // a Mac app's path
    case process(String, [String])                     // an executable and its arguments (Battle.net's --exec)
    case crossover(bottle: String, args: [String])   // the bottle's folder (cxstart --bottle takes a path)     // CrossOver's cxstart --bottle <bottle> -- <args>
    case whisky(exe: String)                           // a Windows program Whisky opens
}

struct ExternalGame: Hashable {
    let id: String              // store:key[@bottle]
    let name: String
    let store: Store
    let launch: Launch
    var app: String? = nil      // the Mac app (its icon; the running app it becomes)
    var folder: String? = nil   // where it is installed
    var bottle: String? = nil   // the CrossOver or Whisky bottle it runs in
    var runtime: Store? = nil   // .crossover or .whisky when it runs in a bottle
    var size: Int64? = nil
    var lastPlayed: Date? = nil
    var seconds: Double? = nil
}

/// The folders the readers look in: the Mac's own by default, a fixture tree in tests
struct Places {
    var home: URL
    var shared: URL = URL(fileURLWithPath: "/Users/Shared")
    var applications: [URL] = [URL(fileURLWithPath: "/Applications")]
    var crossoverApp: URL = URL(fileURLWithPath: "/Applications/CrossOver.app")
    static var mac: Places {
        let h = FileManager.default.homeDirectoryForCurrentUser
        return Places(home: h, applications: [URL(fileURLWithPath: "/Applications"), h.appendingPathComponent("Applications")])
    }
    var support: URL { home.appendingPathComponent("Library/Application Support") }
    var cxstart: String { crossoverApp.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/cxstart").path }
    /// The folders CrossOver keeps bottles in: its default, and the one chosen in its settings (its BottleDir preference, e.g. a game drive)
    var crossoverBottleDirs: [URL] {
        var dirs = [support.appendingPathComponent("CrossOver/Bottles")]
        let prefs = NSDictionary(contentsOf: home.appendingPathComponent("Library/Preferences/com.codeweavers.CrossOver.plist"))
        let live = home == FileManager.default.homeDirectoryForCurrentUser ? UserDefaults(suiteName: "com.codeweavers.CrossOver")?.string(forKey: "BottleDir") : nil
        if let d = live ?? prefs?["BottleDir"] as? String, !d.isEmpty {
            let u = URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
            if !dirs.contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) { dirs.append(u) }
        }
        return dirs
    }
}

enum Sources {
    /// Every game the readers find, each once (a game two launchers list keeps its first: the Mac launcher before a bottle's)
    static func scan(_ p: Places = .mac, enabled: Set<Store> = Set(Store.allCases)) -> [ExternalGame] {
        var out: [ExternalGame] = []
        func add(_ s: Store, _ f: () -> [ExternalGame]) { if enabled.contains(s) { out += f() } }
        add(.steam) { SteamReader.mac(p) }
        add(.battlenet) { BattleNetReader.mac(p) }
        add(.epic) { EpicReader.read(manifests: p.support.appendingPathComponent("Epic/EpicGamesLauncher/Data/Manifests"), root: nil) }
        add(.heroic) { HeroicReader.read(p) }
        add(.itch) { ItchReader.read(p) }
        // Windows launchers in bottles
        var bottles: [WinRoot] = []
        if enabled.contains(.crossover) { bottles += WinRoot.crossover(p) }
        if enabled.contains(.whisky) { bottles += WinRoot.whisky(p) }
        for b in bottles {
            add(.steam) { SteamReader.windows(b) }
            add(.battlenet) { BattleNetReader.windows(b) }
            add(.epic) { EpicReader.read(manifests: b.mac("C:\\ProgramData\\Epic\\EpicGamesLauncher\\Data\\Manifests"), root: b) }
            add(.gog) { GOGReader.windows(b) }
            add(.ubisoft) { UbisoftReader.windows(b) }
            add(.amazon) { AmazonReader.windows(b) }
            add(.ea) { EAReader.windows(b) }
            out += b.programs(excluding: out)   // what else the bottle has in its Start menu (or Whisky pins)
        }
        // Mac apps last: a launcher's game app is named by its launcher above
        let known = Set(out.compactMap(\.app)) .union(out.compactMap(\.folder))
        out += MacGamesReader.read(p, enabled: enabled, known: known)
        var seen = Set<String>(), unique: [ExternalGame] = []
        // a launcher's record can outlive the game (uninstalled by hand, a library on a drive that is not plugged in): only what is on disk is on the shelf
        func onDisk(_ g: ExternalGame) -> Bool { (g.folder ?? g.app).map { exists(URL(fileURLWithPath: $0)) } ?? true }
        for g in out where onDisk(g) && seen.insert(g.id).inserted { unique.append(g) }
        return unique
    }
}

// MARK: files

func readJSON(_ u: URL) -> Any? { (try? Data(contentsOf: u)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
func children(_ u: URL) -> [URL] { (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [] }
func date(_ s: Any?) -> Date? {
    guard let t = (s as? Double) ?? (s as? Int).map(Double.init) ?? (s as? String).flatMap(Double.init), t > 0 else { return nil }
    return Date(timeIntervalSince1970: t)
}

/// Rows of a SQLite query (read only); [] when the file is missing or the query fails
func sqlite(_ u: URL, _ sql: String) -> [[String: String]] {
    var db: OpaquePointer?
    guard exists(u), sqlite3_open_v2(u.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(st) }
    var rows: [[String: String]] = []
    while sqlite3_step(st) == SQLITE_ROW {
        var r: [String: String] = [:]
        for i in 0..<sqlite3_column_count(st) {
            if let c = sqlite3_column_text(st, i) { r[String(cString: sqlite3_column_name(st, i))] = String(cString: c) }
        }
        rows.append(r)
    }
    return rows
}

// MARK: Valve's KeyValues text (.vdf, .acf)

enum VDF {
    /// The file as nested dictionaries, keys lower-cased (Steam writes "apps" and "Apps" in different files)
    static func parse(_ text: String) -> [String: Any] {
        var tokens: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                var s = "", j = text.index(after: i)
                while j < text.endIndex, text[j] != "\"" {
                    if text[j] == "\\", text.index(after: j) < text.endIndex { j = text.index(after: j) }
                    s.append(text[j]); j = text.index(after: j)
                }
                tokens.append(s); i = j < text.endIndex ? text.index(after: j) : j
            } else if c == "{" || c == "}" { tokens.append(String(c)); i = text.index(after: i) }
            else if c == "/", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "/" {
                while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
            } else { i = text.index(after: i) }
        }
        var k = 0
        func block() -> [String: Any] {
            var d: [String: Any] = [:]
            while k < tokens.count {
                let key = tokens[k]; k += 1
                if key == "}" { return d }
                guard k < tokens.count else { break }
                if tokens[k] == "{" { k += 1; d[key.lowercased()] = block() } else { d[key.lowercased()] = tokens[k]; k += 1 }
            }
            return d
        }
        return block()
    }
    static func path(_ d: [String: Any], _ keys: String...) -> Any? {
        var cur: Any? = d
        for k in keys { cur = (cur as? [String: Any])?[k] }
        return cur
    }
}

// MARK: Windows inside a bottle

/// A CrossOver or Whisky bottle: its drives (dosdevices, or drive_c alone) and its registry (system.reg, user.reg)
struct WinRoot {
    let name: String
    let dir: URL
    let runtime: Store          // .crossover or .whisky
    let cxstart: String

    /// A Windows path's place on the Mac: its drive letter through dosdevices (c: is drive_c), case kept as written (APFS ignores it)
    func mac(_ win: String) -> URL {
        let w = win.replacingOccurrences(of: "/", with: "\\")
        guard w.count >= 2, w[w.index(after: w.startIndex)] == ":" else { return dir.appendingPathComponent("drive_c").appendingPathComponent(w.replacingOccurrences(of: "\\", with: "/")) }
        let letter = w.prefix(1).lowercased()
        let rest = w.dropFirst(2).split(separator: "\\").map(String.init)
        var base = dir.appendingPathComponent("dosdevices/\(letter):")
        if !exists(base) && letter == "c" { base = dir.appendingPathComponent("drive_c") }
        return rest.reduce(base) { $0.appendingPathComponent($1) }
    }
    /// How a program in this bottle starts
    func launch(_ args: [String]) -> Launch { runtime == .whisky ? .whisky(exe: args.first ?? "") : .crossover(bottle: dir.path, args: args) }
    func launchURL(_ url: String) -> Launch { launch(["C:\\windows\\system32\\start.exe", url]) }
    func game(_ id: String, _ name: String, _ store: Store, _ launch: Launch, folder: URL?, size: Int64? = nil, last: Date? = nil) -> ExternalGame {
        ExternalGame(id: "\(id)@\(runtime.rawValue):\(self.name)", name: name, store: store, launch: launch, folder: folder?.path, bottle: self.name, runtime: runtime, size: size, lastPlayed: last)
    }

    var machine: Registry { Registry(file: dir.appendingPathComponent("system.reg")) }
    var user: Registry { Registry(file: dir.appendingPathComponent("user.reg")) }

    static func crossover(_ p: Places) -> [WinRoot] {
        p.crossoverBottleDirs.flatMap(children).filter { exists($0.appendingPathComponent("cxbottle.conf")) }
            .map { WinRoot(name: $0.lastPathComponent, dir: $0, runtime: .crossover, cxstart: p.cxstart) }
    }
    static func whisky(_ p: Places) -> [WinRoot] {
        let container = p.home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky")
        var dirs = children(container.appendingPathComponent("Bottles"))
        if let vm = NSDictionary(contentsOf: container.appendingPathComponent("BottleVM.plist")), let paths = vm["paths"] as? [Any] {
            for x in paths {
                let u = (x as? String).map { $0.hasPrefix("file:") ? URL(string: $0) : URL(fileURLWithPath: $0) } ?? (x as? [String: Any])?["relative"].flatMap { ($0 as? String).flatMap(URL.init(string:)) }
                if let u = u ?? nil, !dirs.contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) { dirs.append(u) }
            }
        }
        return dirs.filter { exists($0.appendingPathComponent("drive_c")) }.map { b in
            let meta = NSDictionary(contentsOf: b.appendingPathComponent("Metadata.plist"))
            let name = ((meta?["info"] as? [String: Any])?["name"] as? String) ?? (meta?["name"] as? String) ?? b.lastPathComponent
            return WinRoot(name: name, dir: b, runtime: .whisky, cxstart: "")
        }
    }

    /// The bottle's own programs that no launcher reader claimed: CrossOver's Start menu entries, Whisky's pins. Launchers, uninstallers and help links are left out
    func programs(excluding found: [ExternalGame]) -> [ExternalGame] {
        let skip = ["uninstall", "steam", "battle.net", "epic games launcher", "gog galaxy", "ubisoft connect", "uplay", "ea app", "origin", "amazon games", "help", "readme",
                    "manual", "support", "website", "license", "settings", "config", "launcher", "itch", "redist", "directx", "vcredist", "documentation"]
        let claimed = Set(found.filter { $0.bottle == name }.map { $0.name.lowercased() })
        var out: [ExternalGame] = []
        if runtime == .crossover, let text = try? String(contentsOf: dir.appendingPathComponent("cxmenu.conf"), encoding: .utf8) {
            var seen = Set<String>()
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("[StartMenu.") && line.hasSuffix(".lnk]") {
                let section = String(line.dropFirst(1).dropLast(1).dropFirst("StartMenu.".count))
                let win = WinRoot.menuPath(section)
                let title = (win.split(separator: "\\").last.map(String.init) ?? win).replacingOccurrences(of: ".lnk", with: "")
                let low = title.lowercased()
                guard !skip.contains(where: { low.contains($0) }), !claimed.contains(low), seen.insert(low).inserted else { continue }
                out.append(game("lnk:\(low)", title, .crossover, launch(["C:\\windows\\system32\\start.exe", win]), folder: nil))
            }
        }
        if runtime == .whisky, let meta = NSDictionary(contentsOf: dir.appendingPathComponent("Metadata.plist")), let pins = ((meta["info"] as? [String: Any])?["pins"] ?? meta["pins"]) as? [[String: Any]] {   // Whisky: info.pins (BottleSettings.swift)
            for pin in pins {
                guard let title = pin["name"] as? String, let u = (pin["url"] as? String) ?? ((pin["url"] as? [String: Any])?["relative"] as? String) else { continue }
                let path = u.hasPrefix("file://") ? (URL(string: u)?.path ?? u) : u
                guard !skip.contains(where: { title.lowercased().contains($0) }), !claimed.contains(title.lowercased()) else { continue }
                out.append(game("pin:\(title.lowercased())", title, .whisky, .whisky(exe: path), folder: URL(fileURLWithPath: path).deletingLastPathComponent()))
            }
        }
        return out
    }
    /// cxmenu.conf names an entry by its Windows path: the folder part with ^XX for a byte, _ for \ and + for a space, then / and the rest of the path
    static func menuPath(_ s: String) -> String {
        let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
        var head = "", i = parts[0].startIndex
        let h = parts[0]
        while i < h.endIndex {
            let c = h[i]
            if c == "^", let j = h.index(i, offsetBy: 3, limitedBy: h.endIndex), let b = UInt8(h[h.index(after: i)..<j], radix: 16) { head.append(Character(UnicodeScalar(b))); i = j; continue }
            head.append(c == "_" ? "\\" : c == "+" ? " " : c); i = h.index(after: i)
        }
        return parts.count > 1 ? head + "\\" + parts[1].replacingOccurrences(of: "/", with: "\\") : head
    }
}

/// Wine's registry files (system.reg for HKEY_LOCAL_MACHINE, user.reg for HKEY_CURRENT_USER): [key] lines, then "name"="value" lines; keys and names compare without case
struct Registry {
    let keys: [String: [String: String]]
    init(file: URL) {
        var k: [String: [String: String]] = [:]
        var cur: String?
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) ?? ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                guard let end = line.lastIndex(of: "]") else { continue }
                cur = Registry.unescape(String(line[line.index(after: line.startIndex)..<end])).lowercased()
                if let c = cur, k[c] == nil { k[c] = [:] }
            } else if let c = cur, line.hasPrefix("\""), let eq = line.range(of: "\"=") {
                let name = Registry.unescape(String(line[line.index(after: line.startIndex)..<eq.lowerBound])).lowercased()
                var v = String(line[eq.upperBound...])
                if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = Registry.unescape(String(v.dropFirst().dropLast())) }
                else if v.hasPrefix("dword:") { v = String(UInt32(v.dropFirst(6), radix: 16) ?? 0) }
                k[c]?[name] = v
            } else if let c = cur, line.hasPrefix("@=\"") && line.hasSuffix("\"") {
                k[c]?[""] = Registry.unescape(String(line.dropFirst(3).dropLast()))
            }
        }
        keys = k
    }
    static func unescape(_ s: String) -> String { s.replacingOccurrences(of: "\\\\", with: "\u{0}").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\u{0}", with: "\\") }
    /// The subkeys right under a key (with their values), looked for with and without Wow6432Node
    func subkeys(_ key: String) -> [(String, [String: String])] {
        var out: [(String, [String: String])] = []
        for base in [key, key.replacingOccurrences(of: "software\\", with: "software\\wow6432node\\", options: .caseInsensitive)] {
            let prefix = base.lowercased() + "\\"
            for (k, v) in keys where k.hasPrefix(prefix) && !k.dropFirst(prefix.count).contains("\\") { out.append((String(k.dropFirst(prefix.count)), v)) }
        }
        return out
    }
    func value(_ key: String, _ name: String) -> String? { keys[key.lowercased()]?[name.lowercased()] }
}

// MARK: Steam

enum SteamReader {
    /// Steam's own tools and runtimes, which it installs like games
    static let notGames: Set<Int> = [228980, 1070560, 1391110, 1628350, 1493710, 2180100, 250820, 1826330, 2348590]

    static func mac(_ p: Places) -> [ExternalGame] {
        let root = p.support.appendingPathComponent("Steam")
        let usage = playUsage(root.appendingPathComponent("userdata"))
        return games(libraryfolders: root.appendingPathComponent("steamapps/libraryfolders.vdf"), mapPath: { URL(fileURLWithPath: $0) }) { id, name, folder, st in
            // a game Steam can only run through its Windows layer is left out: the Mac game holds an app
            guard let app = firstApp(in: folder) else { return nil }
            let u = usage[id]
            return ExternalGame(id: "steam:\(id)", name: name, store: .steam, launch: .url("steam://rungameid/\(id)"), app: app.path, folder: folder.path,
                                size: Int64(st["sizeondisk"] as? String ?? ""), lastPlayed: u?.last ?? date(st["lastplayed"]), seconds: u?.seconds)
        }
    }

    static func windows(_ b: WinRoot) -> [ExternalGame] {
        let steamDir = b.user.value("Software\\Valve\\Steam", "SteamPath").map { $0.replacingOccurrences(of: "/", with: "\\") } ?? "C:\\Program Files (x86)\\Steam"
        let exe = steamDir + "\\steam.exe"
        let usage = playUsage(b.mac(steamDir + "\\userdata"))
        return games(libraryfolders: b.mac(steamDir + "\\steamapps\\libraryfolders.vdf"), mapPath: { b.mac($0) }) { id, name, folder, st in
            let u = usage[id]
            return b.game("steam:\(id)", name, .steam, b.launch([exe, "-silent", "steam://rungameid/\(id)"]), folder: folder,
                          size: Int64(st["sizeondisk"] as? String ?? ""), last: u?.last ?? date(st["lastplayed"]))
        }
    }

    /// Each installed app (StateFlags bit 4) of every library folder the file lists, made into a game by `make` (nil leaves it out)
    static func games(libraryfolders: URL, mapPath: (String) -> URL, make: (Int, String, URL, [String: Any]) -> ExternalGame?) -> [ExternalGame] {
        guard let lf = try? String(contentsOf: libraryfolders, encoding: .utf8) else { return [] }
        let top = (VDF.parse(lf)["libraryfolders"] as? [String: Any]) ?? [:]
        // old files list a library as a bare path ("1" "D:\\Games"), newer ones as a block with "path"
        let paths = top.values.compactMap { ($0 as? [String: Any])?["path"] as? String ?? ($0 as? String).flatMap { $0.contains("\\") || $0.contains("/") ? $0 : nil } }
        var out: [ExternalGame] = []
        for path in Set(paths) {
            let apps = mapPath(path).appendingPathComponent("steamapps")
            for f in children(apps) where f.lastPathComponent.hasPrefix("appmanifest_") && f.pathExtension == "acf" {
                guard let t = try? String(contentsOf: f, encoding: .utf8), let st = VDF.parse(t)["appstate"] as? [String: Any],
                      let id = Int(st["appid"] as? String ?? ""), !notGames.contains(id), (Int(st["stateflags"] as? String ?? "0") ?? 0) & 4 != 0,
                      let name = st["name"] as? String, let dir = st["installdir"] as? String else { continue }
                if let g = make(id, name, apps.appendingPathComponent("common").appendingPathComponent(dir), st) { out.append(g) }
            }
        }
        return out
    }
    static func firstApp(in folder: URL) -> URL? {
        let top = children(folder)
        if let a = top.first(where: { $0.pathExtension == "app" }) { return a }
        for d in top where d.hasDirectoryPath && d.pathExtension != "app" {
            if let a = children(d).first(where: { $0.pathExtension == "app" }) { return a }
        }
        return nil
    }
    /// Each app's play time and last play, from the account that played it last (several accounts can share a Mac)
    static func playUsage(_ userdata: URL) -> [Int: (last: Date?, seconds: Double)] {
        var best: [Int: (last: Date?, seconds: Double)] = [:]
        for user in children(userdata) {
            guard let t = try? String(contentsOf: user.appendingPathComponent("config/localconfig.vdf"), encoding: .utf8) else { continue }
            let apps = (VDF.path(VDF.parse(t), "userlocalconfigstore", "software", "valve", "steam", "apps") as? [String: Any]) ?? [:]
            for (k, v) in apps {
                guard let id = Int(k), let a = v as? [String: Any] else { continue }
                let last = date(a["lastplayed"]), mins = Double(a["playtime"] as? String ?? "") ?? 0
                if last == nil && mins == 0 { continue }
                if let b = best[id], (b.last ?? .distantPast) >= (last ?? .distantPast) { continue }
                best[id] = (last, mins * 60)
            }
        }
        return best
    }
}

// MARK: Battle.net

enum BattleNetReader {
    static func mac(_ p: Places) -> [ExternalGame] {
        let app = p.applications.map { $0.appendingPathComponent("Battle.net.app") }.first(where: exists)?.path ?? "/Applications/Battle.net.app"
        var last: [String: Date] = [:]
        if let j = readJSON(p.support.appendingPathComponent("Battle.net/Battle.net.config")) as? [String: Any], let games = j["Games"] as? [String: Any] {
            for (uid, v) in games { if let d = date((v as? [String: Any])?["LastPlayed"]) { last[uid] = d } }
        }
        return installs(p.shared.appendingPathComponent("Battle.net/Agent/product.db")).compactMap { i in
            let folder = URL(fileURLWithPath: i.path)
            guard exists(folder) else { return nil }
            return ExternalGame(id: "bnet:\(i.uid)", name: title(i, folder), store: .battlenet,
                                // Battle.net's own binary, not `open -a`: a running Battle.net ignores the arguments of `open` and only comes forward, while a second
                                // start of its binary hands the command to the running one (and starts it when it is not)
                                launch: .process(app + "/Contents/MacOS/Battle.net", ["--exec=launch \(launchCode(i))"]),
                                app: gameApp(in: folder)?.path, folder: folder.path, lastPlayed: last[i.uid])
        }
    }
    static func windows(_ b: WinRoot) -> [ExternalGame] {
        let exe = "C:\\Program Files (x86)\\Battle.net\\Battle.net.exe"
        return installs(b.mac("C:\\ProgramData\\Battle.net\\Agent\\product.db")).compactMap { i in
            let folder = b.mac(i.path)
            guard exists(folder) else { return nil }
            return b.game("bnet:\(i.uid)", title(i, folder), .battlenet, b.launch([exe, "--exec=launch \(launchCode(i))"]), folder: folder)
        }
    }
    /// The install's folder name ("World of Warcraft"), with a known flavour when several share it
    static func title(_ i: Install, _ folder: URL) -> String {
        let flavours = ["wow_classic": " Classic", "wow_classic_era": " Classic Era", "wowt": " PTR", "wow_beta": " Beta"]
        return folder.lastPathComponent + (flavours[i.uid] ?? "")
    }
    static func gameApp(in folder: URL) -> URL? {
        let top = children(folder)
        let isLauncher = { (u: URL) in u.lastPathComponent.localizedCaseInsensitiveContains("launcher") || u.lastPathComponent.localizedCaseInsensitiveContains("uninstall") }
        if let a = top.first(where: { $0.pathExtension == "app" && !isLauncher($0) }) { return a }
        for d in top where d.hasDirectoryPath && d.lastPathComponent.hasPrefix("_") {
            if let a = children(d).first(where: { $0.pathExtension == "app" && !isLauncher($0) }) { return a }
        }
        return nil
    }

    struct Install { var uid = "", code = "", path = "" }
    /// What Battle.net's `--exec="launch <code>"` takes: the product's code, not the install's uid (given "wowf", Battle.net only selects World of Warcraft;
    /// its log names the product WoWF). product.db keeps the uid in lower case for both, so the codes are Battle.net's own, as its logs and Blizzard's launch
    /// shortcuts spell them; another uid passes as product.db has it
    static func launchCode(_ i: Install) -> String {
        // Playnite's table (BattleNetLibrary/BattleNetGames.cs: uid → product code), and World of Warcraft's other editions as Battle.net's log names them
        let known = ["wow": "WoW", "wowt": "WoWPTR", "wowf": "WoWF", "wow_classic": "WoWC", "wow_classic_era": "WoWClassic", "wow_beta": "WoWX",
                     "diablo3": "D3", "s2": "S2", "s1": "S1", "hs_beta": "WTCG", "heroes": "Hero", "prometheus": "Pro", "viper": "VIPR", "odin": "ODIN",
                     "w3": "W3", "lazarus": "LAZR", "zeus": "ZEUS", "wlby": "WLBY", "osi": "OSI", "rtro": "RTRO", "fore": "FORE", "anbs": "ANBS", "auks": "AUKS",
                     "fen": "Fen", "fenris": "Fen", "d1": "D1", "w1r": "W1R", "w2r": "W2R", "w1": "W1", "w2": "W2", "gryphon": "GRY", "aris": "ARIS",
                     "scorpio": "SCOR", "arkansas": "ARK", "libra": "LBRA", "pinta": "PNTA", "aqua": "AQUA"]
        return known[i.uid.lowercased()] ?? (i.code.isEmpty ? i.uid : i.code)
    }
    /// product.db: field 1 is each install (uid 1, product code 2, settings 3 whose field 1 is the install path); Battle.net and its agent are not games
    static func installs(_ u: URL) -> [Install] {
        guard let d = try? Data(contentsOf: u) else { return [] }
        var out: [Install] = [], seen = Set<String>()
        for (f, v) in fields([UInt8](d)[...]) where f == 1 {
            guard case .bytes(let m) = v else { continue }
            var i = Install()
            for (g, w) in fields(m) {
                guard case .bytes(let s) = w else { continue }
                switch g {
                case 1: i.uid = String(decoding: s, as: UTF8.self)
                case 2: i.code = String(decoding: s, as: UTF8.self)
                case 3: for (h, x) in fields(s) where h == 1 { if case .bytes(let p) = x { i.path = String(decoding: p, as: UTF8.self) } }
                default: break
                }
            }
            guard !["battle.net", "agent", "bna", ""].contains(i.uid), !i.path.isEmpty, seen.insert(i.uid).inserted else { continue }
            out.append(i)
        }
        return out
    }
    enum Wire { case varint(UInt64), bytes(ArraySlice<UInt8>) }
    static func fields(_ b: ArraySlice<UInt8>) -> [(Int, Wire)] {
        var out: [(Int, Wire)] = [], i = b.startIndex
        func varint() -> UInt64? {
            var v: UInt64 = 0, s: UInt64 = 0
            while i < b.endIndex { let c = b[i]; i += 1; v |= UInt64(c & 0x7f) << s; if c & 0x80 == 0 { return v }; s += 7; if s > 63 { return nil } }
            return nil
        }
        while i < b.endIndex {
            guard let key = varint() else { break }
            let f = Int(key >> 3)
            switch key & 7 {
            case 0: guard let v = varint() else { return out }; out.append((f, .varint(v)))
            case 1: i += 8
            case 2: guard let n = varint(), n <= UInt64(b.endIndex - i) else { return out }; out.append((f, .bytes(b[i..<(i + Int(n))]))); i += Int(n)
            case 5: i += 4
            default: return out
            }
        }
        return out
    }
}

// MARK: Epic

enum EpicReader {
    /// Each manifest of a finished install that is a game (not Unreal Engine or a plug-in), started through the launcher's link so its sign-in and cloud saves apply
    static func read(manifests dir: URL, root: WinRoot?) -> [ExternalGame] {
        children(dir).filter { $0.pathExtension.lowercased() == "item" }.compactMap { f in
            guard let m = readJSON(f) as? [String: Any], let name = m["DisplayName"] as? String, let appName = m["AppName"] as? String,
                  (m["bIsIncompleteInstall"] as? Bool) != true else { return nil }
            // what is not a game, by the rules Playnite has used on these manifests for years (EpicLibrary.cs): an add-on that cannot be launched, a plug-in,
            // Unreal Engine and its plug-ins
            let cats = (m["AppCategories"] as? [String] ?? []).map { $0.lowercased() }
            if cats.contains(where: { $0.hasPrefix("addons") }) && !cats.contains("addons/launchable") { return nil }
            if cats.contains("plugins") || cats.contains("plugins/engine") { return nil }
            if (m["CompatibleApps"] as? [String] ?? []).contains(where: { $0.hasPrefix("UE_") }) { return nil }
            if (m["TechnicalType"] as? String ?? "").contains("plugins/engine") || appName.hasPrefix("UE_") { return nil }
            let ns = m["CatalogNamespace"] as? String ?? "", item = m["CatalogItemId"] as? String ?? ""
            let link = "com.epicgames.launcher://apps/\(ns)%3A\(item)%3A\(appName)?action=launch&silent=true"
            let loc = m["InstallLocation"] as? String ?? ""
            let size = (m["InstallSize"] as? NSNumber)?.int64Value
            if let b = root { return b.game("epic:\(appName)", name, .epic, b.launchURL(link), folder: b.mac(loc), size: size) }
            let folder = URL(fileURLWithPath: loc)
            let exe = m["LaunchExecutable"] as? String ?? ""
            let app = exe.contains(".app") ? folder.appendingPathComponent(String(exe[..<exe.range(of: ".app")!.upperBound])) : SteamReader.firstApp(in: folder)
            return ExternalGame(id: "epic:\(appName)", name: name, store: .epic, launch: .url(link), app: app?.path, folder: folder.path, size: size)
        }
    }
}

// MARK: GOG

enum GOGReader {
    /// GOG games are free of DRM: each starts by its own program, Galaxy or not
    static func windows(_ b: WinRoot) -> [ExternalGame] {
        var out = b.machine.subkeys("Software\\GOG.com\\Games").compactMap { id, v -> ExternalGame? in
            guard let name = v["gamename"], let path = v["path"], let exe = v["exe"] ?? v["launchcommand"] else { return nil }
            return b.game("gog:\(v["gameid"] ?? id)", name, .gog, b.launch([exe.replacingOccurrences(of: "\"", with: "")]), folder: b.mac(path))
        }
        let have = Set(out.map(\.id))
        for (key, v) in b.machine.subkeys("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall") where key.hasSuffix("_is1") && v["publisher"] == "GOG.com" {
            let id = String(key.dropLast(4))
            guard id.allSatisfy(\.isNumber), let name = v["displayname"], let path = v["installlocation"] else { continue }
            let folder = b.mac(path)
            guard let j = readJSON(folder.appendingPathComponent("goggame-\(id).info")) as? [String: Any], let tasks = j["playTasks"] as? [[String: Any]],
                  let task = tasks.first(where: { ($0["isPrimary"] as? Bool) == true }) ?? tasks.first, let rel = task["path"] as? String else { continue }
            let g = b.game("gog:\(id)", name, .gog, b.launch([path.hasSuffix("\\") ? path + rel : path + "\\" + rel]), folder: folder)
            if !have.contains(g.id) { out.append(g) }
        }
        return out
    }
    /// A Mac GOG game: its app holds goggame-<id>.info (JSON: gameId, name)
    static func info(_ app: URL) -> (id: String, name: String)? {
        for dir in [app.appendingPathComponent("Contents/Resources"), app.deletingLastPathComponent()] {
            for f in children(dir) where f.lastPathComponent.hasPrefix("goggame-") && f.pathExtension == "info" {
                if let j = readJSON(f) as? [String: Any], let name = j["name"] as? String { return ((j["gameId"] as? String) ?? String(describing: j["gameId"] ?? ""), name) }
            }
        }
        return nil
    }
}

// MARK: Heroic (Epic, GOG and Amazon on the Mac)

enum HeroicReader {
    static func read(_ p: Places) -> [ExternalGame] {
        let root = p.support.appendingPathComponent("heroic")
        guard exists(root) else { return [] }
        var out: [ExternalGame] = []
        func link(_ app: String, _ runner: String) -> Launch { .url("heroic://launch?appName=\(app)&runner=\(runner)") }
        // Epic, through legendary: { appName: { title, install_path, platform } }
        for file in ["installed.json", "third-party-installed.json"] {
            guard let j = readJSON(root.appendingPathComponent("legendaryConfig/legendary/\(file)")) as? [String: [String: Any]] else { continue }
            for (app, v) in j { if let t = v["title"] as? String { out.append(ExternalGame(id: "epic:\(app)", name: t, store: .epic, launch: link(app, "legendary"), folder: v["install_path"] as? String, runtime: .heroic)) } }
        }
        // GOG: { installed: [ { appName, install_path, platform } ] }, titles in the store's library cache
        var gogTitles: [String: String] = [:]
        if let lib = readJSON(root.appendingPathComponent("store_cache/gog_library.json")) as? [String: Any], let games = lib["games"] as? [[String: Any]] {
            for g in games { if let a = g["app_name"] as? String, let t = g["title"] as? String { gogTitles[a] = t } }
        }
        if let j = readJSON(root.appendingPathComponent("gog_store/installed.json")) as? [String: Any], let list = j["installed"] as? [[String: Any]] {
            for v in list {
                guard let app = v["appName"] as? String, let path = v["install_path"] as? String else { continue }
                out.append(ExternalGame(id: "gog:\(app)", name: gogTitles[app] ?? URL(fileURLWithPath: path).lastPathComponent, store: .gog, launch: link(app, "gog"), folder: path, runtime: .heroic))
            }
        }
        // Amazon, through nile: [ { id, path } ]
        var nileTitles: [String: String] = [:]
        if let lib = readJSON(root.appendingPathComponent("nile_config/nile/library.json")) as? [[String: Any]] {
            for g in lib { if let p = g["product"] as? [String: Any], let a = p["id"] as? String, let t = p["title"] as? String { nileTitles[a] = t } }
        }
        if let list = readJSON(root.appendingPathComponent("nile_config/nile/installed.json")) as? [[String: Any]] {
            for v in list {
                guard let app = v["id"] as? String, let path = v["path"] as? String else { continue }
                out.append(ExternalGame(id: "amazon:\(app)", name: nileTitles[app] ?? URL(fileURLWithPath: path).lastPathComponent, store: .amazon, launch: link(app, "nile"), folder: path, runtime: .heroic))
            }
        }
        // games added by hand: { games: [ { app_name, title, is_installed } ] }
        if let j = readJSON(root.appendingPathComponent("sideload_apps/library.json")) as? [String: Any], let list = j["games"] as? [[String: Any]] {
            for v in list where (v["is_installed"] as? Bool) != false {
                guard let app = v["app_name"] as? String, let t = v["title"] as? String else { continue }
                out.append(ExternalGame(id: "heroic:\(app)", name: t, store: .heroic, launch: link(app, "sideload"), runtime: .heroic))
            }
        }
        return out
    }
}

// MARK: itch

enum ItchReader {
    static func read(_ p: Places) -> [ExternalGame] {
        let db = p.support.appendingPathComponent("itch/db/butler.db")
        return sqlite(db, """
            SELECT caves.id AS cave, games.id AS game, games.title AS title, install_locations.path AS root, caves.install_folder_name AS dir, caves.last_touched_at AS last, caves.seconds_run AS secs
            FROM caves JOIN games ON games.id = caves.game_id LEFT JOIN install_locations ON install_locations.id = caves.install_location_id
            """).compactMap { r in
            guard let cave = r["cave"], let title = r["title"] else { return nil }
            let folder = r["root"].map { URL(fileURLWithPath: $0).appendingPathComponent(r["dir"] ?? "").path }
            let last = r["last"].flatMap { ISO8601DateFormatter().date(from: $0) }
            return ExternalGame(id: "itch:\(cave)", name: title, store: .itch, launch: .url("itch://install?game_id=\(r["game"] ?? "")&launch"), folder: folder,
                                lastPlayed: last, seconds: r["secs"].flatMap(Double.init))
        }
    }
}

// MARK: Ubisoft and Amazon, in bottles

enum UbisoftReader {
    static func windows(_ b: WinRoot) -> [ExternalGame] {
        b.machine.subkeys("Software\\Ubisoft\\Launcher\\Installs").compactMap { id, v in
            guard let dir = v["installdir"] else { return nil }
            let folder = b.mac(dir)
            guard exists(folder) else { return nil }
            return b.game("ubisoft:\(id)", folder.lastPathComponent, .ubisoft, b.launchURL("uplay://launch/\(id)/0"), folder: folder)
        }
    }
}

/// The EA app installs each game in Program Files\EA Games\<game>, whose __Installer\installerdata.xml names its offer (<contentIDs><contentID>, the first),
/// and starts one by origin2://game/launch?offerIds=… (as Lutris does, lutris/services/ea_app.py)
enum EAReader {
    static func windows(_ b: WinRoot) -> [ExternalGame] {
        ["C:\\Program Files\\EA Games", "C:\\Program Files (x86)\\EA Games"].flatMap { children(b.mac($0)) }.compactMap { folder -> ExternalGame? in
            guard let xml = try? String(contentsOf: folder.appendingPathComponent("__Installer/installerdata.xml"), encoding: .utf8),
                  let a = xml.range(of: "<contentID>"), let z = xml.range(of: "</contentID>", range: a.upperBound..<xml.endIndex) else { return nil }
            let offer = xml[a.upperBound..<z.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !offer.isEmpty, let q = offer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return b.game("ea:\(offer)", folder.lastPathComponent, .ea, b.launchURL("origin2://game/launch?offerIds=\(q)&autoDownload=1"), folder: folder)
        }
    }
}

enum AmazonReader {
    static func windows(_ b: WinRoot) -> [ExternalGame] {
        children(b.mac("C:\\users")).flatMap { user in
            sqlite(user.appendingPathComponent("AppData/Local/Amazon Games/Data/Games/Sql/GameInstallInfo.sqlite"),
                   "SELECT Id, ProductTitle, InstallDirectory FROM DbSet WHERE Installed = 1").compactMap { r -> ExternalGame? in
                guard let id = r["Id"], let t = r["ProductTitle"] else { return nil }
                return b.game("amazon:\(id)", t, .amazon, b.launchURL("amazon-games://play/\(id)"), folder: r["InstallDirectory"].map { b.mac($0) })
            }
        }
    }
}

// MARK: other Mac games (App Store, GOG, any game app)

enum MacGamesReader {
    /// Launchers and tools that file themselves under games
    static let notGames: Set<String> = ["com.valvesoftware.steam", "net.battle.app", "net.battle.bootstrapper", "com.codeweavers.CrossOver", "org.nxnative.launcher",
                                        "com.apple.Chess", "com.epicgames.EpicGamesLauncher", "com.gog.galaxy", "com.isaacmarovitz.Whisky", "com.apple.games",
                                        "com.heroicgameslauncher.hgl", "io.itch.mac", "com.blizzard.worldofwarcraft.launcher"]
    static func read(_ p: Places, enabled: Set<Store>, known: Set<String>) -> [ExternalGame] {
        var out: [ExternalGame] = []
        let fm = FileManager.default
        for root in p.applications {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                guard u.pathExtension == "app" else { continue }
                e.skipDescendants()
                let path = u.standardizedFileURL.path
                guard !known.contains(path), !known.contains(where: { path.hasPrefix($0 + "/") }),
                      let info = NSDictionary(contentsOf: u.appendingPathComponent("Contents/Info.plist")), info["DMTitleID"] == nil else { continue }
                if let b = info["CFBundleIdentifier"] as? String, notGames.contains(b) { continue }
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? u.deletingPathExtension().lastPathComponent
                if let gog = GOGReader.info(u) {
                    if enabled.contains(.gog) { out.append(ExternalGame(id: "gog:\(gog.id)", name: gog.name, store: .gog, launch: .app(path), app: path, folder: u.deletingLastPathComponent().path)) }
                    continue
                }
                let cat = (info["LSApplicationCategoryType"] as? String) ?? ""
                guard cat == "public.app-category.games" || (cat.hasPrefix("public.app-category.") && cat.hasSuffix("-games")) else { continue }
                let store: Store = exists(u.appendingPathComponent("Contents/_MASReceipt")) ? .appStore : .mac
                guard enabled.contains(store) else { continue }
                out.append(ExternalGame(id: "mac:\(path)", name: name, store: store, launch: .app(path), app: path))
            }
        }
        return out
    }
}
