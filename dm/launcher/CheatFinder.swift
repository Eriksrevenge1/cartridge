// Find Cheats (a game's Cheats page; docs/launcher.md, Find Cheats): the community database switch-cheats-db (github.com/HamletDuFromage/switch-cheats-db, one JSON file
// per title ID: build ID → { "[Name]": Atmosphère text }, and "attribution"), fetched when the player asks, never bundled or mirrored. A Switch 2 Edition (title ID 04…) has
// its own entry rarely: its Switch 1 game's (01…, the last digit 0) is tried too, and labelled so. Cheats for the game's own build are added to its <build ID>.txt, the
// player's own entries kept. Cheats for other builds are carried to this one with scripts/cheat_anchor.py (import on the source build's ExeFS main,
// compile on this build's) when both mains are in the player's games folder (the NSP script's extractions: <title ID>_build/extract/v<n>/ExeFS/main, …_survey/…): nothing
// is downloaded but the cheat text; carried cheats are named "… (converted, may not work)"
import Foundation
import SwiftUI

struct CheatSet: Identifiable {
    let build: String                       // the build ID the cheats were written for
    let cheats: [(name: String, text: String)]
    var id: String { build }
}

struct CheatSearch {
    let titleID: String                     // the database entry used
    let switch1: Bool                       // the Switch 1 game's entry, for a Switch 2 Edition
    let mine: CheatSet?                     // for the game's own build
    let others: [CheatSet]
    let credit: String                      // the database's attribution: the files and authors it names
}

enum FinderState { case idle, searching, none(String), found(CheatSearch), failed(String) }

extension CheatsModel {
    static let dbURL = "https://raw.githubusercontent.com/HamletDuFromage/switch-cheats-db/master/cheats/"
    static let dbCredit = "Cheats from the switch-cheats-db community database, by their authors."

    /// The title IDs to look up: the game's, then for a Switch 2 Edition (04…) its Switch 1 game's (01…, last digit 0)
    var lookupIDs: [(String, Bool)] {
        let t = game.titleID.uppercased()
        guard t.hasPrefix("04"), t.count == 16 else { return [(t, false)] }
        return [(t, false), ("01" + t.dropFirst(2).dropLast() + "0", true)]
    }

    @MainActor func findCheats() async {
        finder = .searching
        for (tid, s1) in lookupIDs {
            guard let url = URL(string: Self.dbURL + tid + ".json") else { continue }
            var r = URLRequest(url: url, timeoutInterval: 20); r.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else { finder = .failed("Couldn't reach the cheat database. Check your internet connection and try again."); return }
            if code == 404 { continue }
            guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { finder = .failed("The cheat database sent something Cartridge doesn't understand. Try again later."); return }
            var sets: [CheatSet] = []
            for (k, v) in obj where k.count == 16 && k.allSatisfy(\.isHexDigit) {
                guard let d = v as? [String: String] else { continue }
                let cheats = d.keys.sorted().map { n in (name: String(n.dropFirst().dropLast()), text: d[n] ?? "") }
                sets.append(CheatSet(build: k.uppercased(), cheats: cheats))
            }
            let credit = (obj["attribution"] as? [String: Any]).map { $0.keys.sorted().map { $0.replacingOccurrences(of: ".txt", with: "") }.joined(separator: "; ") } ?? ""
            let mine = buildID.flatMap { b in sets.first { $0.build == b } }
            finder = .found(CheatSearch(titleID: tid, switch1: s1, mine: s1 ? nil : mine, others: sets.filter { $0.build != buildID || s1 }.sorted { $0.build < $1.build }, credit: credit))
            return
        }
        finder = .none("The cheat database has no cheats for this game.")
    }

