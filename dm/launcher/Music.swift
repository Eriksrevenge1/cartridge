// Each game's music for its page, and the player that plays it. The page shows only the track's name.
//   Switch games   a background-music stream from the game's own files (its app's romfs.img, dm/tools/romfs_image.py's format): a Nintendo BWAV stream (DSP-ADPCM
//                  or PCM16) decoded here, or, in a game whose music is a Wwise package (.pck), one of its streams through vgmstream-cli when it is installed
//                  (Homebrew's vgmstream). Named from its file ("BGM_LonLonRanch" → "Lon Lon Ranch"); a Wwise stream has no name, so the game's
//   Other games    the audio of the game's first trailer in Steam's store (its HLS audio, the first segments), named by the game
// A minute and a half at most, kept in the game's details folder (Meta.swift) as music.caf or music.mp4, with music.json naming it. Fetched only while Find art,
// details and music online is on; a Switch game's music is read from its own files and needs no network.
import AppKit
import AVFoundation
import Foundation

struct Track: Codable, Equatable { var name: String; var file: String }

enum MusicFinder {
    static let seconds = 90.0

    static func track(_ t: Title) -> Track? {
        guard let d = try? Data(contentsOf: DetailsStore.folder(t).appendingPathComponent("music.json")) else { return nil }
        return try? JSONDecoder().decode(Track.self, from: d)
    }
    /// Finds and keeps the game's track when it has none yet (an empty music.json marks a game that has none, so it is not looked for again for a month)
    static func ensure(_ t: Title) async -> Track? {
        let dir = DetailsStore.folder(t), meta = dir.appendingPathComponent("music.json")
        if let a = try? FileManager.default.attributesOfItem(atPath: meta.path), let m = a[.modificationDate] as? Date, Date().timeIntervalSince(m) < 30 * 86400 { return track(t) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var found: Track?
        if let g = t.game { found = fromGame(g, title: t.name, dir: dir) }
        else if DetailsStore.online, let e = t.external {
            var id: Int?
            if e.store == .steam { id = Int(e.id.split(separator: ":")[1].split(separator: "@")[0]) } else { id = await DetailsStore.steamSearch(e.name) }
            if let id { found = await trailer(id, name: t.name, dir: dir) }
        }
        try? (found.flatMap { try? JSONEncoder().encode($0) } ?? Data()).write(to: meta)
        return found
    }

    // MARK: from the game's files

    /// The game's RomFS images: romfs.img, and each program's of a game made of several (romfs_programs/<n>.img: Xenoblade Chronicles: Definitive Edition's data is in one)
    static func images(_ g: Game) -> [RomImage] {
        let res = g.contents.appendingPathComponent("Resources")
        let programs = children(res.appendingPathComponent("romfs_programs")).filter { $0.pathExtension == "img" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return ([res.appendingPathComponent("romfs.img")] + programs).compactMap(RomImage.init)
    }
    static func fromGame(_ g: Game, title: String, dir: URL) -> Track? {
        for rom in images(g) { if let t = fromImage(rom, title: title, dir: dir) { return t } }
        return nil
    }
    static func fromImage(_ rom: RomImage, title: String, dir: URL) -> Track? {
        // BWAV streams that are music: background music by name, the long ones, not jingles, bosses or scenes
        let streams = rom.files.filter { $0.path.lowercased().hasSuffix(".bwav") && isMusic($0.path) }
        if let best = streams.max(by: { score($0) < score($1) }), let data = rom.read(best, max: 40 << 20), let pcm = BWAV.decode(data, seconds: seconds) {
            let out = dir.appendingPathComponent("music.caf")
            if write(pcm, to: out) { return Track(name: prettify(best.path), file: "music.caf") }
        }
        // Wwise: one of the music package's streams through vgmstream
        if let pck = rom.files.filter({ $0.path.lowercased().hasSuffix(".pck") && ["bgm", "music"].contains(where: $0.path.lowercased().contains) }).max(by: { $0.size < $1.size }),
           let tool = ["/opt/homebrew/bin/vgmstream-cli", "/usr/local/bin/vgmstream-cli"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
           let wem = AKPK.pick(rom, pck) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cartridge-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp.appendingPathExtension("wem")); try? FileManager.default.removeItem(at: tmp.appendingPathExtension("wav")) }
            guard (try? wem.write(to: tmp.appendingPathExtension("wem"))) != nil else { return nil }
            let p = Process(); p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = ["-i", "-o", tmp.appendingPathExtension("wav").path, tmp.appendingPathExtension("wem").path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            if let f = try? AVAudioFile(forReading: tmp.appendingPathExtension("wav")), let pcm = read(f, seconds: seconds), write(pcm, to: dir.appendingPathComponent("music.caf")) {
                return Track(name: title, file: "music.caf")
            }
        }
        return nil
    }
    static func isMusic(_ path: String) -> Bool {
        let n = (path as NSString).lastPathComponent.lowercased()
        return n.contains("bgm") || n.hasPrefix("zn_") || n.hasPrefix("strm_bgm") || n.contains("music")
    }
    static func score(_ f: RomImage.File) -> Double {
        let n = (f.path as NSString).lastPathComponent.lowercased()
        var s = 0.0
        for w in ["title", "main", "theme", "field", "opening", "menu", "hub", "town", "ranch", "village", "home", "basic"] where n.contains(w) { s += 4 }
        for w in ["boss", "battle", "fanfare", "jingle", "gameover", "result", "short", "intro", "outro", "_dm_", "dm_", "minigame", "shop", "vocal", "noise", "ending", "credit", "staff"] where n.contains(w) { s -= 5 }
        let mb = Double(f.size) / 1_048_576
        s += mb >= 2 && mb <= 16 ? 2 : -2
        return s + min(mb, 12) / 12
    }
    /// A stream's file name as a title: prefixes and numbers off, words split ("BGM_LonLonRanch" → "Lon Lon Ranch", "Zn_HillLevel_Basic" → "Hill Level")
    static func prettify(_ path: String) -> String {
        var n = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        for p in ["BGM_", "Bgm_", "bgm_", "Zn_", "STRM_BGM_", "Strm_"] where n.hasPrefix(p) { n = String(n.dropFirst(p.count)) }
        var words: [String] = []
        for raw in n.split(separator: "_") {
            let part = raw.reversed().drop(while: \.isNumber).reversed()   // "Main1" → "Main"
            if part.isEmpty || ["basic", "loop", "a", "b", "c", "main", "strm"].contains(String(part).lowercased()) { continue }
            var w = ""
            for c in part {
                if c.isUppercase, let last = w.last, last.isLowercase { words.append(w); w = "" }
                w.append(c)
            }
            if !w.isEmpty { words.append(w) }
        }
        return words.isEmpty ? n : words.joined(separator: " ")
    }

    // MARK: a Steam trailer's audio

    static func trailer(_ id: Int, name: String, dir: URL) async -> Track? {
        guard let (data, _) = await DetailsStore.get("https://store.steampowered.com/api/appdetails?appids=\(id)&l=english"),
              let app = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["\(id)"] as? [String: Any])?["data"] as? [String: Any],
              let movie = (app["movies"] as? [[String: Any]])?.first, let master = movie["hls_h264"] as? String,
              let (mdata, murl) = await DetailsStore.get(master) else { return nil }
        let mtext = String(decoding: mdata, as: UTF8.self)
        guard let audio = mtext.components(separatedBy: "\n").first(where: { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }),
              let uri = audio.components(separatedBy: "URI=\"").dropFirst().first?.components(separatedBy: "\"").first,
              let plURL = URL(string: uri, relativeTo: murl), let (pdata, purl) = await DetailsStore.get(plURL.absoluteString) else { return nil }
        let lines = String(decoding: pdata, as: UTF8.self).components(separatedBy: "\n")
        var parts: [URL] = []
        if let mapLine = lines.first(where: { $0.hasPrefix("#EXT-X-MAP:") }), let u = mapLine.components(separatedBy: "URI=\"").dropFirst().first?.components(separatedBy: "\"").first {
            URL(string: u, relativeTo: purl).map { parts.append($0) }
        }
        var total = 0.0
        for (i, l) in lines.enumerated() where l.hasPrefix("#EXTINF:") && total < seconds {
            total += Double(l.dropFirst(8).split(separator: ",").first ?? "0") ?? 0
            if i + 1 < lines.count, let u = URL(string: lines[i + 1], relativeTo: purl) { parts.append(u) }
        }
        var out = Data()
        for p in parts { guard let (d, _) = await DetailsStore.get(p.absoluteString) else { return nil }; out.append(d) }
        guard out.count > 10_000, (try? out.write(to: dir.appendingPathComponent("music.mp4"))) != nil else { return nil }
        return Track(name: name, file: "music.mp4")
    }

