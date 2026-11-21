// Browse Mods (a game's Mods page; docs/launcher.md, Browse Mods): GameBanana's mods for the game, through its public API (apiv11), read only when the player browses, with a
// User-Agent naming Cartridge and nothing about the player. A mod's file is downloaded from GameBanana only when the player presses its Install, into a folder on the games
// drive (never the home folder), unpacked (zip with ditto; 7z and rar with the system's bsdtar), installed by the Mods page (ModsModel.install, off) and deleted: nothing is
// kept, mirrored or shared. The mod's page and authors go into its SOURCE.txt and show under it on the Mods page. A Switch 2 Edition finds its Switch 1 game's mods (one
// GameBanana game covers both): they are made for the Switch version, and the Mods page carries them over to the edition's files when turned on (ModsModel.port)
import AppKit
import SwiftUI

enum GameBanana {
    static let api = "https://gamebanana.com/apiv11/"
    static let agent = "Cartridge (nxnative launcher)"
    static func get(_ path: String) async throws -> Any {
        guard let url = URL(string: api + path) else { throw URLError(.badURL) }
        var r = URLRequest(url: url, timeoutInterval: 20); r.setValue(agent, forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: d)
    }
    static func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
}

struct GBGame: Identifiable, Hashable { let id: Int; let name: String }
struct GBMod: Identifiable, Hashable {
    let id: Int, name: String, author: String, likes: Int, views: Int, updated: Date?, thumb: URL?, page: URL?
    init?(_ o: [String: Any]) {
        guard let id = o["_idRow"] as? Int, let name = o["_sName"] as? String else { return nil }
        self.id = id; self.name = name
        author = (o["_aSubmitter"] as? [String: Any])?["_sName"] as? String ?? "?"
        likes = o["_nLikeCount"] as? Int ?? 0; views = o["_nViewCount"] as? Int ?? 0
        updated = ((o["_tsDateUpdated"] ?? o["_tsDateModified"] ?? o["_tsDateAdded"]) as? Double).map { Date(timeIntervalSince1970: $0) }
        let img = ((o["_aPreviewMedia"] as? [String: Any])?["_aImages"] as? [[String: Any]])?.first
        thumb = img.flatMap { i in (i["_sBaseUrl"] as? String).flatMap { b in (i["_sFile220"] as? String ?? i["_sFile"] as? String).flatMap { URL(string: b + "/" + $0) } } }
        page = (o["_sProfileUrl"] as? String).flatMap(URL.init(string:))
    }
}
struct GBFile: Identifiable, Hashable { let id: Int, name: String, size: Int64, version: String, about: String, download: URL? }
struct GBDetail { let mod: GBMod, description: String, authors: [String], files: [GBFile] }

@MainActor final class ModBrowserModel: ObservableObject {
    let mods: ModsModel
    var game: Game { mods.game }
    enum Sort: String, CaseIterable { case popular = "Generic_MostLiked", downloads = "Generic_MostDownloaded", newest = "Generic_Newest", updated = "Generic_LatestUpdated"
        var label: String { switch self { case .popular: "Most liked"; case .downloads: "Most downloaded"; case .newest: "Newest"; case .updated: "Recently updated" } } }
    @Published var games: [GBGame] = []
    @Published var gb: GBGame?
    @Published var list: [GBMod] = []
    @Published var total = 0
    @Published var sort = Sort.popular
    @Published var search = ""
    @Published var status: String?
    @Published var busy = false
    @Published var detail: GBDetail?
    @Published var installing: Int?
    private var page = 1
    init(mods: ModsModel) { self.mods = mods }
    var isEdition: Bool { mods.switch1TitleID != nil }
    private var key: String { "mods.gamebanana.\(game.titleID)" }

