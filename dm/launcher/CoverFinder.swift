// Find Cover…: pictures for a game from Nintendo's own pages, for the player to pick one as its cover. Only when the player asks: the game's title ID (and nothing else) goes
// to nintendo.com, through the eShop's own redirect from a title ID to its store page (ec.nintendo.com/apps/<title ID>/<region>).
//  - Square key art: Nintendo Europe's page (region GB) names its wide pictures 16x9_<name> / 2x1_<name>; the square one, when there is one, is 1x1_<name> in the same folder
//    or in the matching folder of square images. Each guess is checked before it is offered.
//  - The eShop's banner and screenshots (region AU's title page): 16:9, shown cropped to the square they will fill.
// A Switch 2 Edition's own title ID has no store page; the sheet then offers a web image search (the picture is dropped on the game's header) and Choose File.
import AppKit
import SwiftUI

struct CoverCandidate: Identifiable, Hashable {
    let url: URL
    let square: Bool
    var id: URL { url }
}

final class CoverFinder: ObservableObject {
    static let shared = CoverFinder()
    @Published var game: Game?          // the game the sheet is open for
    @Published var found: [CoverCandidate] = []
    @Published var searching = false
    @Published var applying: URL?
    private var task: Task<Void, Never>?

    func open(_ g: Game) { game = g; search(g) }
    func close() { task?.cancel(); game = nil; found = []; searching = false }

    private func search(_ g: Game) {
        task?.cancel(); found = []; searching = true
        let tid = g.titleID.lowercased()
        task = Task { @MainActor in
            async let eu = CoverFinder.europe(tid)
            async let shop = CoverFinder.eshop(tid)
            let all = await eu + shop
            if Task.isCancelled { return }
            var seen = Set<URL>(); found = all.filter { seen.insert($0.url).inserted }; searching = false
        }
    }

    private static func fetch(_ u: URL) async -> (String, URL)? {
        var r = URLRequest(url: u, timeoutInterval: 20); r.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (String(decoding: d, as: UTF8.self), resp.url ?? u)
    }
    private static func exists(_ u: URL) async -> Bool {
        var r = URLRequest(url: u, timeoutInterval: 15); r.httpMethod = "HEAD"; r.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
    private static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    /// Nintendo Europe: the 1x1 sibling of each wide picture on the game's page
    static func europe(_ tid: String) async -> [CoverCandidate] {
        guard let page = URL(string: "https://ec.nintendo.com/apps/\(tid)/GB"), let (html, landed) = await fetch(page), landed.host?.contains("nintendo.com") == true,
              !landed.absoluteString.contains("ec.nintendo.com/apps") else { return [] }
        var guesses: [URL] = []
        for m in matches(#"(https://www\.nintendo\.com/eu/media/images/[^"'\s)]*/)(?:16x9|2x1)_([A-Za-z0-9_]+?)(?:_image\d+w)?\.(?:jpg|png)"#, html) {
            let folder = m[1], base = m[2]
            var options = ["\(folder)1x1_\(base).jpg"]
            // a share picture's square one sits in the square images' folder: 10_share_images/games_N/nintendo_switch_M → 11_square_images/games_N+3/nintendo_switch_M+1
            if let s = matches(#"10_share_images/games_(\d+)/nintendo_switch_(\d+)/"#, folder).first, let g = Int(s[1]), let n = Int(s[2]) {
                options.append(folder.replacingOccurrences(of: s[0], with: "11_square_images/games_\(g + 3)/nintendo_switch_\(n + 1)/") + "1x1_\(base).jpg")
            }
            for o in options { if let u = URL(string: o), !guesses.contains(u) { guesses.append(u) } }
        }
        var out: [CoverCandidate] = []
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (i, u) in guesses.prefix(12).enumerated() { group.addTask { (i, await exists(u) ? u : nil) } }
            var hits: [(Int, URL)] = []
            for await (i, u) in group { if let u { hits.append((i, u)) } }
            out = hits.sorted { $0.0 < $1.0 }.map { CoverCandidate(url: $0.1, square: true) }
        }
        return out.filter { !$0.url.lastPathComponent.contains("CharactersHub") }   // a character page's picture, not the game's
    }

    /// The eShop's title page: its banner first, then a few screenshots
    static func eshop(_ tid: String) async -> [CoverCandidate] {
        guard let page = URL(string: "https://ec.nintendo.com/apps/\(tid)/AU"), let (html, _) = await fetch(page) else { return [] }
        var urls: [String] = []
        for key in ["heroBannerUrl", "og:image"] {
            for m in matches(#"\#(key)[^h]{0,40}(https://img-eshop\.cdn\.nintendo\.net/i/[0-9a-f]{64}\.jpg)"#, html) where !urls.contains(m[1]) { urls.append(m[1]) }
            if !urls.isEmpty { break }
        }
        for m in matches(#"(https://img-eshop\.cdn\.nintendo\.net/i/[0-9a-f]{64}\.jpg)"#, html) where !urls.contains(m[1]) && urls.count < 6 { urls.append(m[1]) }
        return urls.compactMap(URL.init(string:)).map { CoverCandidate(url: $0, square: false) }
    }

    /// The picked picture becomes the game's cover
    func apply(_ c: CoverCandidate, to g: Game) {
        applying = c.url
        Task { @MainActor in
            defer { applying = nil }
            guard let (d, resp) = try? await URLSession.shared.data(from: c.url), (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-cover-\(UUID().uuidString).img")
            guard (try? d.write(to: tmp)) != nil else { return }
            Covers.shared.setCustom(g, from: tmp); try? FileManager.default.removeItem(at: tmp)
            close()
        }
    }
}

/// The Find Cover sheet
struct CoverFinderSheet: View {
    @ObservedObject var finder = CoverFinder.shared
    let game: Game
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Covers for \(game.title)").font(.title2.bold())
                Spacer()
                if finder.searching { ProgressView().controlSize(.small); Text("Looking on nintendo.com…").foregroundStyle(.secondary) }
            }
            Text("From Nintendo's store pages for this game. Square art first; wide pictures are shown as the tile will crop them. Click one to use it.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                if !finder.searching && finder.found.isEmpty {
                    ContentUnavailableView("Nothing found", systemImage: "photo.on.rectangle.angled",
                                           description: Text("Nintendo's store has no page for this title ID (a Switch 2 Edition has none of its own). Search the web, then drop the picture on the game's header."))
                        .padding(.top, 30)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                    ForEach(finder.found) { c in
                        Button { finder.apply(c, to: game) } label: {
                            VStack(spacing: 6) {
                                Color.clear.aspectRatio(1, contentMode: .fit)
                                    .overlay(AsyncImage(url: c.url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { ProgressView() })
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay { if finder.applying == c.url { ProgressView().padding(10).background(.thinMaterial, in: Circle()) } }
                                Text(c.square ? "Square art" : "Banner, cropped").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain).disabled(finder.applying != nil)
                    }
                }
                .padding(2)
            }
            HStack {
                Button("Search the Web…") {
                    let q = "\(game.title) Nintendo Switch box art".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let u = URL(string: "https://duckduckgo.com/?q=\(q)&iax=images&ia=images") { NSWorkspace.shared.open(u) }
                }
                Button("Choose File…") { finder.close(); chooseCover(game) }
                Spacer()
                Button("Cancel") { finder.close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 640, height: 560)
    }
}
