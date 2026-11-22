// Mods (docs/frontends.md, Mods): folders in ~/Library/Application Support/nxnative/<title ID>/mods, and mods.txt, the ones that are on, first winning. The game's own launcher
// (dm/mac/launcher.c) turns the list into DM_ROMFS_OVERLAY (romfs/), DM_EXEFS_PATCHES (exefs/: IPS and pchtxt code patches, hle_exefs.c) and DM_AOC_OVERLAY_<index>
// (aoc/<index>/: files of a DLC) at every start. A mod is installed from a folder in any of the usual layouts: the Switch SD card's (atmosphere/contents/<title ID>/romfs
// and exefs, and contents/<DLC's ID>/romfs), a mod manager's (<mod>/romfs, <mod>/exefs), or the game's files themselves.
import AppKit
import SwiftUI

enum ModCode: Hashable {
    case none
    case patches       // IPS / pchtxt files: applied at the game's start
    case module(String) // a code module (subsdk9, main…): not loaded, and the mod's patches are left out with it (they call into it)
}

struct Mod: Identifiable, Hashable {
    let name: String
    var on: Bool
    var code: ModCode   // what its exefs folder holds
    var id: String { name }
}

final class ModsModel: ObservableObject {
    let game: Game
    @Published var mods: [Mod] = []   // in the order of priority: the ones that are on first, in mods.txt's order
    @Published var message: String?

    init(game: Game) { self.game = game; reload() }