    /// Cheats added to this build's file: the player's entries stay, a cheat whose name is already there is left out, all new ones are off
    @discardableResult func addCheats(_ cheats: [(name: String, text: String)], from: String) -> Int {
        guard let b = buildID else { message = "This game needs to be built again before cheats can be added."; return 0 }
        let fm = FileManager.default, dest = file ?? game.cheatsFolder.appendingPathComponent("\(b).txt")
        let had = (try? String(contentsOf: dest, encoding: .utf8)) ?? ""
        let names = Set(Self.parse(had).map(\.name))
        let new = cheats.filter { !names.contains($0.name) }
        guard !new.isEmpty else { message = "No new cheats found."; return 0 }
        var text = had
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n" + new.map { c in c.text.hasSuffix("\n") ? c.text : c.text + "\n" }.joined(separator: "\n")
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: dest, atomically: true, encoding: .utf8)
            let credit = dest.deletingPathExtension().appendingPathExtension("source.txt")
            let line = "\(new.count) cheat(s) from \(from). \(Self.dbCredit)\n"
            if let h = try? FileHandle(forWritingTo: credit) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(to: credit, atomically: true, encoding: .utf8) }
        } catch { message = "Couldn't add the cheats: \(error.localizedDescription)"; return 0 }
        reload()
        return new.count
    }

    /// The cheats ticked in Choose cheats: written into this version's cheat file (the player's entries untouched, names already there skipped) and switched on
    func addChosen(_ chosen: [(name: String, text: String)], from: String) {
        let names = Set(cheats.map(\.name))
        let new = chosen.filter { !names.contains($0.name) }
        guard addCheats(new, from: from) > 0 else { return }
        for i in cheats.indices where new.contains(where: { $0.name == cheats[i].name }) { cheats[i].on = true }
        writeEnabledPublic()
        message = "Added \(new.count) cheat\(new.count == 1 ? "" : "s")."
    }

    /// An ExeFS main of the given build in the player's games folder (or beside this game's app), from the NSP script's extractions
    func mainNSO(build: String) -> URL? {
        var roots: [URL] = []
        if let r = GamesFolder.root { roots.append(r) }
        roots.append(game.url.deletingLastPathComponent())
        let fm = FileManager.default
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            while let u = e.nextObject() as? URL {
                if e.level > 6 { e.skipDescendants(); continue }
                guard u.lastPathComponent == "main", u.deletingLastPathComponent().lastPathComponent == "ExeFS",
                      let h = try? FileHandle(forReadingFrom: u) else { continue }
                defer { try? h.close() }
                guard let head = try? h.read(upToCount: 0x48), head.count == 0x48, head.prefix(4) == Data("NSO0".utf8) else { continue }
                if head[0x40..<0x48].map({ String(format: "%02X", $0) }).joined() == build { return u }
            }
        }
        return nil
    }

    /// Carries another build's cheats to this build (cheat_anchor.py import, then compile): the ones that resolve are added as "… (converted, may not work)"
    /// Converts another version's cheats for this one (cheat_anchor.py import on that version's main, compile on this one's) and hands back the ones that converted,
    /// named "… (converted, may not work)", and how many did not; or a plain reason
    func convert(_ set: CheatSet, done: @escaping (_ cheats: [(name: String, text: String)], _ failed: Int, _ problem: String?) -> Void) {
        guard let b = buildID else { done([], 0, "This game needs to be built again before cheats can be added."); return }
        guard let src = mainNSO(build: set.build) else { done([], 0, "These cheats can't be converted: the other version's game files aren't in your games folder."); return }
        guard let dst = mainNSO(build: b) else { done([], 0, "Your version's game files aren't in your games folder any more: build the game again, then try."); return }
        guard let py = Engine.shared.python?.path, let dir = Engine.shared.installedDir else { done([], 0, "Cartridge is still getting ready: try again in a minute."); return }
        let script = dir.appendingPathComponent("scripts/cheat_anchor.py").path
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cartridge-cheats-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("out"), withIntermediateDirectories: true)
            let txt = tmp.appendingPathComponent("\(set.build).txt"), toml = tmp.appendingPathComponent("port.cheats.toml")
            try? set.cheats.map { $0.text.hasSuffix("\n") ? $0.text : $0.text + "\n" }.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
            let a = shell(py, [script, "import", txt.path, "--nso", src.path, "-o", toml.path])
            let c = a.0 == 0 || a.0 == 2 ? shell(py, [script, "compile", toml.path, "--nso", dst.path, "-o", tmp.appendingPathComponent("out").path]) : a
            let text = (try? String(contentsOf: tmp.appendingPathComponent("out/\(b).txt"), encoding: .utf8)) ?? ""
            let got = Self.split(text).map { (name: $0.name + " (converted, may not work)", text: $0.text.replacingOccurrences(of: "[\($0.name)]", with: "[\($0.name) (converted, may not work)]")) }
            DispatchQueue.main.async {
                if c.0 != 0 && c.0 != 2 { done([], set.cheats.count, "These cheats couldn't be converted for your version."); return }
                done(got, max(set.cheats.count - got.count, 0), got.isEmpty ? "None of these cheats could be converted for your version." : nil)
            }
        }
    }

    /// A cheat file's entries with their text, header line included ([Name] or {Name}); labels without code are kept too
    static func split(_ text: String) -> [(name: String, text: String)] {
        var out: [(name: String, text: String)] = [], cur: (name: String, lines: [String])?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if (l.hasPrefix("[") && l.contains("]")) || (l.hasPrefix("{") && l.contains("}")) {
                if let c = cur { out.append((c.name, c.lines.joined(separator: "\n") + "\n")) }
                let close: Character = l.hasPrefix("[") ? "]" : "}"
                cur = (String(l.dropFirst().prefix { $0 != close }), [l])
            } else if !l.isEmpty { cur?.lines.append(l) }
        }
        if let c = cur { out.append((c.name, c.lines.joined(separator: "\n") + "\n")) }
        return out.filter { !$0.name.isEmpty && $0.text.split(separator: "\n").count > 1 }
    }
}

