// High-resolution art for the library from the LaunchBox Games Database (gamesdb.launchbox-app.com): its community's background art ("Fanart - Background", most of
// it 1920 to 3840 pixels wide, without logos), transparent logos ("Clear Logo") and gameplay screenshots, for every platform: Switch, PC, Mac. LaunchBox publishes
// the whole database as one file (Metadata.zip, about 110 MB, the one its own app downloads). Cartridge downloads it once a month, reads it as it unpacks (nothing
// unpacked is kept), keeps only the records of the games on the shelf (<Application Support>/Cartridge/details/launchbox.json), and fetches the chosen pictures
// themselves from images.launchbox-app.com. Only while Find art, details and music online is on.
import Foundation

struct LBEntry: Codable {
    var id: String
    var platform: String
    var overview: String?
    var developer: String?
    var released: String?
    var images: [[String]] = []   // [type, file]
}

final class LaunchBox {
    static let shared = LaunchBox()
    private var index: [String: [LBEntry]]?
    private var building: Task<Void, Never>?
    private var file: URL { DetailsStore.root.appendingPathComponent("launchbox.json") }
    private struct Stored: Codable { var built: Date; var names: [String]; var games: [String: [LBEntry]] }

    static func norm(_ s: String) -> String {
        var n = s
        for cut in [" – Nintendo Switch 2 Edition", " - Nintendo Switch 2 Edition", " Nintendo Switch 2 Edition", "™", "®"] { n = n.replacingOccurrences(of: cut, with: "") }
        return n.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The record for a game, by name, preferring the platform it is played on here
    func entry(name: String, platforms: [String]) async -> LBEntry? {
        await ensure()
        guard let list = index?[LaunchBox.norm(name)], !list.isEmpty else { return nil }
        // the game's records on the platforms it is played on here, the preferred one first: a Switch 2 Edition's record often has one picture and the Switch
        // game's twenty, and both are the same game's art. Another platform's record (Ocarina of Time on the Nintendo 64) only when these have none
        let mine = platforms.flatMap { p in list.filter { $0.platform == p } }
        guard var e = mine.first ?? list.max(by: { $0.images.count < $1.images.count }) else { return nil }
        if !mine.isEmpty {
            // then the same game's background art on other platforms (Ocarina of Time's paintings are filed under the Nintendo 64): the same game's art
            let others = list.filter { o in !mine.contains { $0.id == o.id } }.flatMap { $0.images.filter { $0[0] == "Fanart - Background" } }
            e.images = mine.flatMap(\.images) + others
            e.overview = mine.compactMap(\.overview).first; e.developer = mine.compactMap(\.developer).first; e.released = mine.compactMap(\.released).first
        }
        return e
    }

    /// The index for the games on the shelf: kept for a month, built again sooner when a game on the shelf is not in it
    private func ensure() async {
        if let b = building { await b.value; return }
        let names = Set(await MainActor.run { Titles.shared.all.map { LaunchBox.norm($0.name) } })
        if index == nil, let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            if Date().timeIntervalSince(s.built) < 30 * 86400 && names.isSubset(of: Set(s.names)) { index = s.games; return }
            index = s.games   // usable meanwhile
        } else if index != nil { return }
        let t = Task.detached(priority: .utility) { [file] in
            guard let games = await LaunchBox.build(names) else { return }
            if let d = try? JSONEncoder().encode(Stored(built: Date(), names: Array(names), games: games)) { try? d.write(to: file) }
            await MainActor.run { LaunchBox.shared.index = games }
        }
        building = t
        await t.value
        building = nil
    }

    /// Downloads Metadata.zip and reads Metadata.xml out of it as it unpacks, keeping the games named on the shelf
    static func build(_ names: Set<String>) async -> [String: [LBEntry]]? {
        guard DetailsStore.online, let url = URL(string: "https://gamesdb.launchbox-app.com/Metadata.zip") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 600); r.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (zip, resp) = try? await URLSession.shared.download(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        defer { try? FileManager.default.removeItem(at: zip) }
        let unzip = Process(), pipe = Pipe()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", zip.path, "Metadata.xml"]
        unzip.standardOutput = pipe; unzip.standardError = FileHandle.nullDevice
        guard (try? unzip.run()) != nil, let stream = InputStream(fileAtPath: "/dev/fd/\(pipe.fileHandleForReading.fileDescriptor)") else { return nil }
        let reader = Reader(names: names)
        let parser = XMLParser(stream: stream)
        parser.delegate = reader
        parser.parse()
        unzip.waitUntilExit()
        var out: [String: [LBEntry]] = [:]
        for (n, list) in reader.games {
            out[n] = list.map { var e = $0; e.images = reader.images[e.id] ?? []; return e }
        }
        return out.isEmpty ? nil : out
    }

    /// Metadata.xml: <Game> records (Name, DatabaseID, Platform, Overview, Developer, ReleaseDate) and <GameImage> records (DatabaseID, FileName, Type)
    private final class Reader: NSObject, XMLParserDelegate {
        let names: Set<String>
        var games: [String: [LBEntry]] = [:]
        var images: [String: [[String]]] = [:]
        private var ids = Set<String>()
        private var fields: [String: String] = [:]
        private var text = ""
        private var inRecord = false
        static let kinds: Set<String> = ["Fanart - Background", "Clear Logo", "Screenshot - Gameplay", "Square"]
        init(names: Set<String>) { self.names = names }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if e == "Game" || e == "GameImage" { inRecord = true; fields = [:] }
            text = ""
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inRecord { text += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch e {
            case "Game":
                inRecord = false
                guard let name = fields["Name"], let id = fields["DatabaseID"] else { return }
                let n = LaunchBox.norm(name)
                guard names.contains(n) else { return }
                ids.insert(id)
                games[n, default: []].append(LBEntry(id: id, platform: fields["Platform"] ?? "", overview: fields["Overview"], developer: fields["Developer"],
                                                     released: fields["ReleaseDate"] ?? fields["ReleaseYear"]))
            case "GameImage":
                inRecord = false
                guard let id = fields["DatabaseID"], ids.contains(id), let type = fields["Type"], Reader.kinds.contains(type), let f = fields["FileName"] else { return }
                images[id, default: []].append([type, f])
            default:
                if inRecord { fields[e] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
    }
}
