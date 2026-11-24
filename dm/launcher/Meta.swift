// Each game's details for the home and its page: a wallpaper (the game's own art or a scene from it, never its box art), its logo, cover, screenshots, what it is
// about, genres, who made it and when. Kept on this Mac (<Application Support>/Cartridge/details/<id>/), fetched once in the background and again after 30 days,
// only while Settings › Library & sources › Find art, details and music online is on (the default). What is sent: a Switch game's title ID (to nintendo.com, as Find
// Cover does), a Steam game's app ID, or another launcher's game's name (to Steam's store search and Wikipedia). Nothing about the player.
//   Steam games     Steam's own cache on this Mac first (appcache/librarycache/<id>: library_hero, logo, capsule), then the store's appdetails (text, screenshots)
//   Switch games    Nintendo Europe's page for the title ID: excerpt, genres, publisher, release date, screenshots; a screenshot is the wallpaper (its key art has the logo)
//   Other launchers Steam's store when a game of the same name is there (most PC games are), else Wikipedia's summary
import AppKit
import Foundation
import Vision

struct Details: Codable, Equatable {
    var about: String?
    var genres: [String] = []
    var maker: String?
    var released: String?
    var wall: String?          // file names in the game's details folder
    var logo: String?
    var cover: String?
    var shots: [String] = []
    var storePage: String?
    var fetched = Date()
    var chosenWall: String?    // the player's own choice (Choose Wallpaper…), kept when the details are looked up again
    var walls: [String]?       // the good wallpapers, best first: the home turns to the next every few minutes
    var compat: String?        // a bottle game's rating from ProtonDB's players (platinum, gold, silver, bronze, borked): Proton and CrossOver are both Wine
}

