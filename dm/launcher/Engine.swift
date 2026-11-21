// The engine Cartridge carries (scripts/build_launcher.py: Resources/engine.tar, the repository's files without docs; Resources/python.tar, a standalone Python with the
// NSP script's modules), unpacked once per version into <games folder's drive>/…/.cartridge-engine/<version>/ (beside the games folder: builds write into it, a compiled
// host per game profile, and the home drive is kept free), then used by every build. Settings › Building can point builds at your own nxnative checkout and Python
// instead (for working on nxnative itself). Older versions stay beside it (Updates installs new ones the same way); Xcode is still needed (the Setup Assistant)
import Foundation

final class Engine: ObservableObject {
    static let shared = Engine()
    @Published var status = ""       // what the engine is doing, for the Build window and the Setup Assistant
    @Published private(set) var installedDir: URL?
    private let store = UserDefaults.standard

    let version: String? = Bundle.main.infoDictionary?["DMEngine"] as? String
    private var res: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }
    var bundled: Bool { version != nil && FileManager.default.fileExists(atPath: res.appendingPathComponent("engine.tar").path) }
    /// Builds use the engine Cartridge carries (on by default when it carries one); off: your own checkout and Python (Settings › Building)
    var builtIn: Bool {
        get { bundled && (store.object(forKey: "engine.builtIn") as? Bool ?? true) }
        set { store.set(newValue, forKey: "engine.builtIn"); objectWillChange.send() }
    }
    /// Where versions are unpacked: beside the games folder, else the folder chosen for it
    var parent: URL? {
        if let p = store.string(forKey: "engine.parent") { return URL(fileURLWithPath: p) }
        return GamesFolder.root?.appendingPathComponent(".cartridge-engine")
    }
    var dir: URL? { guard let parent, let version else { return nil }; return parent.appendingPathComponent(version) }
    var python: URL? { dir?.appendingPathComponent("python/bin/python3") }
    private var marker: URL? { dir?.appendingPathComponent(".installed") }
    var isInstalled: Bool { marker.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    init() { if isInstalled { installedDir = dir } }

    /// Versions kept: this one and the newest other (to go back to); older ones, and unfinished unpacks, are removed (about 1 GB each)
    static func prune(_ parent: URL, keep: URL) {
        let fm = FileManager.default
        let all = ((try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.lastPathComponent != keep.lastPathComponent }
        let dated = all.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }.sorted { $0.1 > $1.1 }
        let finished = dated.filter { $0.0.pathExtension != "partial" && fm.fileExists(atPath: $0.0.appendingPathComponent(".installed").path) }
        for (u, _) in dated where u.pathExtension == "partial" || !finished.prefix(1).contains(where: { $0.0 == u }) { try? fm.removeItem(at: u) }
    }
    /// Unpacked if it is not yet (in the background); a finished one is used by the next build
    func ensure() {
        guard builtIn, !isInstalled, status.isEmpty else { if isInstalled { installedDir = dir }; return }
        guard let dir, let parent else { status = "Choose a games folder (Setup Assistant): the engine is unpacked on its drive."; return }
        if let free = Builder.freeSpace(at: parent), free < 3_000_000_000 {
            status = String(format: "Only %.1f GB free on the games folder's drive: the engine needs about 2 GB.", Double(free) / 1e9); return
        }
        status = "Unpacking the engine \(version ?? "")…"
        let res = self.res
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default, part = dir.appendingPathExtension("partial")
            try? fm.removeItem(at: part)
            var ok = (try? fm.createDirectory(at: part, withIntermediateDirectories: true)) != nil
            for t in ["engine.tar", "python.tar"] where ok { ok = shell("/usr/bin/tar", ["-x", "-f", res.appendingPathComponent(t).path, "-C", part.path]).0 == 0 }
            if ok { try? fm.removeItem(at: dir); ok = (try? fm.moveItem(at: part, to: dir)) != nil }
            if ok { ok = fm.createFile(atPath: dir.appendingPathComponent(".installed").path, contents: Data()) }
            if ok { Engine.prune(parent, keep: dir) }
            DispatchQueue.main.async {
                self.status = ok ? "" : "The engine could not be unpacked into \(dir.path)."
                if ok { self.installedDir = dir }
            }
        }
    }
}