    /// The game's name as GameBanana knows it: without " – Nintendo Switch 2 Edition" and what follows a "+"
    var searchName: String {
        var n = game.name
        for s in ["Nintendo Switch 2 Edition", "Switch 2 Edition"] { if let r = n.range(of: s) { n = String(n[..<r.lowerBound]) } }
        if let r = n.range(of: " + ") { n = String(n[..<r.lowerBound]) }
        return n.trimmingCharacters(in: CharacterSet(charactersIn: " –-:"))
    }
    func start() async {
        if let id = UserDefaults.standard.object(forKey: key) as? Int, let name = UserDefaults.standard.string(forKey: key + ".name") { gb = GBGame(id: id, name: name); await reload(); return }
        busy = true; status = nil; defer { busy = false }
        do {
            let o = try await GameBanana.get("Util/Search/Results?_sModelName=Game&_sSearchString=\(GameBanana.q(searchName))&_nPage=1") as? [String: Any]
            games = ((o?["_aRecords"] as? [[String: Any]]) ?? []).compactMap { r in (r["_idRow"] as? Int).flatMap { id in (r["_sName"] as? String).map { GBGame(id: id, name: $0) } } }
            let want = searchName.lowercased().filter { $0.isLetter || $0.isNumber }
            if let exact = games.first(where: { $0.name.lowercased().filter { $0.isLetter || $0.isNumber } == want }) { choose(exact); await reload() }
            else if games.isEmpty { status = "GameBanana has no page for \(searchName)." }
        } catch { status = "Could not reach GameBanana." }
    }
    func choose(_ g: GBGame) { gb = g; UserDefaults.standard.set(g.id, forKey: key); UserDefaults.standard.set(g.name, forKey: key + ".name") }
    func reload() async { page = 1; list = []; await more() }
    func more() async {
        guard let gb else { return }
        busy = true; defer { busy = false }
        do {
            let q = search.trimmingCharacters(in: .whitespaces)
            let path = q.isEmpty
                ? "Mod/Index?_aFilters%5BGeneric_Game%5D=\(gb.id)&_nPage=\(page)&_nPerpage=20&_sSort=\(sort.rawValue)"
                : "Util/Search/Results?_sModelName=Mod&_sSearchString=\(GameBanana.q(q))&_idGameRow=\(gb.id)&_nPage=\(page)"
            let o = try await GameBanana.get(path) as? [String: Any]
            let rows = ((o?["_aRecords"] as? [[String: Any]]) ?? []).filter { ($0["_sModelName"] as? String ?? "Mod") == "Mod" }.compactMap(GBMod.init)
            list += rows.filter { r in !list.contains { $0.id == r.id } }
            total = ((o?["_aMetadata"] as? [String: Any])?["_nRecordCount"] as? Int) ?? list.count
            page += 1; status = list.isEmpty ? (q.isEmpty ? "No mods for this game yet." : "No mods match.") : nil
        } catch { status = "Could not reach GameBanana." }
    }
    var hasMore: Bool { list.count < total }
    func open(_ m: GBMod) async {
        busy = true; defer { busy = false }
        do {
            let o = try await GameBanana.get("Mod/\(m.id)?_csvProperties=_sName,_aFiles,_sDescription,_aSubmitter,_sProfileUrl,_aCredits") as? [String: Any] ?? [:]
            let files = ((o["_aFiles"] as? [[String: Any]]) ?? []).compactMap { f -> GBFile? in
                guard let id = f["_idRow"] as? Int, let n = f["_sFile"] as? String else { return nil }
                return GBFile(id: id, name: n, size: (f["_nFilesize"] as? NSNumber)?.int64Value ?? 0, version: f["_sVersion"] as? String ?? "",
                              about: f["_sDescription"] as? String ?? "", download: (f["_sDownloadUrl"] as? String).flatMap(URL.init(string:)))
            }
            var authors: [String] = []
            for (_, people) in (o["_aCredits"] as? [String: Any]) ?? [:] { for p in (people as? [[Any]]) ?? [] { if let n = p.first as? String, !authors.contains(n) { authors.append(n) } } }
            if !authors.contains(m.author) { authors.insert(m.author, at: 0) }
            detail = GBDetail(mod: m, description: o["_sDescription"] as? String ?? "", authors: authors, files: files)
        } catch { status = "Could not read this mod from GameBanana." }
    }

