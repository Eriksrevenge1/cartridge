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


/// What Browse Mods does not offer (the owner's legal review, after Nintendo v. Yuzu): mods that replace the game's code (whole code modules), unlock paid content, are
/// console system or piracy tools (signature patches, Atmosphère or firmware files, keys), or give an advantage in online play; and, unless the player turns it on, mods
/// rated for mature content, and mods that are adult or crude by what they say about themselves (always: there is no switch to show them). Decided from the name, category and description where they say so plainly (conservative: only clear cases), and again from the unpacked files
/// at install (GameBanana's API does not list an archive's contents). Code patches (IPS, pchtxt) stay allowed
enum ModRules {
    static func has(_ t: String, _ pattern: String) -> Bool { t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    /// Why a mod is not offered, from what GameBanana says about it; nil when it is
    static func refused(name: String, category: String, description: String = "") -> String? {
        let t = "\(name)\n\(category)\n\(description)"
        if has(t, #"\b(sig(nature)?\s*patch(es)?|sigpatch(es)?|es\s*patch(es)?|prod\.keys|title\.keys|\b(prod|title)\s*keys\b|firmware\s*(files?|dumps?|updates?|downloads?|packages?|\d)|atmosph[eè]re|hekate|\bcfw\b|custom\s*firmware|tinfoil|homebrew\s*(loader|menu|launcher)|nsp\s*install)"#) { return "console system or piracy tool" }
        if has(t, #"(unlock(s|er|ed|ing)?\b[^\n]{0,30}\b(dlc|paid|premium|season\s*pass|expansion\s*pass)|\b(dlc|paid\s*content|season\s*pass)\b[^\n]{0,20}\bunlock|free\s*dlc|all\s*dlc\s*unlock|dlc\s*unlocker)"#) { return "unlocks paid content" }
        if has(t, #"\b(online|pvp|ranked|multiplayer|competitive)\b"#) && has(t, #"\b(cheat|hack|aimbot|wallhack|esp\b|god\s*mode|exploit|speed\s*hack)"#) { return "gives an advantage in online play" }
        return nil
    }
    /// Adult or crude by its own words: nudity, sex, fetish and slurs in the name, categories, tags or description. GameBanana's content ratings miss many of these
    /// (an Ocarina of Time mod named for a body part had none), so they are hidden on the words as well; whole words only, so "class", "cockpit" or "Sussex" pass
    static func adult(_ t: String) -> Bool {
        has(t, #"\b(nsfw|18\+|r-?18|adults?\s*only|nud(e|es|ity|ist)|naked|topless|bottomless|lewd|hentai|ecchi|porn\w*|xxx|sex|sexy|sexual\w*|erotic\w*|fetish\w*|kink\w*|horny|thicc|milf|futa\w*|lingerie|panties|pantsu|bikinis?|swimsuits?|swimwear|beachwear|bra|thong|underwear|boobs?|breasts?|tits?|titties|nipples?|butt|booty|ass|asses|jiggle|bouncy|penis|dick|cock|genitals?|vagina|uncircumcised|circumcised|balls|testicles?|onlyfans|stripper|strip\s*club|slutty|slut|whore|uncensored|censorship\s*removal|fart\w*|poop|piss|vomit)\b"#)
    }
    /// Why an unpacked mod is refused, from its files; nil when it can be installed
    static func refused(files root: URL) -> String? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        var ncas = 0
        for case let u as URL in e {
            let rel = u.path.dropFirst(root.path.count).lowercased(), n = u.lastPathComponent
            if rel.contains("/atmosphere/kips") || rel.contains("/atmosphere/exefs_patches") || rel.hasSuffix(".kip") || n.lowercased() == "prod.keys" || n.lowercased() == "title.keys"
                || rel.contains("/bootloader/") || rel.contains("/hekate") { return "console system or piracy files" }
            if rel.hasSuffix(".nca") { ncas += 1; if ncas >= 3 { return "console system or piracy files" } }
            if has(String(rel), #"dlc[\s_-]*unlock"#) { return "unlocks paid content" }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true, ModsModel.isModule(n),
               u.deletingLastPathComponent().lastPathComponent.lowercased() == "exefs" || ["subsdk", "rtld"].contains(where: { n.lowercased().hasPrefix($0) }) {
                return "replaces the game's code"
            }
        }
        return nil
    }
}

struct GBGame: Identifiable, Hashable { let id: Int; let name: String }
struct GBMod: Identifiable, Hashable {
    let id: Int, name: String, author: String, likes: Int, views: Int, updated: Date?, thumb: URL?, page: URL?
    let category: String, mature: Bool   // GameBanana's root category; rated for mature content by GameBanana (content ratings, or hidden by default there)
    let words: String   // its sub-category and tags, for ModRules.adult
    init?(_ o: [String: Any]) {
        guard let id = o["_idRow"] as? Int, let name = o["_sName"] as? String else { return nil }
        self.id = id; self.name = name
        category = (o["_aRootCategory"] as? [String: Any])?["_sName"] as? String ?? ""
        mature = (o["_bHasContentRatings"] as? Bool ?? false) || (o["_sInitialVisibility"] as? String) == "hide"
        let sub = (o["_aSubCategory"] as? [String: Any])?["_sName"] as? String ?? ""
        let tags = ((o["_aTags"] as? [Any]) ?? []).map { t in (t as? String) ?? ((t as? [String: Any]).map { "\($0["_sTitle"] ?? "") \($0["_sValue"] ?? "")" } ?? "") }
        words = ([sub] + tags).joined(separator: " ")
        author = (o["_aSubmitter"] as? [String: Any])?["_sName"] as? String ?? "?"
        likes = o["_nLikeCount"] as? Int ?? 0; views = o["_nViewCount"] as? Int ?? 0
        updated = ((o["_tsDateUpdated"] ?? o["_tsDateModified"] ?? o["_tsDateAdded"]) as? Double).map { Date(timeIntervalSince1970: $0) }
        let img = ((o["_aPreviewMedia"] as? [String: Any])?["_aImages"] as? [[String: Any]])?.first
        thumb = img.flatMap { i in (i["_sBaseUrl"] as? String).flatMap { b in (i["_sFile530"] as? String ?? i["_sFile220"] as? String ?? i["_sFile"] as? String).flatMap { URL(string: b + "/" + $0) } } }
        page = (o["_sProfileUrl"] as? String).flatMap(URL.init(string:))
    }
}
struct GBFile: Identifiable, Hashable { let id: Int, name: String, size: Int64, version: String, about: String, download: URL? }
struct GBDetail {
    let mod: GBMod, description: String, authors: [String], files: [GBFile]
    var refused: String? {
        if mod.mature || ModRules.adult("\(mod.name)\n\(mod.category)\n\(mod.words)\n\(description)") { return "adult or crude content" }
        return ModRules.refused(name: mod.name, category: mod.category, description: description)
    }
}

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
    /// The mods shown: none that Browse Mods does not offer, none GameBanana rates as mature, none adult or crude by their own words
    var shown: [GBMod] { list.filter { ModRules.refused(name: $0.name, category: $0.category) == nil && !$0.mature && !ModRules.adult("\($0.name)\n\($0.category)\n\($0.words)") } }
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
        guard let url = f.download, d.refused == nil else { return }
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
            // the folder that holds the mod (ModsModel.modFolder); none marked: past wrapping folders, so that a download of the game's files as they are is taken whole
            var src = ModsModel.modFolder(in: out)
            if src == out { while ModsModel.subdirs(src).count == 1 { src = ModsModel.subdirs(src)[0] } }
            if let why = ModRules.refused(files: out) { status = "Not installed: this mod \(why == "replaces the game's code" ? "replaces the game's code" : "contains \(why)")."; return }
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Mods for \(mods.game.name)"; w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.minSize = NSSize(width: 820, height: 560)   // the game's art runs under the title bar
        w.contentView = NSHostingView(rootView: ModBrowserView(model: ModBrowserModel(mods: mods)))
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in open[key] = nil; mods.reload() }
        open[key] = w
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct ModBrowserView: View {
    @StateObject var model: ModBrowserModel
    @ObservedObject private var details = DetailsStore.shared
    /// The game's own art for the banner (the shelf's wallpaper of it), when Cartridge has one
    private var art: NSImage? { Titles.shared.all.first { $0.game?.id == model.game.id }.flatMap { details.wall($0) } }
    var body: some View {
        VStack(spacing: 0) {
            banner
            if model.gb == nil { pickGame } else { grid }
            footer
        }
        .background(Brand.ink)
        .environment(\.colorScheme, .dark)
        .task { await model.start() }
        .sheet(item: Binding(get: { model.detail.map { DetailBox(d: $0) } }, set: { if $0 == nil { model.detail = nil } })) { box in ModDetailView(model: model, d: box.d) }
    }
    /// The game's art across the top, darkened to the window's ink, with its name and the search, sort and progress over it
    var banner: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                Color.clear.frame(height: 170).frame(maxWidth: .infinity).overlay {
                    if let art { Image(nsImage: art).resizable().scaledToFill() }
                    else { LinearGradient(colors: [Brand.cyan.opacity(0.5), Brand.red.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing) }
                }
            }
            .clipped()
            .overlay(LinearGradient(colors: [Brand.ink.opacity(0.15), Brand.ink.opacity(0.65), Brand.ink], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.gb == nil ? "Which game on GameBanana?" : "Mods").font(.custom("Avenir Next", size: 30).weight(.heavy))
                    if let g = model.gb {
                        Text(g.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                        if model.isEdition { Text("Switch version mods").font(.system(size: 11, weight: .heavy)).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Brand.red.opacity(0.85))) }
                        Button("Change Game") { model.gb = nil }.buttonStyle(.link).font(.callout)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }
                if model.gb != nil {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search mods", text: $model.search).textFieldStyle(.plain).onSubmit { Task { await model.reload() } }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7).frame(width: 260)
                        .background(.ultraThinMaterial, in: Capsule())
                        Picker("", selection: $model.sort) { ForEach(ModBrowserModel.Sort.allCases, id: \.self) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 420).onChange(of: model.sort) { Task { await model.reload() } }
                        Spacer()
                        if model.total > 0 { Text("\(model.total) on GameBanana").font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(.horizontal, 22).padding(.bottom, 14)
        }
    }
    var pickGame: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.games) { g in
                    Button { model.choose(g); Task { await model.reload() } } label: {
                        HStack { Text(g.name).font(.system(size: 14, weight: .semibold)); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                            .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                    }.buttonStyle(.plain)
                }
            }.padding(22)
        }
    }
    var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.isEdition {
                    Label("These mods were made for the Switch version. When you turn one on, Cartridge carries its changes over to this edition where it can.", systemImage: "arrow.triangle.branch")
                        .font(.callout).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)], spacing: 18) {
                    ForEach(model.shown) { m in ModCard(m: m) { Task { await model.open(m) } } }
                }
                if model.hasMore {
                    HStack { Spacer(); Button("Show More") { Task { await model.more() } }.controlSize(.large); Spacer() }.padding(.top, 6)
                }
            }
            .padding(22)
        }
    }
    var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(Brand.cyan)
            Text("Mods come straight from GameBanana, made by their authors. Not offered: adult or crude mods, mods that replace the game's code, unlock paid content, are console system tools, or cheat online.")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            if let s = model.status { Text(s).font(.footnote) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial)
    }
}