    func reload() {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: game.modsFolder.path)) ?? []).filter { n in
            var d: ObjCBool = false
            return !n.hasPrefix(".") && fm.fileExists(atPath: game.modsFolder.appendingPathComponent(n).path, isDirectory: &d) && d.boolValue
        }
        let list = ((try? String(contentsOf: game.modsList, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let on = list.filter(names.contains)
        let off = names.filter { !on.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        mods = (on.map { Mod(name: $0, on: true, code: code($0)) }) + off.map { Mod(name: $0, on: false, code: code($0)) }
    }
    /// What the mod's exefs folder holds, as the host judges it (hle_exefs.c is_module_file)
    private func code(_ n: String) -> ModCode {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: game.modsFolder.appendingPathComponent(n).appendingPathComponent("exefs").path)) ?? []
        if let m = names.first(where: Self.isModule) { return .module(m) }
        return names.contains { $0.lowercased().hasSuffix(".ips") || $0.lowercased().hasSuffix(".pchtxt") } ? .patches : .none
    }
    static func isModule(_ n: String) -> Bool {
        let l = n.lowercased()
        if ["main", "main.npdm", "sdk", "rtld"].contains(l) { return true }
        return l.count == 7 && l.hasPrefix("subsdk") && l.last!.isNumber
    }
    func save() {
        let on = mods.filter(\.on).map(\.name)
        let text = "# Mods that are on, the first winning where two have the same file (Cartridge; docs/frontends.md, Mods)\n" + on.map { $0 + "\n" }.joined()
        do {
            try FileManager.default.createDirectory(at: game.support, withIntermediateDirectories: true)
            try text.write(to: game.modsList, atomically: true, encoding: .utf8)
        } catch { message = error.localizedDescription }
    }
    func toggle(_ m: Mod) {
        guard let i = mods.firstIndex(of: m) else { return }
        mods[i].on.toggle()
        if mods[i].on { port(m.name) }
        let x = mods.remove(at: i)   // on: after the others that are on; off: among the ones that are off
        let firstOff = mods.firstIndex { !$0.on } ?? mods.count
        mods.insert(x, at: x.on ? firstOff : mods.count)
        save()
    }
    func move(_ m: Mod, by d: Int) {
        guard let i = mods.firstIndex(of: m), mods.indices.contains(i + d), mods[i + d].on == m.on else { return }
        mods.swapAt(i, i + d); save()
    }

    /// A folder's subfolders, leaving out hidden ones and macOS's __MACOSX
    static func subdirs(_ u: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter {
            !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
    /// The folder that holds the mod: the first, breadth-first and at most 4 levels down, with romfs, exefs, atmosphere or contents in it (a download or a folder the
    /// player chose often wraps it: "<mod>/<variant>/exefs/…" as emulators' add-on folders are shipped); none: the folder itself
    static func modFolder(in src: URL) -> URL {
        func marked(_ u: URL) -> Bool { subdirs(u).contains { ["romfs", "exefs", "atmosphere", "contents"].contains($0.lastPathComponent.lowercased()) } }
        var level = [src]
        for _ in 0..<4 {
            if let u = level.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first(where: marked) { return u }
            level = level.flatMap(subdirs)
            if level.isEmpty { break }
        }
        return src
    }
    /// The folders in a mod download that hold the game's files and code patches: …/contents/<title ID>/romfs and exefs, …/<title ID>/…, …/romfs and …/exefs, or the folder
    /// itself; and the files of the game's DLCs, …/contents/<DLC's ID>/romfs, by the DLC's index (the low 12 bits of its ID)
    func romfsRoot(in src: URL) -> (URL, URL?, [Int: URL]) {
        let fm = FileManager.default
        func dir(_ u: URL) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue }
        let tid = game.titleID
        var aoc: [Int: URL] = [:]
        for base in [src.appendingPathComponent("atmosphere/contents"), src.appendingPathComponent("contents"), src] {
            for n in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where Self.isDLC(n.uppercased(), of: tid) && dir(base.appendingPathComponent(n).appendingPathComponent("romfs")) {
                aoc[Int(n.suffix(3), radix: 16)!] = base.appendingPathComponent(n).appendingPathComponent("romfs")
            }
            for t in [tid, tid.lowercased()] + (switch1TitleID.map { [$0, $0.lowercased()] } ?? []) {
                let r = base.appendingPathComponent(t)
                if dir(r.appendingPathComponent("romfs")) || dir(r.appendingPathComponent("exefs")) {
                    return (r.appendingPathComponent("romfs"), dir(r.appendingPathComponent("exefs")) ? r.appendingPathComponent("exefs") : nil, aoc)
                }
            }
            if !aoc.isEmpty { return (base.appendingPathComponent(tid).appendingPathComponent("romfs"), nil, aoc) }
        }
        let rom = src.appendingPathComponent("romfs"), exe = src.appendingPathComponent("exefs")
        if dir(rom) || dir(exe) { return (rom, dir(exe) ? exe : nil, aoc) }
        return (src, nil, aoc)
    }
    /// A DLC of the game: an ID of 16 hex digits whose digits 5 to 12 are the game's (the first byte differs between a Switch 2 Edition and the Switch game whose DLCs it
    /// reads) and whose low 12 bits, the DLC's index, are not 0
    static func isDLC(_ n: String, of tid: String) -> Bool {
        n.count == 16 && n.allSatisfy(\.isHexDigit) && n != tid && Array(n)[4..<12] == Array(tid)[4..<12] && Int(n.suffix(3), radix: 16)! != 0 && n.dropLast(3).last != tid.dropLast(3).last
    }

    /// A Switch 2 Edition (title ID 04…) also takes mods made for its Switch 1 game (01…, the last digit 0), whose files lie under that game's title ID
    var switch1TitleID: String? {
        let t = game.titleID.uppercased()
        return t.hasPrefix("04") && t.count == 16 ? "01" + t.dropFirst(2).dropLast() + "0" : nil
    }
    /// Installs a mod folder; name: the mod's name (default: the folder's), on: turned on at once (a folder the player chose) or left off (a download, Browse Mods),
    /// credit: written as the mod's SOURCE.txt (where it came from and its authors). Returns the installed mod's name
    @discardableResult func install(from src: URL, name given: String? = nil, on: Bool = true, credit: String? = nil) -> String? {
        let fm = FileManager.default
        var name = (given ?? src.lastPathComponent).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        if given == nil, name == tidFolderName(src) { name = src.deletingLastPathComponent().lastPathComponent }
        var dest = game.modsFolder.appendingPathComponent(name), n = 2
        while fm.fileExists(atPath: dest.path) { dest = game.modsFolder.appendingPathComponent("\(name) \(n)"); n += 1 }
        let (romfs, exefs, aoc) = romfsRoot(in: Self.modFolder(in: src))
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            if fm.fileExists(atPath: romfs.path) { try fm.copyItem(at: romfs, to: dest.appendingPathComponent("romfs")) }
            if let exefs { try fm.copyItem(at: exefs, to: dest.appendingPathComponent("exefs")) }
            for (i, u) in aoc {
                try fm.createDirectory(at: dest.appendingPathComponent("aoc"), withIntermediateDirectories: true)
                try fm.copyItem(at: u, to: dest.appendingPathComponent("aoc/\(i)"))
            }
            if let credit { try credit.write(to: dest.appendingPathComponent("SOURCE.txt"), atomically: true, encoding: .utf8) }
            message = "Installed \(dest.lastPathComponent)\(on ? "" : " (off: turn it on below)")."
            if case .module(let n) = code(dest.lastPathComponent) { message! += " It adds a code module (\(n)), which nxnative does not load: only its files are used." }
        } catch { message = "Could not install the mod: \(error.localizedDescription)"; reload(); return nil }
        reload()
        if on, let m = mods.first(where: { $0.name == dest.lastPathComponent }), !m.on { toggle(m) }
        return dest.lastPathComponent
    }
    /// Where a mod came from: its SOURCE.txt's lines (name, page, "by …"), for the credit under it
    func source(_ m: Mod) -> (page: URL?, by: String?)? {
        guard let t = try? String(contentsOf: game.modsFolder.appendingPathComponent(m.name).appendingPathComponent("SOURCE.txt"), encoding: .utf8) else { return nil }
        let lines = t.split(whereSeparator: \.isNewline).map(String.init)
        return (lines.first { $0.hasPrefix("https://") }.flatMap(URL.init(string:)), lines.first { $0.hasPrefix("by ") }.map { String($0.dropFirst(3)) })
    }
    /// A game whose add-on content carries newer copies of the program's files (a Switch 2 Edition's upgrade add-on: Xenoblade Chronicles: Definitive Edition's) reads
    /// those, so a Switch mod's files lie over copies the game never reads. scripts/mod_port.py carries the mod's change onto the add-on's copies (tables and key=value
    /// files) into the mod's aoc/<index>/ folder, and lists what it cannot (images, layouts); run when a mod is installed or turned on, in the background
    func port(_ name: String) {
        let aoc = game.contents.appendingPathComponent("Resources/aoc")
        guard ((try? FileManager.default.contentsOfDirectory(atPath: aoc.path)) ?? []).contains(where: { $0.hasSuffix(".img") }) else { return }
        let info = Bundle.main.infoDictionary ?? [:]   // the engine Cartridge carries, else the player's own checkout (Settings › Building)
        let repo = Engine.shared.builtIn ? (Engine.shared.installedDir?.path ?? "") : (UserDefaults.standard.string(forKey: "build.repo") ?? (info["DMRepo"] as? String ?? ""))
        let python = Engine.shared.builtIn ? (Engine.shared.python?.path ?? "/usr/bin/python3") : (UserDefaults.standard.string(forKey: "build.python") ?? (info["DMPython"] as? String ?? "/usr/bin/python3"))
        let script = repo + "/scripts/mod_port.py", folder = game.modsFolder.appendingPathComponent(name).path, app = game.url.path
        guard FileManager.default.fileExists(atPath: script) else { return }
        DispatchQueue.global(qos: .utility).async {
            let (code, out) = shell(python, [script, app, folder])
            let last = out.split(separator: "\n").last.map(String.init) ?? ""
            let r = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Int]
            DispatchQueue.main.async {
                guard code == 0, let r else { self.message = "\(name): could not be checked against this edition's files (\(last))"; return }
                let ported = r["ported"] ?? 0, bad = r["unportable"] ?? 0
                if ported > 0 && bad == 0 { self.message = "\(name): made for the Switch version; its changes were carried over to this edition's files (\(ported))." }
                else if bad > 0 { self.message = "\(name): made for the Switch version. \(bad) of its files (images or layouts) are replaced by this edition and cannot be carried over, so the mod may not work or may break the picture\(ported > 0 ? "; \(ported) others were carried over" : "")." }
            }
        }
    }
    private func tidFolderName(_ u: URL) -> String? { u.lastPathComponent.uppercased() == game.titleID ? u.lastPathComponent : nil }

    func remove(_ m: Mod) {
        do { try FileManager.default.trashItem(at: game.modsFolder.appendingPathComponent(m.name), resultingItemURL: nil) } catch { message = error.localizedDescription }
        reload(); save()
    }
}