    /// Download one file of the mod (from GameBanana, when pressed), unpack it on the games drive, install it off with its credit, delete the download
    func install(_ f: GBFile, of d: GBDetail) async {
        guard let url = f.download else { return }
        guard let root = GamesFolder.root else { status = "Choose a games folder first (Settings › Library): mods are unpacked on its drive."; return }
        installing = f.id; defer { installing = nil }
        let work = root.appendingPathComponent(".cartridge-mods/\(UUID().uuidString)"), out = work.appendingPathComponent("unpacked")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            var r = URLRequest(url: url, timeoutInterval: 120); r.setValue(GameBanana.agent, forHTTPHeaderField: "User-Agent")
            let (tmp, resp) = try await URLSession.shared.download(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { status = "The download failed."; return }
            let archive = work.appendingPathComponent(f.name); try fm.moveItem(at: tmp, to: archive)
            let ext = archive.pathExtension.lowercased()
            let (code, msg) = await Task.detached { () -> (Int32, String) in
                switch ext {
                case "zip": return shell("/usr/bin/ditto", ["-x", "-k", archive.path, out.path])
                case "7z", "rar", "tar", "gz", "tgz", "xz": return shell("/usr/bin/tar", ["-x", "-f", archive.path, "-C", out.path])
                default:   // a single file (an IPS patch, a pchtxt): the mod is that file in an exefs folder, or the file as it is
                    let isPatch = ["ips", "pchtxt"].contains(ext), dir = isPatch ? out.appendingPathComponent("exefs") : out
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    return (((try? FileManager.default.copyItem(at: archive, to: dir.appendingPathComponent(archive.lastPathComponent))) != nil) ? 0 : 1, "")
                }
            }.value
            guard code == 0 else { status = "Could not unpack \(f.name)\(ext == "rar" ? " (some newer RAR files cannot be opened on a Mac)" : ""): \(msg.split(separator: "\n").last ?? "")."; return }
            // the folder that holds the mod: the first, breadth-first, with romfs, exefs, atmosphere or contents in it; else past wrapping folders (loose readme files and
            // macOS's __MACOSX beside them do not count), so that a download of the game's files as they are is taken whole
            func subdirs(_ u: URL) -> [URL] {
                ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter {
                    !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
            func marked(_ u: URL) -> Bool { subdirs(u).contains { ["romfs", "exefs", "atmosphere", "contents"].contains($0.lastPathComponent.lowercased()) } }
            var src = out, level = [out]
            search: for _ in 0..<4 {
                for u in level where marked(u) { src = u; break search }
                level = level.flatMap(subdirs)
                if level.isEmpty { break }
            }
            if src == out { while subdirs(src).count == 1, !marked(src) { src = subdirs(src)[0] } }
            let credit = "\(d.mod.name)\n\(d.mod.page?.absoluteString ?? "")\nby \(d.authors.joined(separator: ", "))\nDownloaded by Cartridge from GameBanana (\(f.name)).\n"
            let name = d.files.count > 1 ? "\(d.mod.name) – \(f.name.split(separator: ".").first ?? "")" : d.mod.name
            if let installed = mods.install(from: src, name: name, on: false, credit: credit) {
                status = "Installed \(installed), off: turn it on in the Mods list." + (isEdition ? " It was made for the Switch version: it is carried over to this edition when you turn it on." : "")
            } else { status = mods.message }
        } catch { status = "The download failed: \(error.localizedDescription)" }
    }
}

@MainActor enum ModBrowserWindow {
    static var open: [String: NSWindow] = [:]
    static func open(for mods: ModsModel) {
        let key = mods.game.titleID
        if let w = open[key] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Mods for \(mods.game.name)"; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ModBrowserView(model: ModBrowserModel(mods: mods)))
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in open[key] = nil; mods.reload() }
        open[key] = w
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct ModBrowserView: View {
    @StateObject var model: ModBrowserModel
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.gb == nil { pickGame } else { list }
            Divider()
            HStack {
                Text("Mods come straight from GameBanana, made by their authors.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if let s = model.status { Text(s).font(.footnote) }
            }.padding(8)
        }
        .task { await model.start() }
        .sheet(item: Binding(get: { model.detail.map { DetailBox(d: $0) } }, set: { if $0 == nil { model.detail = nil } })) { box in ModDetailView(model: model, d: box.d) }
    }
    var header: some View {
        HStack {
            if let g = model.gb {
                Text(g.name).font(.headline)
                if model.isEdition { Text("(Switch version mods)").foregroundStyle(.secondary) }
                Button("Change Game") { model.gb = nil }.buttonStyle(.link)
                Spacer()
                TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 200).onSubmit { Task { await model.reload() } }
                Picker("", selection: $model.sort) { ForEach(ModBrowserModel.Sort.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .labelsHidden().frame(width: 170).onChange(of: model.sort) { Task { await model.reload() } }
            } else { Text("Which game on GameBanana?").font(.headline); Spacer() }
            if model.busy { ProgressView().controlSize(.small) }
        }.padding(10)
    }
    var pickGame: some View {
        List(model.games) { g in Button(g.name) { model.choose(g); Task { await model.reload() } }.buttonStyle(.link) }
    }
    var list: some View {
        List {
            if model.isEdition {
                Text("These mods were made for the Switch version of the game. When you turn one on, Cartridge carries its changes over to this edition where it can.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.list) { m in
                Button { Task { await model.open(m) } } label: {
                    HStack(alignment: .top, spacing: 10) {
                        AsyncImage(url: m.thumb) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                            .frame(width: 110, height: 62).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.name).font(.body.weight(.medium))
                            Text("by \(m.author)").font(.callout).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Label("\(m.likes)", systemImage: "heart"); Label("\(m.views)", systemImage: "eye")
                                if let u = m.updated { Text(u, style: .date) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if model.hasMore { Button("Show More") { Task { await model.more() } } }
        }
    }
}
private struct DetailBox: Identifiable { let d: GBDetail; var id: Int { d.mod.id } }

struct ModDetailView: View {
    @ObservedObject var model: ModBrowserModel
    let d: GBDetail
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.mod.name).font(.title3.weight(.semibold))
                    Text("by \(d.authors.joined(separator: ", "))").foregroundStyle(.secondary)
                    if let p = d.mod.page { Link("Open on GameBanana", destination: p).font(.callout) }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !d.description.isEmpty { Text(d.description).font(.callout) }
            Text("Files").font(.headline)
            List(d.files) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name)
                        Text([f.version.isEmpty ? nil : "Version \(f.version)", ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file), f.about.isEmpty ? nil : f.about]
                                .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.installing == f.id { ProgressView().controlSize(.small) }
                    else { Button("Install") { Task { await model.install(f, of: d) } }.disabled(model.installing != nil) }
                }
            }.frame(minHeight: 140)
            if let s = model.status { Text(s).font(.footnote) }
            Text("Installed mods start off. Mods that add a code module only have their files used.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding().frame(minWidth: 620, minHeight: 420)
    }
}
