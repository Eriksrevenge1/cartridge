// The games folder (Setup Assistant; Settings › Library): one folder, on the drive you choose, with a folder per game that holds all of it: your game files (NSPs, .nup,
// update and DLC, or a dump folder), the NSP script's work folders beside them (<title ID>_build, -work) and the built app, which the script puts beside its source. A new
// build's files move in when you build (the Build window's option); a game already in the library moves in when you ask (its menu). On the same drive a move is a rename,
// instant; to another drive it is a copy, so it asks first. The library always includes the folder. Folders elsewhere keep working as before
import AppKit
import Foundation

enum GamesFolder {
    static var root: URL? { UserDefaults.standard.string(forKey: "games.root").map { URL(fileURLWithPath: $0) } }
    static func set(_ u: URL) { UserDefaults.standard.set(u.path, forKey: "games.root"); Library.shared.addFolder(u) }
    static func contains(_ u: URL) -> Bool {
        guard let r = root?.standardizedFileURL.path else { return false }
        return u.standardizedFileURL.path.hasPrefix(r + "/")
    }
    /// The game's folder name from its source: the file or folder name without its extension and its [title ID][version] tags
    static func name(for source: URL) -> String {
        var n = source.hasDirectoryPath ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        n = n.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression).replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Game" : n
    }
    static func unique(_ name: String, in r: URL) -> URL {
        var u = r.appendingPathComponent(name), k = 2
        while FileManager.default.fileExists(atPath: u.path) { u = r.appendingPathComponent("\(name) \(k)"); k += 1 }
        return u
    }
    static func sameDrive(_ a: URL, _ b: URL) -> Bool {
        func vol(_ u: URL) -> NSObject? {
            var d = u; while !FileManager.default.fileExists(atPath: d.path), d.pathComponents.count > 1 { d.deleteLastPathComponent() }
            return (try? d.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let x = vol(a), let y = vol(b) else { return false }
        return x.isEqual(y)
    }
    /// Bytes in a file or folder
    static func size(_ u: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0 }
        var t: Int64 = 0
        let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        while let f = e?.nextObject() as? URL { t += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
        return t
    }
    /// A move to another drive copies: true when the player agrees (or nothing is copied)
    static func confirmCopy(_ items: [URL], to r: URL) -> Bool {
        let far = items.filter { !sameDrive($0, r) }
        guard !far.isEmpty else { return true }
        let bytes = far.reduce(0) { $0 + size($1) }
        let a = NSAlert(); a.messageText = "Copy to the games folder's drive?"
        a.informativeText = "The games folder is on another drive, so \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) will be copied there and then removed here. This can take a while."
        if let free = Builder.freeSpace(at: r), free < bytes + 5_000_000_000 {
            a.informativeText += "\n\nOnly \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) is free there."
        }
        a.addButton(withTitle: "Copy"); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// A new build's source moved in: a folder (NSPs, a dump) whole, a file (.nup, one NSP) into a folder of its own. Returns where it is now
    static func adopt(_ src: URL) throws -> URL {
        guard let r = root else { return src }
        if contains(src) { return src }
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        var isDir: ObjCBool = false; FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir)
        let dir = unique(name(for: src), in: r)
        if isDir.boolValue { try FileManager.default.moveItem(at: src, to: dir); return dir }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appendingPathComponent(src.lastPathComponent)
        try FileManager.default.moveItem(at: src, to: to)
        return to
    }
    /// What belongs to a library game beside its source: the source, the NSP script's folders for its title ID, the app and the app's pack record. A source folder that
    /// holds the app is the game's own folder: it goes whole
    static func parts(of g: Game, source: URL?) -> [URL] {
        let fm = FileManager.default
        if let s = source, s.hasDirectoryPath, g.url.path.hasPrefix(s.path + "/") { return [s] }
        let dir = source?.deletingLastPathComponent() ?? g.url.deletingLastPathComponent(), tid = g.titleID
        var out: [URL] = []
        if let s = source { out.append(s) }
        for n in ["\(tid)_build", "\(tid)-work", "\(tid)_survey"] { let u = dir.appendingPathComponent(n); if fm.fileExists(atPath: u.path) { out.append(u) } }
        out.append(g.url)
        let key = URL(fileURLWithPath: g.url.path + ".key"); if fm.fileExists(atPath: key.path) { out.append(key) }
        return Array(Set(out)).sorted { $0.path < $1.path }
    }
    /// A library game moved in, all its parts into one folder named for it; returns the source's new place (nil when it had none)
    static func move(_ g: Game, source: URL?) throws -> URL? {
        guard let r = root else { return source }
        let items = parts(of: g, source: source)
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        if items.count == 1, let only = items.first, only.hasDirectoryPath, only != g.url {   // the game's own folder
            let dir = unique(g.title.replacingOccurrences(of: ":", with: " -"), in: r)
            try FileManager.default.moveItem(at: only, to: dir)
            return dir
        }
        let dir = unique(g.title.replacingOccurrences(of: ":", with: " -"), in: r)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var newSource: URL?
        for u in items {
            let to = dir.appendingPathComponent(u.lastPathComponent)
            try FileManager.default.moveItem(at: u, to: to)
            if u == source { newSource = to }
        }
        return newSource
    }
}
