// Find Cheats (a game's Cheats page; docs/launcher.md, Find Cheats): the community database switch-cheats-db (github.com/HamletDuFromage/switch-cheats-db, one JSON file
// per title ID: build ID → { "[Name]": Atmosphère text }, and "attribution"), fetched when the player asks, never bundled or mirrored. A Switch 2 Edition (title ID 04…) has
// its own entry rarely: its Switch 1 game's (01…, the last digit 0) is tried too, and labelled so. Cheats for the game's own build are added to its <build ID>.txt, the
// player's own entries kept, all new ones off. Cheats for other builds are carried to this one with scripts/cheat_anchor.py (import on the source build's ExeFS main,
// compile on this build's) when both mains are in the player's games folder (the NSP script's extractions: <title ID>_build/extract/v<n>/ExeFS/main, …_survey/…): nothing
// is downloaded but the cheat text; carried cheats are named "… (ported, untested)"
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
    static let dbCredit = "From the switch-cheats-db community database (HamletDuFromage), by their authors."

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
            guard let (data, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else { finder = .failed("Could not reach the cheat database."); return }
            if code == 404 { continue }
            guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { finder = .failed("The cheat database answered in a way Cartridge does not understand."); return }
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
        guard let b = buildID else { message = "This app has no build ID: build it again."; return 0 }
        let fm = FileManager.default, dest = file ?? game.cheatsFolder.appendingPathComponent("\(b).txt")
        let had = (try? String(contentsOf: dest, encoding: .utf8)) ?? ""
        let names = Set(Self.parse(had).map(\.name))
        let new = cheats.filter { !names.contains($0.name) }
        guard !new.isEmpty else { message = "These cheats are already installed."; return 0 }
        var text = had
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n" + new.map { c in c.text.hasSuffix("\n") ? c.text : c.text + "\n" }.joined(separator: "\n")
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: dest, atomically: true, encoding: .utf8)
            let credit = dest.deletingPathExtension().appendingPathExtension("source.txt")
            let line = "\(new.count) cheat(s) from \(from). \(Self.dbCredit)\n"
            if let h = try? FileHandle(forWritingTo: credit) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(to: credit, atomically: true, encoding: .utf8) }
        } catch { message = "Could not install: \(error.localizedDescription)"; return 0 }
        reload()
        return new.count
    }

    func installMine(_ s: CheatSearch) {
        guard let set = s.mine else { return }
        let n = addCheats(set.cheats, from: "switch-cheats-db")
        if n > 0 { message = "Installed \(n) cheat\(n == 1 ? "" : "s"). They start off: turn on the ones you want." }
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

    /// Carries another build's cheats to this build (cheat_anchor.py import, then compile): the ones that resolve are added as "… (ported, untested)"
    func port(_ set: CheatSet) {
        guard let b = buildID else { message = "This app has no build ID: build it again."; return }
        guard let src = mainNSO(build: set.build) else {
            message = "Cheats exist for another version of this game (\(set.build)), but carrying them over needs that version's files, which aren't in your games folder."; return
        }
        guard let dst = mainNSO(build: b) else { message = "This version's files aren't in your games folder any more: build the game again, then try."; return }
        guard let py = Engine.shared.python?.path, let dir = Engine.shared.installedDir else { message = "Cartridge's engine is not ready yet."; return }
        message = "Carrying \(set.cheats.count) cheats over…"
        let script = dir.appendingPathComponent("scripts/cheat_anchor.py").path
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cartridge-cheats-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("out"), withIntermediateDirectories: true)
            let txt = tmp.appendingPathComponent("\(set.build).txt"), toml = tmp.appendingPathComponent("port.cheats.toml")
            try? set.cheats.map { $0.text.hasSuffix("\n") ? $0.text : $0.text + "\n" }.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
            let a = shell(py, [script, "import", txt.path, "--nso", src.path, "-o", toml.path])
            let c = a.0 == 0 || a.0 == 2 ? shell(py, [script, "compile", toml.path, "--nso", dst.path, "-o", tmp.appendingPathComponent("out").path]) : a
            let out = tmp.appendingPathComponent("out/\(b).txt")
            let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            let ported = Self.parse(text).isEmpty ? [] : Self.split(text).map { (name: $0.name + " (ported, untested)", text: $0.text.replacingOccurrences(of: "[\($0.name)]", with: "[\($0.name) (ported, untested)]")) }
            DispatchQueue.main.async {
                guard c.0 == 0 || c.0 == 2 else { self.message = "These cheats could not be carried over to your version."; return }
                let n = ported.isEmpty ? 0 : self.addCheats(ported, from: "switch-cheats-db, carried over from version \(set.build)")
                let skipped = set.cheats.count - ported.count
                self.message = n == 0 && ported.isEmpty ? "None of these cheats could be carried over to your version."
                    : "Carried \(ported.count) of \(set.cheats.count) cheats over (\(skipped) could not be). They start off and are untested: try them one at a time."
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

struct FindCheatsSection: View {
    @ObservedObject var m: CheatsModel
    var body: some View {
        Section {
            switch m.finder {
            case .idle: Button("Find Cheats…") { Task { await m.findCheats() } }
            case .searching: HStack { ProgressView().controlSize(.small); Text("Looking for cheats…") }
            case .none(let s), .failed(let s): Text(s); Button("Search Again") { Task { await m.findCheats() } }
            case .found(let s):
                if let mine = s.mine {
                    Text("\(mine.cheats.count) cheat\(mine.cheats.count == 1 ? "" : "s") for your version")
                    Text(mine.cheats.prefix(8).map(\.name).joined(separator: " · ") + (mine.cheats.count > 8 ? " …" : "")).font(.footnote).foregroundStyle(.secondary)
                    Button("Install (they start off)") { m.installMine(s) }
                } else {
                    Text(s.switch1 ? "No cheats for this edition; the database has some for the Switch 1 version, written for other builds:" : "No cheats for your version; the database has some for other versions:")
                }
                ForEach(s.others) { o in
                    HStack {
                        Text("\(o.cheats.count) cheat\(o.cheats.count == 1 ? "" : "s") for version \(o.build)\(s.switch1 ? " (Switch 1)" : "")").font(.callout)
                        Spacer()
                        Button("Carry Over") { m.port(o) }
                    }
                }
                if !s.others.isEmpty { Text("Carrying over works only when that version's files are in your games folder, and not for every cheat.").font(.footnote).foregroundStyle(.secondary) }
                Text(CheatsModel.dbCredit + (s.credit.isEmpty ? "" : " (\(s.credit))")).font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Find Cheats") }
    }
}