struct ModsView: View {
    @StateObject var m: ModsModel
    init(game: Game) { _m = StateObject(wrappedValue: ModsModel(game: game)) }

    var body: some View {
        Form {
            Section {
                Text("A mod replaces some of the game's files. Mods that are on are read in this order: where two have the same file, the higher one wins. Code patches (IPS, pchtxt) of this version of the game are applied; mods that add a code module (exlaunch, skyline) are not supported. Changes take effect at the game's next start.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Browse Mods…") { ModBrowserWindow.open(for: m) }
                    Button("Add Mod Folder…") { pick() }
                    Button("Open Mods Folder") {
                        try? FileManager.default.createDirectory(at: m.game.modsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(m.game.modsFolder)
                    }
                    Button("Refresh") { m.reload() }
                }
                if let s = m.message { Text(s).font(.footnote) }
            }
            Section("Mods") {
                if m.mods.isEmpty { Text("No mods installed.").foregroundStyle(.secondary) }
                ForEach(m.mods) { mod in
                    HStack {
                        Toggle(isOn: Binding(get: { mod.on }, set: { _ in m.toggle(mod) })) {
                            VStack(alignment: .leading) {
                                Text(mod.name)
                                if let src = m.source(mod), src.by != nil || src.page != nil {
                                    HStack(spacing: 4) {
                                        if let by = src.by { Text("by \(by)") }
                                        if let page = src.page { Link("GameBanana", destination: page) }
                                    }.font(.footnote).foregroundStyle(.secondary)
                                }
                                switch mod.code {
                                case .none: EmptyView()
                                case .patches: Text("Changes the game's code (exefs patches).").font(.footnote).foregroundStyle(.secondary)
                                case .module(let n): Text("Adds a code module (\(n)), which nxnative does not load: only its files are used.").font(.footnote).foregroundStyle(.orange)
                                }
                            }
                        }
                        Spacer()
                        if mod.on {
                            Button { m.move(mod, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).help("Higher priority")
                            Button { m.move(mod, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).help("Lower priority")
                        }
                        Button { m.remove(mod) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Move to the Trash")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers { _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { m.install(from: u) } } } }
            return true
        }
    }
    private func pick() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.message = "Choose a mod's folder (an SD card's atmosphere folder, a folder with romfs in it, or the game's files)"
        if p.runModal() == .OK { p.urls.forEach { m.install(from: $0) } }
    }
}