/// Choose cheats: the database's cheats for this version, each with a checkbox (unticked; the player's own shown ticked and disabled, "(added)"), Select All / None, a search
/// field for a long list, and Cancel / Add N. With only other versions in the database, More options converts them and lists what converted in the same checkboxes
struct ChooseCheatsSheet: View {
    @ObservedObject var m: CheatsModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [(name: String, text: String)] = []
    @State private var ticked: Set<String> = []
    @State private var search = ""
    @State private var from = "switch-cheats-db"
    @State private var note: String?
    @State private var converting = false
    @State private var moreOpen = false
    private var have: Set<String> { Set(m.cheats.map(\.name)) }
    private var shown: [(name: String, text: String)] { items.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    private var choosable: [String] { items.map(\.name).filter { !have.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose cheats").font(.title2)
            switch m.finder {
            case .idle, .searching:
                Spacer(); HStack { Spacer(); ProgressView().controlSize(.small); Text("Looking for cheats…"); Spacer() }; Spacer()
            case .none(let t), .failed(let t):
                Spacer(); Text(t).frame(maxWidth: .infinity); Spacer()
            case .found(let s):
                if items.isEmpty {
                    Text(s.mine == nil ? "No cheats for your version of this game." : "No cheats found for this game.")
                    if s.mine == nil && !s.others.isEmpty {
                        DisclosureGroup("More options", isExpanded: $moreOpen) {
                            ForEach(s.others) { o in
                                HStack {
                                    Text("Try cheats made for another version (may not all work)")
                                    Text("\(o.cheats.count)\(s.switch1 ? ", Switch 1 version" : "")").foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Try") {
                                        converting = true; note = nil
                                        m.convert(o) { got, failed, problem in
                                            converting = false
                                            if let problem { note = problem; return }
                                            items = got; from = "switch-cheats-db, converted from another version"
                                            note = failed > 0 ? "\(failed) couldn't be converted." : nil
                                        }
                                    }.disabled(converting)
                                }
                            }
                            if converting { HStack { ProgressView().controlSize(.small); Text("Converting…") } }
                        }
                    }
                    if let note { Text(note).foregroundStyle(.secondary) }
                    Spacer()
                } else {
                    HStack {
                        if items.count > 12 { TextField("Search", text: $search).textFieldStyle(.roundedBorder) }
                        Spacer()
                        Button("Select All") { ticked = Set(choosable) }
                        Button("Select None") { ticked = [] }
                    }
                    if let note { Text(note).foregroundStyle(.secondary) }
                    List(shown, id: \.name) { c in
                        let added = have.contains(c.name)
                        Toggle(isOn: Binding(get: { added || ticked.contains(c.name) },
                                             set: { if $0 { ticked.insert(c.name) } else { ticked.remove(c.name) } })) {
                            Text(added ? "\(c.name) (added)" : c.name)
                        }
                        .toggleStyle(.checkbox).disabled(added)
                    }
                    .frame(minHeight: 260)
                }
            }
            Text(CheatsModel.dbCredit).font(.footnote).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(ticked.count)") {
                    m.addChosen(items.filter { ticked.contains($0.name) }, from: from); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(ticked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .task {
            await m.findCheats()
            if case .found(let s) = m.finder, let mine = s.mine { items = mine.cheats }
        }
    }
}