/// One mod on the grid: its picture large, its name, author and counts; lit in Cartridge's colours under the pointer
struct ModCard: View {
    let m: GBMod
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                // a fixed frame the picture fills and is cut to: a picture sized by its own width pushed the cards out of their columns
                Color.white.opacity(0.05).frame(height: 150).frame(maxWidth: .infinity)
                    .overlay {
                        AsyncImage(url: m.thumb) { $0.resizable().scaledToFill() } placeholder: {
                            Image(systemName: "puzzlepiece.extension.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.25))
                        }
                    }
                    .clipped()
                VStack(alignment: .leading, spacing: 5) {
                    Text(m.name).font(.system(size: 14, weight: .bold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Text("by \(m.author)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 12) {
                        Label("\(m.likes)", systemImage: "heart.fill").foregroundStyle(Brand.red.opacity(0.9))
                        Label(m.views.formatted(.number.notation(.compactName)), systemImage: "eye.fill")
                        Spacer()
                        if let u = m.updated { Text(u, format: .dateTime.month(.abbreviated).year()) }
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hover ? 0.09 : 0.055)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                hover ? AnyShapeStyle(LinearGradient(colors: [Brand.cyan, Brand.red], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.white.opacity(0.08)), lineWidth: hover ? 2 : 1))
            .shadow(color: Brand.cyan.opacity(hover ? 0.3 : 0), radius: 16, y: 6)
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
private struct DetailBox: Identifiable { let d: GBDetail; var id: Int { d.mod.id } }

struct ModDetailView: View {
    @ObservedObject var model: ModBrowserModel
    let d: GBDetail
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.frame(height: 200).frame(maxWidth: .infinity)
                    .overlay { AsyncImage(url: d.mod.thumb) { $0.resizable().scaledToFill() } placeholder: { LinearGradient(colors: [Brand.cyan.opacity(0.4), Brand.red.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing) } }
                    .clipped()
                    .overlay(LinearGradient(colors: [.clear, Brand.ink.opacity(0.7), Brand.ink], startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.mod.name).font(.custom("Avenir Next", size: 24).weight(.heavy))
                    Text("by \(d.authors.joined(separator: ", "))").foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 12) {
                if !d.description.isEmpty { Text(d.description).font(.callout) }
                if let p = d.mod.page { Link("Open on GameBanana", destination: p).font(.callout) }
                Text("FILES").font(.system(size: 11, weight: .heavy)).tracking(2).foregroundStyle(.secondary).padding(.top, 4)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(d.files) { f in
                            HStack {
                                Image(systemName: "shippingbox.fill").foregroundStyle(Brand.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.name).font(.system(size: 13, weight: .semibold))
                                    Text([f.version.isEmpty ? nil : "Version \(f.version)", ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file), f.about.isEmpty ? nil : f.about]
                                            .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let why = d.refused { Text("Not offered: \(why)").font(.caption).foregroundStyle(.secondary) }
                                else if model.installing == f.id { ProgressView().controlSize(.small) }
                                else { Button("Install") { Task { await model.install(f, of: d) } }.buttonStyle(.borderedProminent).tint(Brand.cyan.opacity(0.8)).disabled(model.installing != nil) }
                            }
                            .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                        }
                    }
                }.frame(minHeight: 120)
                if let s = model.status { Text(s).font(.footnote) }
                HStack {
                    Text("Installed mods start off. A mod that replaces the game's code can't be used and isn't installed.").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
        }
        .background(Brand.ink).environment(\.colorScheme, .dark)
        .frame(minWidth: 640, minHeight: 520)
    }
}
