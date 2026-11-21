// Cheats (docs/frontends.md, Cheats): Atmosphère cheat files in ~/Library/Application Support/nxnative/<title ID>/cheats, flat (<build ID>.txt) or in an SD card's tree, and
// beside each one <build ID>.enabled, the cheats that are on, one name per line (a duplicate name's later entries "Name #2", …). The host (dm/host/hle_cheats.c) reads them at
// the start and on Reload cheats (⌘R in the game); this page writes them before the start. Masters ({Name}) are always on and labels (entries with no code) never: neither is listed.
import AppKit
import SwiftUI

struct Cheat: Identifiable, Hashable {
    let key: String      // its line in .enabled
    let name: String
    let section: String
    var on: Bool
    var id: String { key }
}

final class CheatsModel: ObservableObject {
    let game: Game
    let buildID: String?
    @Published var file: URL?
    @Published var cheats: [Cheat] = []
    @Published var masterOff = false
    @Published var others: [String] = []   // build IDs of files for other versions of the game
    @Published var message: String?
    @Published var finder: FinderState = .idle   // Find Cheats (CheatFinder.swift)

    init(game: Game) { self.game = game; buildID = game.buildID; reload() }

    private var enabledFile: URL? { file.map { $0.deletingPathExtension().appendingPathExtension("enabled") } }
    private var offFlag: URL { game.cheatsFolder.appendingPathComponent(".cheats-off-\(game.titleID)") }

    /// The running build's file, as the host looks for it: flat first, then the SD card trees (with and without atmosphere/)
    private func findFile() -> URL? {
        guard let b = buildID else { return nil }
        let fm = FileManager.default, root = game.cheatsFolder
        let dirs = [root] + ["atmosphere/contents", "contents"].flatMap { base in [game.titleID, game.titleID.lowercased()].map { root.appendingPathComponent("\(base)/\($0)/cheats") } }
        for d in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
            if let n = names.first(where: { $0.lowercased() == "\(b.lowercased()).txt" }) { return d.appendingPathComponent(n) }
        }
        return nil
    }

    func reload() {
        file = findFile()
        masterOff = FileManager.default.fileExists(atPath: offFlag.path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: game.cheatsFolder.path)) ?? []
        others = names.compactMap { n in
            let u = n.uppercased()
            guard u.hasSuffix(".TXT"), u.count == 20, u.prefix(16).allSatisfy(\.isHexDigit), String(u.prefix(16)) != buildID else { return nil }
            return String(u.prefix(16))
        }
        guard let file, let data = try? Data(contentsOf: file) else { cheats = []; return }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) ?? String(decoding: data, as: UTF8.self)
        let on = Set(((try? String(contentsOf: enabledFile!, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init))
        cheats = Self.parse(text).map { Cheat(key: $0.key, name: $0.name, section: $0.section, on: on.contains($0.key)) }
    }

    /// The toggleable cheats of a file, keyed as the host keys them (hle_cheats.c parse_file): every [Name] / {Name} header is an entry, labels and section markers
    /// included, and a name's later entries are "Name #2", …; a cheat is an entry with code words that is not the master. [--SectionStart:X--] sets the section of the entries after it
    static func parse(_ text: String) -> [(key: String, name: String, section: String)] {
        var out: [(key: String, name: String, section: String)] = []
        var seen: [String: Int] = [:], section = ""
        var cur: (name: String, master: Bool, code: Bool, dup: Int, section: String)?
        func close() {
            guard let c = cur, !c.master, c.code else { return }
            out.append((c.dup == 0 ? c.name : "\(c.name) #\(c.dup + 1)", c.name, c.section))
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if let open = l.first, open == "[" || open == "{", let end = l.firstIndex(of: open == "[" ? "]" : "}") {
                let full = String(l[l.index(after: l.startIndex)..<end])
                if full.isEmpty { close(); cur = nil; continue }
                close()
                var n = full; while n.utf8.count > 127 { n.removeLast() }   // cut as the host cuts it, on a character boundary
                var entrySection = section
                if n.hasSuffix("--"), n.count >= 4 {
                    if n.hasPrefix("--SectionStart:") { section = String(n.dropFirst(15).dropLast(2)); entrySection = section }
                    else if n.hasPrefix("--SectionEnd:") { section = "" }
                }
                let dup = seen[n, default: 0]; seen[n] = dup + 1
                cur = (n, open == "{", l[l.index(after: end)...].contains { $0.isHexDigit }, dup, entrySection)
            } else if let f = l.first, f.isHexDigit {
                cur?.code = true
            }
        }
        close()
        return out
    }

    func set(_ c: Cheat, on: Bool) {
        guard let i = cheats.firstIndex(of: c) else { return }
        cheats[i].on = on; writeEnabled()
    }
    func setAll(_ on: Bool) { for i in cheats.indices { cheats[i].on = on }; writeEnabled() }
    func writeEnabledPublic() { writeEnabled() }
    private func writeEnabled() {
        guard let f = enabledFile else { return }
        let text = cheats.filter(\.on).map { $0.key + "\n" }.joined()
        do { try text.write(to: f, atomically: true, encoding: .utf8) } catch { message = error.localizedDescription }
    }
    func setMaster(off: Bool) {
        let fm = FileManager.default
        if off { try? fm.createDirectory(at: game.cheatsFolder, withIntermediateDirectories: true); fm.createFile(atPath: offFlag.path, contents: Data()) }
        else { try? fm.removeItem(at: offFlag) }
        masterOff = off
    }

    /// A cheat file for this build: copied to <build ID>.txt (a file already there goes to the Trash)
    func install(_ src: URL) {
        guard let b = buildID else { message = "This app has no build ID (main.fixups.tsv): pack it again."; return }
        let fm = FileManager.default, dest = game.cheatsFolder.appendingPathComponent("\(b).txt")
        do {
            try fm.createDirectory(at: game.cheatsFolder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: src, to: dest)
            let stem = src.deletingPathExtension().lastPathComponent.uppercased()
            message = stem.count == 16 && stem.allSatisfy(\.isHexDigit) && stem != b
                ? "Added. The file was made for another version of the game (\(stem)), so its cheats may not work."
                : "Added."
        } catch { message = "Could not install: \(error.localizedDescription)" }
        reload()
    }
}