final class DetailsStore: ObservableObject {
    static let shared = DetailsStore()
    @Published private(set) var version = 0
    private var memory: [String: Details] = [:]
    private var images: [String: NSImage] = [:]
    private var busy = Set<String>()
    static var online: Bool { UserDefaults.standard.object(forKey: "details.online") as? Bool ?? true }
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cartridge/details") }
    static func folder(_ t: Title) -> URL { root.appendingPathComponent(t.id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")) }

    func details(_ t: Title) -> Details? {
        if let d = memory[t.id] { return d }
        guard let data = try? Data(contentsOf: DetailsStore.folder(t).appendingPathComponent("details.json")), let d = try? JSONDecoder().decode(Details.self, from: data) else { return nil }
        memory[t.id] = d
        return d
    }
    func image(_ t: Title, _ name: String?) -> NSImage? {
        guard let name else { return nil }
        let key = t.id + "/" + name
        if let i = images[key] { return i }
        let i = NSImage(contentsOf: DetailsStore.folder(t).appendingPathComponent(name))
        images[key] = i
        return i
    }
    func wall(_ t: Title) -> NSImage? { image(t, wallName(t)) }
    func wallName(_ t: Title) -> String? {
        guard let d = details(t) else { return nil }
        if let c = d.chosenWall { return c }
        guard let pool = d.walls, pool.count > 1 else { return d.wall }
        return pool[(turn[t.id] ?? 0) % pool.count]
    }
    /// Which of each game's wallpapers is showing (an index into its pool), turned by the home every few minutes
    private var turn: [String: Int] = [:]
    /// The next of the game's good wallpapers; false when it has one (or the player pinned one)
    @discardableResult func nextWall(_ t: Title) -> Bool {
        guard let d = details(t), d.chosenWall == nil, let pool = d.walls, pool.count > 1 else { return false }
        turn[t.id] = ((turn[t.id] ?? 0) + 1) % pool.count
        _ = wallCG(t)   // decoded now, so the change cross-fades at once
        version += 1
        return true
    }
    /// Every picture that can be the wallpaper: the store's (the wallpaper and the screenshots), in the game's details folder
    func wallCandidates(_ t: Title) -> [URL] {
        guard let d = details(t) else { return [] }
        return ([d.chosenWall, d.wall].compactMap { $0 } + d.shots).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.map { DetailsStore.folder(t).appendingPathComponent($0) }
    }
    /// The player's wallpaper for the game: a picture from anywhere (copied into the game's details folder), or nil for the automatic one
    func choose(_ t: Title, wallpaper src: URL?) {
        guard var d = details(t) else { return }
        if let src {
            let dir = DetailsStore.folder(t), name = src.deletingLastPathComponent() == dir ? src.lastPathComponent : "chosen-\(UUID().uuidString.prefix(6)).\(src.pathExtension.isEmpty ? "jpg" : src.pathExtension)"
            if src.deletingLastPathComponent() != dir { try? FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(name)) }
            d.chosenWall = name
        } else { d.chosenWall = nil }
        memory[t.id] = d; walls = walls.filter { !$0.key.hasPrefix(t.id + "/") }
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: DetailsStore.folder(t).appendingPathComponent("details.json")) }
        version += 1
    }
    /// The wallpaper decoded at its full size (an NSImage can be drawn from a smaller representation), kept while Cartridge runs
    func wallCG(_ t: Title) -> CGImage? {
        guard let name = wallName(t) else { return nil }
        let key = t.id + "/" + name
        if let c = walls[key] { return c }
        let u = DetailsStore.folder(t).appendingPathComponent(name)
        // at the largest screen's pixel width (and a little more for the drift): a 4K picture on a smaller screen is decoded smaller, once
        let px = (NSScreen.screens.map { $0.frame.width * $0.backingScaleFactor }.max() ?? 2560) * 1.1
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let c = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: px,
                                                                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        walls[key] = c
        return c
    }
    private var walls: [String: CGImage] = [:]
    func logo(_ t: Title) -> NSImage? { image(t, details(t)?.logo) }
    func shots(_ t: Title) -> [NSImage] { (details(t)?.shots ?? []).compactMap { image(t, $0) } }

    /// Looks the game up when it has no details yet or they are a month old
    func ensure(_ t: Title) {
        if let d = details(t), Date().timeIntervalSince(d.fetched) < 30 * 86400 { return }
        guard !busy.contains(t.id) else { return }
        busy.insert(t.id)
        Task.detached(priority: .utility) {
            let d = await DetailsStore.fetch(t)
            await MainActor.run {
                self.busy.remove(t.id)
                guard var d else { return }
                d.chosenWall = self.details(t)?.chosenWall
                self.memory[t.id] = d
                self.images = self.images.filter { !$0.key.hasPrefix(t.id + "/") }
                if let data = try? JSONEncoder().encode(d) { try? data.write(to: DetailsStore.folder(t).appendingPathComponent("details.json")) }
                self.version += 1
            }
        }
    }

    // MARK: fetching

    static func fetch(_ t: Title) async -> Details? {
        let dir = folder(t)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var d = Details()
        if let g = t.game {
            guard online else { return nil }
            await nintendo(g.titleID.lowercased(), name: g.title, into: &d, dir: dir)
            await launchBox(name: g.title, platforms: g.isSwitch2 ? ["Nintendo Switch 2", "Nintendo Switch"] : ["Nintendo Switch", "Nintendo Switch 2"], into: &d, dir: dir)
        } else if let e = t.external {
            if e.store == .steam, let id = Int(e.id.split(separator: ":")[1].split(separator: "@")[0]) {
                steamLocal(id, into: &d, dir: dir)
                if online { await steam(id, into: &d, dir: dir) }
                // in a bottle: how well it runs under Wine, as ProtonDB's players report it (only the app ID is sent)
                if online, e.runtime == .crossover || e.runtime == .whisky, let (data, _) = await get("https://www.protondb.com/api/v1/reports/summaries/\(id).json"),
                   let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tier = j["tier"] as? String { d.compat = tier }
            } else if online {
                if let id = await steamSearch(e.name) { await steam(id, into: &d, dir: dir, art: true) }
                if d.about == nil { await wikipedia(e.name, into: &d, dir: dir) }
            }
            if online { await launchBox(name: e.name, platforms: ["Windows", "Apple Mac OS"], into: &d, dir: dir) }
            // the game's own icon as its cover when nothing better was found
            if d.cover == nil, let app = e.app, let png = NSWorkspace.shared.icon(forFile: app).png(512) { try? png.write(to: dir.appendingPathComponent("icon.png")); d.cover = "icon.png" }
        }
        return d.about == nil && d.wall == nil && d.cover == nil ? nil : d
    }

    static func get(_ s: String, timeout: Double = 20) async -> (Data, URL)? {
        guard let u = URL(string: s) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: timeout); r.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (data, resp.url ?? u)
    }
    /// Downloads a picture into the game's folder; its file name, or nil
    static func save(_ url: String, _ name: String, _ dir: URL) async -> String? {
        guard let (data, _) = await get(url, timeout: 40), NSImage(data: data) != nil else { return nil }
        let file = name + "." + (URL(string: url)?.pathExtension.lowercased().prefix(4).description ?? "jpg")
        return (try? data.write(to: dir.appendingPathComponent(file))) != nil ? file : nil
    }

    /// Steam's cache on this Mac: each picture of the game Steam keeps for its own library (no network)
    static func steamLocal(_ id: Int, into d: inout Details, dir: URL) {
        let cache = Places.mac.support.appendingPathComponent("Steam/appcache/librarycache/\(id)")
        guard let e = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil) else { return }
        for case let f as URL in e {
            let n = f.lastPathComponent
            let slot: String? = n == "library_hero.jpg" ? "wall" : n == "logo.png" ? "logo" : (n == "library_600x900.jpg" || n == "library_capsule.jpg") ? "cover" : nil
            guard let slot else { continue }
            let file = slot + "." + f.pathExtension
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            guard (try? FileManager.default.copyItem(at: f, to: dir.appendingPathComponent(file))) != nil else { continue }
            switch slot { case "wall": d.wall = file; case "logo": d.logo = file; default: d.cover = file }
        }
    }
    /// The store's details for an app ID; its hero, logo and capsule too when `art` (a game Steam's cache does not have)
    static func steam(_ id: Int, into d: inout Details, dir: URL, art: Bool = false) async {
        if art || d.wall == nil { d.wall = await save("https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_hero.jpg", "wall", dir) ?? d.wall }
        if art || d.logo == nil { d.logo = await save("https://cdn.akamai.steamstatic.com/steam/apps/\(id)/logo.png", "logo", dir) ?? d.logo }
        if art || d.cover == nil { d.cover = await save("https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_600x900.jpg", "cover", dir) ?? d.cover }
        guard let (data, _) = await get("https://store.steampowered.com/api/appdetails?appids=\(id)&l=english"),
              let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let app = (top["\(id)"] as? [String: Any])?["data"] as? [String: Any] else { return }
        d.about = (app["short_description"] as? String).map(clean)
        d.genres = ((app["genres"] as? [[String: Any]]) ?? []).compactMap { $0["description"] as? String }
        d.maker = (app["developers"] as? [String])?.first
        d.released = (app["release_date"] as? [String: Any])?["date"] as? String
        d.storePage = "https://store.steampowered.com/app/\(id)"
        var shots: [String] = []
        for (i, s) in ((app["screenshots"] as? [[String: Any]]) ?? []).prefix(6).enumerated() {
            if let u = s["path_full"] as? String, let f = await save(u, "shot\(i)", dir) { shots.append(f) }
        }
        d.shots = shots
    }
    /// A game of exactly this name in Steam's store (punctuation and case aside)
    static func steamSearch(_ name: String) async -> Int? {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let (data, _) = await get("https://store.steampowered.com/api/storesearch/?term=\(q)&l=english&cc=US"),
              let items = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["items"] as? [[String: Any]] else { return nil }
        let want = norm(name)
        return items.first { norm($0["name"] as? String ?? "") == want }?["id"] as? Int
    }
    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func wikipedia(_ name: String, into d: inout Details, dir: URL) async {
        let q = name.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let (data, _) = await get("https://en.wikipedia.org/api/rest_v1/page/summary/\(q)"),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], (j["type"] as? String) != "disambiguation" else { return }
        d.about = j["extract"] as? String
        if d.cover == nil, let img = (j["originalimage"] as? [String: Any])?["source"] as? String { d.cover = await save(img, "cover", dir) }
    }

    /// LaunchBox's background art (up to four), its transparent logo when there is none yet, and its text where the store gave none; then the wallpaper is chosen
    /// again among everything the game has: background art first when it is as good (it is made to be one), the store's pictures otherwise
    static func launchBox(name: String, platforms: [String], into d: inout Details, dir: URL) async {
        guard let e = await LaunchBox.shared.entry(name: name, platforms: platforms) else { return }
        if d.about == nil { d.about = e.overview }
        if d.maker == nil { d.maker = e.developer }
        if d.released == nil { d.released = e.released.map { String($0.prefix(10)) } }
        // the game's logo: shown on its label when it has none yet, and looked for on every picture below (art with the logo printed on it is a poster, not a
        // wallpaper, and the window's edges cut the logo off)
        var clearLogo: String?
        if let f = e.images.first(where: { $0[0] == "Clear Logo" })?[1] { clearLogo = await save("https://images.launchbox-app.com/\(f)", "lblogo", dir) }
        if d.logo == nil { d.logo = clearLogo }
        let logoPrint = clearLogo.flatMap { LogoFinder(logo: dir.appendingPathComponent($0)) }
        // a square cover for the cartridge's label (a Steam capsule or a box is tall and would be cropped), when it has one
        if let f = e.images.first(where: { $0[0] == "Square" })?[1], let sq = await save("https://images.launchbox-app.com/\(f)", "square", dir) { d.cover = sq }
        // its background art, judged as it arrives: until eight good pieces (enough to turn through for half an hour) or the art runs out (World of Warcraft has
        // nearly forty pieces, of which most are posters, logos or close-ups); a rejected piece is deleted at once
        var art: [String] = [], artScores: [String: Double] = [:]
        for (i, img) in e.images.filter({ $0[0] == "Fanart - Background" }).prefix(48).enumerated() {
            guard let f = await save("https://images.launchbox-app.com/\(img[1])", "art\(i)", dir) else { continue }
            let u = dir.appendingPathComponent(f)
            let score = logoPrint?.found(in: u) == true ? -1 : wallpaperScore(u, art: true) + 1.5
            if score < 1.5 { try? FileManager.default.removeItem(at: u); continue }
            art.append(f); artScores[f] = score
            if art.count >= 8 { break }
        }
        // its gameplay screenshots too (many are 4K captures): more pictures to turn through
        var shots: [String] = []
        // (none for an online world: the player wants its art, never its screenshots)
        for (i, img) in e.images.filter({ $0[0] == "Screenshot - Gameplay" && !DetailsStore.isMMO(d) }).prefix(4).enumerated() {
            if let f = await save("https://images.launchbox-app.com/\(img[1])", "lbshot\(i)", dir) { shots.append(f) }
        }
        d.shots += shots
        guard !art.isEmpty || !shots.isEmpty else { return }
        var scores: [String: Double] = [:]
        for f in art { scores[f] = artScores[f] }   // made to be a background: ahead (by 1.5) when it is about as good
        for f in [d.wall].compactMap({ $0 }) + d.shots { scores[f] = wallpaperScore(dir.appendingPathComponent(f)) }
        if let lp = logoPrint { for (f, _) in scores where lp.found(in: dir.appendingPathComponent(f)) { scores[f] = -1 } }
        // below this, none of them makes a good wallpaper (a collage, a logo on a plain colour, a close-up): the game gets its colours' backdrop instead
        guard let best = scores.max(by: { $0.value < $1.value }), best.value >= 1.5 else {
            for f in art { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
            if let w = d.wall, (scores[w] ?? 0) < 1.5 { d.shots.insert(w, at: 0); d.wall = nil }
            d.walls = d.wall.map { [$0] }
            return
        }
        d.walls = pool(scores, art: Set(art), dir: dir, shots: !DetailsStore.isMMO(d))
        if let old = d.wall, old != best.key, !art.contains(old) { d.shots.insert(old, at: 0) }
        d.wall = best.key
        d.shots.removeAll { $0 == best.key }
        // the page shows the game's screenshots and, of the art, only what made the wallpapers: art that failed (a drawing on a plain page, another release's
        // poster, a collage) is not this game's look and is deleted
        let keep = Set(d.walls ?? [])
        for f in art where !keep.contains(f) && f != best.key { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        d.shots = art.filter { keep.contains($0) && $0 != best.key } + d.shots.filter { !art.contains($0) }
    }

    /// The wallpapers to turn through: the good art (made to be a background) best first; a screenshot only for a game with no good art (a screenshot can carry
    /// the game's interface, which nothing here can see, and the player wants art where there is art); a picture that looks like one already in it (the same screenshot from two places) once
    /// An online world (World of Warcraft, Final Fantasy XIV): its screenshots are a crowd of other players, names and the game's interface, so it never gets a
    /// screenshot as its wallpaper, only art (or its colours' backdrop). Known by its genres or its description
    static func isMMO(_ d: Details) -> Bool {
        let text = (d.genres.joined(separator: " ") + " " + (d.about ?? "")).lowercased()
        return text.contains("massively multiplayer") || text.contains("mmorpg") || text.contains("mmo ")
    }

    static func pool(_ scores: [String: Double], art: Set<String>, dir: URL, shots: Bool = true) -> [String] {
        // art from 1.5, a screenshot only from 3 (one that just passes is often a close-up or busy with the game's interface)
        let good = scores.filter { $0.value >= (art.contains($0.key) ? 1.5 : 3) }.sorted { $0.value > $1.value }.map(\.key)
        var out: [String] = [], prints: [UInt64] = []
        for f in good.filter(art.contains) + (shots ? good.filter({ !art.contains($0) }) : []) {
            if !art.contains(f) && out.count >= 1 { break }   // a screenshot only when the game has no good art at all
            let fp = fingerprint(dir.appendingPathComponent(f))
            if prints.contains(where: { ($0 ^ fp).nonzeroBitCount <= 6 }) { continue }
            prints.append(fp); out.append(f)
            if out.count == 8 { break }
        }
        return out
    }
    /// A picture's look in 64 bits (8×8 grey, each pixel above or below the mean): two copies of one picture differ by a few bits
    static func fingerprint(_ u: URL) -> UInt64 {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary),
              let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let mean = (0..<64).reduce(0) { $0 + Int(p[$1]) } / 64
        return (0..<64).reduce(UInt64(0)) { $0 | (Int(p[$1]) > mean ? UInt64(1) << UInt64($1) : 0) }
    }

    /// Nintendo Europe: the page the eShop's redirect for the title ID lands on, and the search index's record for it
    static func nintendo(_ tid: String, name: String, into d: inout Details, dir: URL) async {
        // the eShop's redirect for the title ID; a Switch 2 Edition's own ID has none, so then the store's search for the name (its Switch 2 page first)
        var page = await get("https://ec.nintendo.com/apps/\(tid)/GB")
        var record: [String: Any]?
        if page == nil || page?.1.host?.contains("nintendo.com") != true || page?.1.absoluteString.contains("ec.nintendo.com") == true {
            let q = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
            if let (data, _) = await get("https://searching.nintendo-europe.com/en/select?q=\(q)&fq=type:GAME&rows=5&wt=json"),
               let docs = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["response"] as? [String: Any])?["docs"] as? [[String: Any]] {
                let want = DetailsStore.norm(name)
                let fit = docs.filter { DetailsStore.norm($0["title"] as? String ?? "").hasPrefix(want.prefix(12)) }
                let pick = fit.first { ($0["system_names_txt"] as? [String])?.contains("Nintendo Switch 2") == true } ?? fit.first
                if let path = pick?["url"] as? String { page = await get("https://www.nintendo.com" + path); record = pick }
            }
        }
        guard let (pageData, landed) = page, landed.host?.contains("nintendo.com") == true else { return }
        let html = String(decoding: pageData, as: UTF8.self)
        d.storePage = landed.absoluteString
        if let nsuid = URLComponents(url: landed, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "nsuid" })?.value,
           let (data, _) = await get("https://searching.nintendo-europe.com/en/select?q=*&fq=nsuid_txt:\(nsuid)&rows=1&wt=json"),
           let doc = ((((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["response"] as? [String: Any])?["docs"] as? [[String: Any]])?.first {
            record = doc
        }
        if let doc = record {
            d.about = doc["excerpt"] as? String
            d.genres = (doc["pretty_game_categories_txt"] as? [String]) ?? []
            d.maker = doc["publisher"] as? String
            d.released = doc["pretty_date_s"] as? String
        }
        // the page's screenshots (full size, not the ones with the trademark line); the first is the wallpaper
        let re = try! NSRegularExpression(pattern: #"https://www\.nintendo\.com/eu/media/images/(?:06_screenshots|assets)/[^"'\s)]+?_\d\d\.(?:jpg|png)"#)
        var urls: [String] = []
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let u = String(html[Range(m.range, in: html)!])
            let low = u.lowercased()
            // screenshots only: not the trademark-lined copies, characters, banners, logos or box art
            if !u.contains("TM_Standard") && !urls.contains(u)
                && !["character", "_char", "sideimg", "carousel", "banner", "logo", "packshot", "boxart", "render", "amiibo", "icon"].contains(where: low.contains) { urls.append(u) }
        }
        // what Nintendo names a screenshot (or keeps in its screenshot and gallery folders) first; pictures drawn for the page after
        func shotLike(_ u: String) -> Bool { let l = u.lowercased(); return ["screenshot", "_scr_", "06_screenshots", "/gallery/", "nswitch"].contains(where: l.contains) }
        urls = urls.filter(shotLike) + urls.filter { !shotLike($0) }
        var shots: [String] = []
        for (i, u) in urls.prefix(16).enumerated() { if let f = await save(u, "shot\(i)", dir) { shots.append(f) } }
        // the wallpaper: the most scenic of them (a character drawn on black or white makes a poor one), the rest stay screenshots
        let scores = Dictionary(uniqueKeysWithValues: shots.map { ($0, wallpaperScore(dir.appendingPathComponent($0))) })
        let ranked = shots.sorted { scores[$0]! > scores[$1]! }
        d.wall = ranked.first
        d.walls = pool(scores, art: [], dir: dir, shots: !DetailsStore.isMMO(d))
        // the page keeps eight more, in the store's order; the others are deleted
        let keep = Set(ranked.prefix(9))
        for f in shots where !keep.contains(f) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        d.shots = shots.filter { keep.contains($0) && $0 != d.wall }
    }
}