    // MARK: audio files

    static func read(_ f: AVAudioFile, seconds: Double) -> AVAudioPCMBuffer? {
        let n = AVAudioFrameCount(min(Double(f.length), seconds * f.processingFormat.sampleRate))
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n), (try? f.read(into: b, frameCount: n)) != nil else { return nil }
        return b
    }
    /// Written with a short fade at each end, so a loop or a cut never clicks
    static func write(_ b: AVAudioPCMBuffer, to url: URL) -> Bool {
        let n = Int(b.frameLength), fade = min(n / 4, Int(b.format.sampleRate * 1.5))
        if let ch = b.floatChannelData {
            for c in 0..<Int(b.format.channelCount) {
                for i in 0..<fade { let g = Float(i) / Float(fade); ch[c][i] *= g; ch[c][n - 1 - i] *= g }
            }
        }
        try? FileManager.default.removeItem(at: url)
        guard let f = try? AVAudioFile(forWriting: url, settings: b.format.settings) else { return false }
        return (try? f.write(from: b)) != nil
    }
}

/// A packed RomFS image (dm/tools/romfs_image.py): its files' paths, offsets and sizes, read without copying the image
final class RomImage {
    struct File { let path: String; let offset: UInt64; let size: UInt64 }
    let files: [File]
    private let handle: FileHandle
    init?(_ url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 32), head.count == 32, head.prefix(8) == Data("DMROMFS1".utf8) else { return nil }
        func u64(_ d: Data, _ o: Int) -> UInt64 { d.subdata(in: o..<o + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
        let at = u64(head, 8), size = u64(head, 16), count = Int(u64(head, 24))
        guard size < 1 << 30, (try? h.seek(toOffset: at)) != nil, let idx = try? h.read(upToCount: Int(size)), idx.count == Int(size), count * 24 <= idx.count else { return nil }
        let pool = idx.subdata(in: count * 24..<idx.count)
        struct E { let a: UInt64, b: UInt64, name: String, dir: Bool }
        let ents: [E] = (0..<count).map { i in
            let o = i * 24
            let nOff = Int(idx.subdata(in: o + 16..<o + 20).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let nLen = Int(idx.subdata(in: o + 20..<o + 22).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
            let name = nOff + nLen <= pool.count ? String(decoding: pool.subdata(in: nOff..<nOff + nLen), as: UTF8.self) : ""
            return E(a: u64(idx, o), b: u64(idx, o + 8), name: name, dir: idx[o + 22] == 0)
        }
        var out: [File] = [], queue: [(Int, String)] = [(0, "")]
        while !queue.isEmpty {
            let (i, path) = queue.removeFirst()
            guard ents.indices.contains(i), ents[i].dir else { continue }
            let first = Int(ents[i].a), n = Int(ents[i].b)
            guard first >= 0, n >= 0, first + n <= ents.count else { continue }
            for k in first..<first + n {
                let p = path.isEmpty ? ents[k].name : path + "/" + ents[k].name
                if ents[k].dir { queue.append((k, p)) } else { out.append(File(path: p, offset: ents[k].a, size: ents[k].b)) }
            }
        }
        files = out; handle = h
    }
    func read(_ f: File, max: Int) -> Data? { read(at: f.offset, count: Int(min(f.size, UInt64(max)))) }
    func read(at: UInt64, count: Int) -> Data? { (try? handle.seek(toOffset: at)).flatMap { try? handle.read(upToCount: count) } }
    deinit { try? handle.close() }
}

/// Wwise's AKPK package inside a RomFS image: its stream table, and one stream to play (one of a usual song's size: 3 to 8 MB, a few minutes of Opus)
enum AKPK {
    static func pick(_ rom: RomImage, _ pck: RomImage.File) -> Data? {
        guard let head = rom.read(at: pck.offset, count: 28), head.prefix(4) == Data("AKPK".utf8) else { return nil }
        func u32(_ d: Data, _ o: Int) -> Int { Int(d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
        let hsize = u32(head, 4), lang = u32(head, 12), banks = u32(head, 16), sounds = u32(head, 20)
        let base = hsize - 16 - (lang + banks + sounds) >= 8 ? 28 : 24
        guard let table = rom.read(at: pck.offset + UInt64(base + lang + banks), count: sounds), table.count == sounds else { return nil }
        let n = u32(table, 0)
        var streams: [(size: Int, offset: Int)] = []
        for i in 0..<n where 4 + i * 20 + 20 <= table.count {
            let o = 4 + i * 20
            streams.append((u32(table, o + 8), u32(table, o + 12) * max(1, u32(table, o + 4))))
        }
        let songs = streams.filter { $0.size >= 3 << 20 && $0.size <= 8 << 20 }.sorted { $0.size > $1.size }
        guard let s = songs.dropFirst(songs.count / 3).first ?? streams.max(by: { $0.size < $1.size }) else { return nil }
        return rom.read(at: pck.offset + UInt64(s.offset), count: s.size)
    }
}

/// Nintendo's BWAV stream: a header, one 0x4C-byte record per channel (codec 0 PCM16, 1 DSP-ADPCM; sample rate; sample count; DSP coefficients; data offset)
enum BWAV {
    static func decode(_ d: Data, seconds: Double) -> AVAudioPCMBuffer? {
        guard d.count > 0x60, d.prefix(4) == Data("BWAV".utf8) else { return nil }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> AVAudioPCMBuffer? in
            let b = raw.bindMemory(to: UInt8.self)
            func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
            func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
            let channels = min(2, u16(0x0E))
            guard channels > 0 else { return nil }
            let rate = u32(0x10 + 4), total = u32(0x10 + 8)
            let count = min(total, Int(seconds * Double(rate)))
            guard rate > 0, count > 0, let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2),
                  let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)), let dst = out.floatChannelData else { return nil }
            out.frameLength = AVAudioFrameCount(count)
            for c in 0..<channels {
                let e = 0x10 + c * 0x4C, codec = u16(e), off = u32(e + 0x30)
                let coef = (0..<16).map { Int(Int16(truncatingIfNeeded: u16(e + 0x10 + $0 * 2))) }
                if codec == 0 {
                    for i in 0..<count where off + i * 2 + 1 < b.count { dst[c][i] = Float(Int16(truncatingIfNeeded: u16(off + i * 2))) / 32768 }
                } else if codec == 1 {
                    var h1 = 0, h2 = 0, s = 0, p = off
                    while s < count && p + 8 <= b.count {
                        let ps = Int(b[p]), scale = 1 << (ps & 15), pr = (ps >> 4) & 7
                        let c1 = coef[pr * 2], c2 = coef[pr * 2 + 1]
                        for i in 0..<14 where s < count {
                            var nib = i & 1 == 1 ? Int(b[p + 1 + i / 2] & 15) : Int(b[p + 1 + i / 2] >> 4)
                            if nib >= 8 { nib -= 16 }
                            let v = max(-32768, min(32767, (((nib * scale) << 11) + 1024 + c1 * h1 + c2 * h2) >> 11))
                            h2 = h1; h1 = v; dst[c][s] = Float(v) / 32768; s += 1
                        }
                        p += 8
                    }
                } else { return nil }   // Opus and others: not decoded here
            }
            if channels == 1 { for i in 0..<count { dst[1][i] = dst[0][i] } }
            return out
        }
    }
}

/// Plays the chosen game's track on its page: fades in, fades to the next game's, quiet while a game runs or Cartridge is in the background
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()
    @Published private(set) var now: Track?
    private var player: AVAudioPlayer?
    private var want: String?
    static var on: Bool { UserDefaults.standard.object(forKey: "music.on") as? Bool ?? true }
    static var volume: Float { UserDefaults.standard.object(forKey: "music.volume") as? Float ?? 0.6 }
    static var fade: TimeInterval { [0.4, 1.2, 2.5][UserDefaults.standard.object(forKey: "music.fade") as? Int ?? 1] }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.pause() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.resume() }
    }

    /// The game whose page is in front (nil: none)
    func play(_ t: Title?) {
        guard let t, MusicPlayer.on else { stop(); return }
        want = t.id
        Task { @MainActor in
            let track = await MusicFinder.ensure(t)
            guard self.want == t.id else { return }
            guard let track, let p = try? AVAudioPlayer(contentsOf: DetailsStore.folder(t).appendingPathComponent(track.file)) else { self.stop(); return }
            let old = self.player
            old?.setVolume(0, fadeDuration: MusicPlayer.fade)
            DispatchQueue.main.asyncAfter(deadline: .now() + MusicPlayer.fade) { old?.stop() }
            p.numberOfLoops = -1; p.volume = 0
            guard NSApp.isActive, Titles.shared.runningExternal.isEmpty, Library.shared.running.isEmpty else { self.player = p; self.now = track; return }
            p.play(); p.setVolume(MusicPlayer.volume, fadeDuration: MusicPlayer.fade)
            self.player = p; self.now = track
        }
    }
    func stop() { want = nil; let p = player; p?.setVolume(0, fadeDuration: 0.4); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { p?.stop() }; player = nil; now = nil }
    func pause() { player?.setVolume(0, fadeDuration: 0.3); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.player?.pause() } }
    func resume() {
        guard let p = player, MusicPlayer.on, Titles.shared.runningExternal.isEmpty, Library.shared.running.isEmpty else { return }
        p.play(); p.setVolume(MusicPlayer.volume, fadeDuration: MusicPlayer.fade)
    }
}
