// What Cartridge's widget shows (dm/launcher/widget/Widget.swift): the library's games, most recently played first, with a cover thumbnail each, written to
// <Application Support>/nxnative/cartridge/ after every scan, cover change and game end. The widget is sandboxed and reads only that folder.
import AppKit
import WidgetKit

enum RecentFile {
    static var dir: URL { Game.supportRoot.appendingPathComponent("cartridge") }

    static func write(_ games: [Game]) {
        let played = games.filter { Stats.shared.of($0).last != nil }
            .sorted { (Stats.shared.of($0).last ?? .distantPast) > (Stats.shared.of($1).last ?? .distantPast) }
        var seen = Set<String>()
        let list = (played.isEmpty ? games : played).filter { seen.insert($0.titleID).inserted }.prefix(8)
        let covers = dir.appendingPathComponent("covers")
        try? FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        for g in list { thumb(Covers.shared.image(g), to: covers.appendingPathComponent("\(g.titleID).png")) }
        let rows: [[String: Any]] = list.map { g in
            var r: [String: Any] = ["titleID": g.titleID, "title": g.title]
            if let l = Stats.shared.of(g).last { r["last"] = l.timeIntervalSince1970 }
            return r
        }
        if let d = try? JSONSerialization.data(withJSONObject: rows) { try? d.write(to: dir.appendingPathComponent("recent.json"), options: .atomic) }
        WidgetCenter.shared.reloadAllTimelines()
    }
    /// 256 × 256 PNG of the art, written only when it differs
    private static func thumb(_ img: NSImage, to u: URL) {
        let n = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        // fill the square, as the tiles do
        let s = img.size, k = max(Double(n) / max(s.width, 1), Double(n) / max(s.height, 1))
        let w = s.width * k, h = s.height * k
        img.draw(in: NSRect(x: (Double(n) - w) / 2, y: (Double(n) - h) / 2, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        if (try? Data(contentsOf: u)) != png { try? png.write(to: u, options: .atomic) }
    }
}