/// How good a picture is as a wallpaper, by macOS's own image understanding (Vision, on this Mac): a scene (sky, landscape, buildings, water, forest) counts for
/// it; people, faces and bodies filling the frame count against it (a close-up of a character makes a poor wallpaper); anything narrower than 1920 pixels is out
func wallpaperScore(_ u: URL, art: Bool = false) -> Double {
    guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
          let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any], let w = props[kCGImagePropertyPixelWidth] as? Int else { return -100 }
    guard w >= 1920 else { return -50 + Double(w) / 100 }
    let scenic: Set<String> = ["outdoor", "landscape", "sky", "blue_sky", "cloudy", "mountain", "forest", "grass", "field", "land", "water", "lake", "ocean", "beach", "structure", "building",
                               "castle", "tree", "sunset_sunrise", "plant", "canyon", "cliff", "desert", "snow", "river", "waterfall", "city", "night_sky", "path", "bridge", "ruins", "rocks"]
    let persons: Set<String> = ["people", "adult", "child", "portrait", "selfie", "face", "costume"]
    let handler = VNImageRequestHandler(cgImage: img)
    let cls = VNClassifyImageRequest(), faces = VNDetectFaceRectanglesRequest(), humans = VNDetectHumanRectanglesRequest(), words = VNRecognizeTextRequest()
    let salient = VNGenerateObjectnessBasedSaliencyImageRequest(), rects = VNDetectRectanglesRequest()
    rects.maximumObservations = 16; rects.minimumSize = 0.1; rects.minimumConfidence = 0.6
    words.recognitionLevel = .fast
    try? handler.perform([cls, faces, humans, words, salient, rects])
    // a close-up: one subject filling much of the frame (drawn characters' faces are not found as faces, but their size is)
    let subject = Double((salient.results?.first?.salientObjects ?? []).map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0)
    // half for art made to be a background: a character there is meant to be in it, in a screenshot it is a close-up
    let closeUp = max(0, subject - 0.3) * (art ? 4 : 8)
    // a logo, a title or a collage's captions: the area covered by text
    let text = Double((words.results ?? []).map { $0.boundingBox.width * $0.boundingBox.height }.reduce(0, +))
    // a banner much wider than a screen is cropped and enlarged to fill it
    let h = props[kCGImagePropertyPixelHeight] as? Int ?? w
    let wide = Double(w) / Double(max(h, 1)) > 2.2 ? 1.5 : 0
    let obs = cls.results ?? []
    let scene = Double(obs.filter { scenic.contains($0.identifier) }.map(\.confidence).reduce(0, +))
    let people = Double(obs.filter { persons.contains($0.identifier) }.map(\.confidence).reduce(0, +))
    let face = Double((faces.results ?? []).map { $0.boundingBox.width * $0.boundingBox.height }.reduce(0, +))
    let body = Double((humans.results ?? []).map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0)
    // a screenshot with the game's interface over it (maps, names, numbers) reads as a document or a screenshot
    let hud = Double(obs.filter { ["screenshot", "document", "text", "videogame"].contains($0.identifier) }.map(\.confidence).reduce(0, +))
    // and a game's interface is many small labels (a map's names, a clock, button hints), which their area alone hardly counts
    let labels = Double(words.results?.count ?? 0)
    if labels >= 3 { return min(0, scene - 0.6 * labels) }   // a screenshot with the game's interface on it is never a wallpaper
    if art {
        // community art: much of it is a scene painted for a wallpaper, but some is a character on a plain colour, a collage of cards, a logo poster or a pattern.
        // Measured on 25 pieces: every one of those shows almost no scene (below 0.25), carries text (a logo Vision can read), holds several framed pictures,
        // or has empty edges; the painted scenes pass all four. The ones that pass are ranked by how much scene they show
        let collage = (rects.results?.count ?? 0) >= 2
        if scene < 0.25 || labels >= 1 || collage || edgeFill(img) < 0.5 { return -1 }
        return 1.5 + 0.8 * scene - 30 * max(0, face - 0.03) - 10 * max(0, subject - 0.6) - wide + (w >= 3000 ? 0.5 : 0)
    }
    return scene - 1.5 * people - 40 * face - 3 * body - 2 * hud - 25 * text - 0.6 * labels - wide - closeUp + (w >= 3000 ? 0.5 : 0)
}