struct CheatsView: View {
    @StateObject var m: CheatsModel
    @State private var search = ""
    init(game: Game) { _m = StateObject(wrappedValue: CheatsModel(game: game)) }

    private var sections: [String] { m.cheats.reduce(into: []) { if !$0.contains($1.section) { $0.append($1.section) } } }
    private func shown(_ s: String) -> [Cheat] {
        m.cheats.filter { $0.section == s && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    @State private var choosing = false
    @State private var advanced = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Find Cheats…") { choosing = true }.buttonStyle(.borderedProminent)
                    if let t = m.message { Text(t).foregroundStyle(.secondary) }
                }
            }
            Section("Your cheats") {
                if m.cheats.isEmpty {
                    Text("You have no cheats for this game yet.").foregroundStyle(.secondary)
                } else {
                    Toggle("Cheats", isOn: Binding(get: { !m.masterOff }, set: { m.setMaster(off: !$0) }))
                    Text("Takes effect the next time the game starts (or press ⌘R in the game).").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if m.cheats.count > 12 { TextField("Search", text: $search).textFieldStyle(.roundedBorder) }
                        Spacer()
                        Button("All On") { m.setAll(true) }
                        Button("All Off") { m.setAll(false) }
                    }
                }
            }
            ForEach(sections, id: \.self) { s in
                let rows = shown(s)
                if !rows.isEmpty {
                    Section(s.isEmpty ? "" : s) {
                        ForEach(rows) { c in
                            Toggle(c.name, isOn: Binding(get: { c.on }, set: { m.set(c, on: $0) }))
                        }
                    }
                    .disabled(m.masterOff)
                }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    LabeledContent("Build ID", value: m.buildID ?? "unknown")
                    if let f = m.file { LabeledContent("Cheat file", value: f.path.replacingOccurrences(of: m.game.support.path + "/", with: "")) }
                    else { Text("No cheat file yet. An Atmosphère cheat file for this version is named \(m.buildID ?? "<build ID>").txt.").font(.footnote).foregroundStyle(.secondary) }
                    if !m.others.isEmpty { Text("Files for other versions: \(m.others.joined(separator: ", ")). Their addresses do not fit this version.").font(.footnote).foregroundStyle(.secondary) }
                    HStack {
                        Button("Add Cheat File…") { pick() }
                        Button("Open Cheats Folder") {
                            try? FileManager.default.createDirectory(at: m.game.cheatsFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(m.game.cheatsFolder)
                        }
                        Button("Refresh") { m.reload() }
                    }
                    Text("Typed values and run-once cheats are set in the game's Cheats window.").font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text(CheatsModel.dbCredit).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $choosing) { ChooseCheatsSheet(m: m) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers { _ = p.loadObject(ofClass: URL.self) { u, _ in if let u, u.pathExtension.lowercased() == "txt" { DispatchQueue.main.async { m.install(u) } } } }
            return true
        }
    }
    private func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText]; p.allowsMultipleSelection = false
        p.message = "Choose an Atmosphère cheat file (.txt) for this version of the game"
        if p.runModal() == .OK, let u = p.url { m.install(u) }
    }
}
