// Mods (docs/frontends.md, Mods): folders in ~/Library/Application Support/nxnative/<title ID>/mods, and mods.txt, the ones that are on, first winning. The game's own launcher
// (dm/mac/launcher.c) turns the list into DM_ROMFS_OVERLAY at every start. A mod is installed from a folder in any of the usual layouts: the Switch SD card's
// (atmosphere/contents/<title ID>/romfs), a mod manager's (<mod>/romfs), or the game's files themselves.
import AppKit
import SwiftUI

struct Mod: Identifiable, Hashable {
    let name: String
    var on: Bool
    var hasCode: Bool   // an exefs folder: code patches, which the host does not read
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
        mods = (on.map { Mod(name: $0, on: true, hasCode: hasCode($0)) }) + off.map { Mod(name: $0, on: false, hasCode: hasCode($0)) }
    }
    private func hasCode(_ n: String) -> Bool {
        FileManager.default.fileExists(atPath: game.modsFolder.appendingPathComponent(n).appendingPathComponent("exefs").path)
    }
    func save() {
        let on = mods.filter(\.on).map(\.name)
        let text = "# Mods that are on, the first winning where two have the same file (nxnative Launcher; docs/frontends.md, Mods)\n" + on.map { $0 + "\n" }.joined()
        do {
            try FileManager.default.createDirectory(at: game.support, withIntermediateDirectories: true)
            try text.write(to: game.modsList, atomically: true, encoding: .utf8)
        } catch { message = error.localizedDescription }
    }
    func toggle(_ m: Mod) {
        guard let i = mods.firstIndex(of: m) else { return }
        mods[i].on.toggle()
        let x = mods.remove(at: i)   // on: after the others that are on; off: among the ones that are off
        let firstOff = mods.firstIndex { !$0.on } ?? mods.count
        mods.insert(x, at: x.on ? firstOff : mods.count)
        save()
    }
    func move(_ m: Mod, by d: Int) {
        guard let i = mods.firstIndex(of: m), mods.indices.contains(i + d), mods[i + d].on == m.on else { return }
        mods.swapAt(i, i + d); save()
    }

    /// The folder in a mod download that holds the game's files: …/contents/<title ID>/romfs, …/<title ID>/romfs, …/romfs, or the folder itself
    func romfsRoot(in src: URL) -> (URL, URL?) {
        let fm = FileManager.default
        func dir(_ u: URL) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue }
        let tid = game.titleID
        for base in [src.appendingPathComponent("atmosphere/contents"), src.appendingPathComponent("contents"), src] {
            for t in [tid, tid.lowercased()] {
                let r = base.appendingPathComponent(t)
                if dir(r.appendingPathComponent("romfs")) || dir(r.appendingPathComponent("exefs")) {
                    return (r.appendingPathComponent("romfs"), dir(r.appendingPathComponent("exefs")) ? r.appendingPathComponent("exefs") : nil)
                }
            }
        }
        if dir(src.appendingPathComponent("romfs")) { return (src.appendingPathComponent("romfs"), dir(src.appendingPathComponent("exefs")) ? src.appendingPathComponent("exefs") : nil) }
        return (src, nil)
    }

    func install(from src: URL) {
        let fm = FileManager.default
        var name = src.lastPathComponent.replacingOccurrences(of: ":", with: "-")
        if name == tidFolderName(src) { name = src.deletingLastPathComponent().lastPathComponent }
        var dest = game.modsFolder.appendingPathComponent(name), n = 2
        while fm.fileExists(atPath: dest.path) { dest = game.modsFolder.appendingPathComponent("\(name) \(n)"); n += 1 }
        let (romfs, exefs) = romfsRoot(in: src)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            if fm.fileExists(atPath: romfs.path) { try fm.copyItem(at: romfs, to: dest.appendingPathComponent("romfs")) }
            if let exefs { try fm.copyItem(at: exefs, to: dest.appendingPathComponent("exefs")) }
            message = exefs != nil ? "Installed \(dest.lastPathComponent). It also changes the game's code (exefs), which nxnative does not read: only its files are used." : "Installed \(dest.lastPathComponent)."
        } catch { message = "Could not install the mod: \(error.localizedDescription)" }
        reload()
        if let m = mods.first(where: { $0.name == dest.lastPathComponent }), !m.on { toggle(m) }
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
                Text("A mod replaces some of the game's files. Mods that are on are read in this order: where two have the same file, the higher one wins. Mods that change the game's code (exefs, IPS patches) are not supported. Changes take effect at the game's next start.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
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
                                if mod.hasCode { Text("Its code changes (exefs) are not used.").font(.footnote).foregroundStyle(.orange) }
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
        if p.runModal() == .OK { p.urls.forEach(m.install) }
    }
}