/// Finds a game's logo printed on a picture: the logo (its transparent Clear Logo, flattened on dark grey) against the places logos sit — the top and bottom
/// centre, the corners, the middle — at three sizes, by Vision's image likeness. Measured on 37 pieces of World of Warcraft art: the 7 with the logo came within
/// 0.39–0.73 of it, the others no closer than 1.13
struct LogoFinder {
    let logo: VNFeaturePrintObservation
    let aspect: Double
    init?(logo url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let flat = ctx.makeImage(), let p = LogoFinder.featurePrint(flat) else { return nil }
        logo = p; aspect = Double(img.width) / Double(max(img.height, 1))
    }
    static func featurePrint(_ img: CGImage) -> VNFeaturePrintObservation? {
        let r = VNGenerateImageFeaturePrintRequest(); try? VNImageRequestHandler(cgImage: img).perform([r]); return r.results?.first
    }
    func found(in url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary) else { return false }
        let W = Double(img.width), H = Double(img.height)
        for frac in [0.22, 0.3, 0.4] {
            let w = W * frac, h = min(H, w / aspect)
            for (x, y) in [((W - w) / 2, 0.0), ((W - w) / 2, H - h), (W - w, H - h), (0.0, 0.0), ((W - w) / 2, (H - h) / 2)] {
                guard let crop = img.cropping(to: CGRect(x: x, y: y, width: w, height: h)), let f = LogoFinder.featurePrint(crop) else { continue }
                var d = Float(9); try? f.computeDistance(&d, to: logo)
                if d < 0.9 { return true }
            }
        }
        return false
    }
}

/// The share of a picture's edge (at 32×32) that is neither near black nor near white: a scene reaches its edges, a character drawn on an empty page does not
func edgeFill(_ img: CGImage) -> Double {
    guard let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: 32, height: 32))
    guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return 1 }
    var filled = 0.0, n = 0.0
    for y in 0..<32 { for x in 0..<32 where x < 2 || x > 29 || y < 2 || y > 29 {
        let i = (y * 32 + x) * 4, hi = max(p[i], p[i + 1], p[i + 2]), lo = min(p[i], p[i + 1], p[i + 2])
        n += 1; if hi > 30 && lo < 230 { filled += 1 }
    } }
    return filled / max(n, 1)
}

extension NSImage {
    func png(_ size: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
