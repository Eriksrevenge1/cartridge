// Building a game from the launcher: scripts/build_ipa_from_nsp.py with --progress json (docs/frontends.md, Building: the NSP script), one build after the other. A Mac app
// joins the library when it is done (its folder is added); an IPA is shown in Finder, for the player to sideload. Each build's source is remembered by title ID, so a game in the
// library can be built again (Rebuild) after a game update or a newer nxnative; a game the launcher did not build is rebuilt from the source beside its app (rebuildRequest).
import AppKit
import SwiftUI

enum BuildTarget: String, CaseIterable, Identifiable {
    case mac = "mac-app", ios = "ios"
    var id: String { rawValue }
    var label: String { self == .mac ? "Mac app" : "iPhone / iPad (IPA)" }
}

struct BuildRequest: Identifiable, Hashable {
    let id = UUID()
    var source: URL           // the NSP folder, a dump folder, or a .nup file
    var target: BuildTarget
    var outFolder: URL?       // nil: beside the source, as the script does
    var language = ""         // "" = the script's default
    var romfsSeparate = false // IPA: the game files stay out of the IPA (push_romfs.sh)
    var seenShaders = false   // Mac: only the shaders the playtests used
    var prebake = true        // Mac app: the prewarm list's pipelines made here
    var fallbackIcon: URL?    // --fallback-icon: a rebuilt app keeps the icon it had when the game has none of its own (a dump, a NUP without one)
}

final class BuildJob: ObservableObject, Identifiable {
    let id = UUID()
    var request: BuildRequest
    var artTried = false   // the store's artwork was looked for (storeArt)
    @Published var stage = "Waiting"
    @Published var step = ""
    @Published var stageK = 0
    @Published var stageN = 0
    @Published var frac: Double?
    @Published var eta: Double?
    @Published var lines: [String] = []
    @Published var gameName: String?
    @Published var titleID: String?
    @Published var out: URL?
    @Published var icon: NSImage?
    @Published var state: State = .waiting
    enum State: Equatable { case waiting, running, done, failed(String), cancelled }
    fileprivate var process: Process?
    init(_ r: BuildRequest) { request = r }
    var title: String { gameName ?? request.source.lastPathComponent }
    var overall: Double? {   // the stages done plus this one's fraction
        guard stageN > 0 else { return nil }
        return (Double(max(stageK - 1, 0)) + (frac ?? 0)) / Double(stageN)
    }
}

final class Builder: ObservableObject {
    @Published var jobs: [BuildJob] = []
    @Published var keys: String { didSet { store.set(keys, forKey: "build.keys") } }
    @Published var repo: String { didSet { store.set(repo, forKey: "build.repo") } }
    @Published var python: String { didSet { store.set(python, forKey: "build.python") } }
    private let store = UserDefaults.standard
    weak var library: Library?
    weak var devices: Devices?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        keys = store.string(forKey: "build.keys") ?? ""
        repo = store.string(forKey: "build.repo") ?? (info["DMRepo"] as? String ?? "")
        python = store.string(forKey: "build.python") ?? (info["DMPython"] as? String ?? "/usr/bin/python3")
        // the Setup Assistant writes these settings itself: picked up here as they change, so Settings › Building and the Build window show the new ones at once
        watch = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for (k, cur, set) in [("build.keys", self.keys, { (v: String) in self.keys = v }), ("build.repo", self.repo, { self.repo = $0 }), ("build.python", self.python, { self.python = $0 })] {
                if let v = self.store.string(forKey: k), v != cur { set(v) }
            }
        }
    }
    private var watch: NSObjectProtocol?

    /// What builds run: the engine Cartridge carries, once unpacked (Engine.swift), else your own checkout and Python (Settings › Building)
    var runRepo: String { Engine.shared.builtIn ? (Engine.shared.installedDir?.path ?? "") : repo }
    var runPython: String { Engine.shared.builtIn ? (Engine.shared.python?.path ?? "") : python }
    var script: URL { URL(fileURLWithPath: runRepo).appendingPathComponent("scripts/build_ipa_from_nsp.py") }
    var ready: String? {   // why a build cannot start, or nil
        if !FileManager.default.fileExists(atPath: script.path) { return "Set the nxnative repository folder (Build Settings): \(script.path) is missing." }
        if Engine.shared.builtIn && Engine.shared.installedDir == nil { return Engine.shared.status.isEmpty ? "The engine is not unpacked yet." : Engine.shared.status }
        if !FileManager.default.isExecutableFile(atPath: runPython) { return "Set Python (Build Settings): \(runPython) is not a program." }
        return nil
    }
    func needsKeys(_ u: URL) -> Bool {   // NSPs need prod.keys; a .nup and a dump folder do not
        if u.pathExtension.lowercased() == "nup" { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []
        return names.contains { $0.lowercased().hasSuffix(".nsp") || $0.lowercased().hasSuffix(".xci") }
    }

    /// The source of the last build of each game, by title ID: a library game's Rebuild
    func source(of titleID: String) -> BuildRequest? {
        guard let d = store.dictionary(forKey: "build.sources")?[titleID] as? [String: String], let s = d["source"], let t = BuildTarget(rawValue: d["target"] ?? "") else { return nil }
        return BuildRequest(source: URL(fileURLWithPath: s), target: t, outFolder: d["out"].map { URL(fileURLWithPath: $0) }, language: d["language"] ?? "")
    }
    /// A library game's Rebuild: its last build's source when the launcher built it, else the source beside its app (the NSP script puts the app beside its NSP folder's
    /// files, dump folder or .nup by default, so an app packed from a terminal or by another front end finds its own), else nil: the player chooses one
    func rebuildRequest(for g: Game) -> BuildRequest? {
        if let r = source(of: g.titleID), FileManager.default.fileExists(atPath: r.source.path) { return r }
        guard let s = Builder.sourceBeside(g.url.deletingLastPathComponent(), titleID: g.titleID) else { return nil }
        return BuildRequest(source: s, target: .mac)
    }
    /// The game's source in this folder: its .nup (by title ID, or the only one), else the folder itself when it holds NSPs, a dump (base/) or the game's build folder
    static func sourceBeside(_ dir: URL, titleID: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [], tid = titleID.lowercased()
        let nups = names.filter { $0.lowercased().hasSuffix(".nup") && !$0.hasPrefix("._") }
        if let n = nups.first(where: { $0.lowercased().contains(tid) }) ?? (nups.count == 1 ? nups.first : nil) { return dir.appendingPathComponent(n) }
        let game = names.contains { n in
            let l = n.lowercased()
            return !l.hasPrefix("._") && ([".nsp", ".xci", ".nsz", ".xcz"].contains { l.hasSuffix($0) } || l == "base" || l == "\(tid)_build")
        }
        return game ? dir : nil
    }
    /// The game's files hold no icon: a Switch 2 .nup, or a dump folder (base/), which have no control data
    static func carriesNoIcon(_ u: URL) -> Bool {
        if u.pathExtension.lowercased() == "nup" { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []
        return names.contains("base") || (names.contains { $0.lowercased().hasSuffix(".nup") } && !names.contains { [".nsp", ".xci", ".nsz", ".xcz"].contains(where: $0.lowercased().hasSuffix) })
    }
    /// The 16-digit title ID in a file's name, or in the name of a game file in a folder ([0400…000])
    /// The exefs folders of the game's mods that are on, in mods.txt's order (as dm/mac/launcher.c reads them at play): the code patches a build bakes in
    static func codeModFolders(_ titleID: String) -> [String] {
        let support = Game.supportRoot.appendingPathComponent(titleID)
        guard let text = try? String(contentsOf: support.appendingPathComponent("mods.txt"), encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }.compactMap { name in
            let d = support.appendingPathComponent("mods").appendingPathComponent(name).appendingPathComponent("exefs")
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir) && isDir.boolValue ? d.resolvingSymlinksInPath().path : nil
        }
    }
    static func titleID(in u: URL) -> String? {
        let names = u.hasDirectoryPath ? ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []) : [u.lastPathComponent]
        for n in names { if let r = n.range(of: #"\[[0-9A-Fa-f]{16}\]"#, options: .regularExpression) { return String(n[r].dropFirst().dropLast()).lowercased() } }
        return nil
    }
    /// The store's square key art for a title ID (else its first picture), downloaded to a temporary file; nil when the store has none or cannot be reached
    static func storeArt(_ tid: String) async -> URL? {
        async let eu = CoverFinder.europe(tid)
        async let shop = CoverFinder.eshop(tid)
        let all = await eu + shop
        guard let pick = all.first(where: \.square) ?? all.first else { return nil }
        var r = URLRequest(url: pick.url, timeoutInterval: 30); r.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, NSImage(data: d) != nil else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-art-\(tid).\(pick.url.pathExtension.isEmpty ? "jpg" : pick.url.pathExtension)")
        return (try? d.write(to: out)) != nil ? out : nil
    }
    /// The app's current icon as a PNG for --fallback-icon, so a rebuild keeps an icon the player gave a game that has none of its own; nil when the app has no icon file
    static func iconPNG(of g: Game) -> URL? {
        if Covers.icon(g) == nil, Covers.shared.hasCustom(g) { return Covers.custom(g) }   // no icon in the app, but a cover (yours, or the store's): the app takes it
        guard let info = NSDictionary(contentsOf: g.contents.appendingPathComponent("Info.plist")), let name = info["CFBundleIconFile"] as? String else { return nil }
        let icns = g.contents.appendingPathComponent("Resources").appendingPathComponent(name.hasSuffix(".icns") ? name : name + ".icns")
        guard let img = NSImage(contentsOf: icns), let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-icon-\(g.titleID).png")
        return (try? png.write(to: out)) != nil ? out : nil
    }
    /// A game's files moved (GamesFolder): its last build's source follows, so Rebuild finds them
    func setSource(_ titleID: String, to u: URL) {
        var all = store.dictionary(forKey: "build.sources") ?? [:]
        var d = (all[titleID.uppercased()] as? [String: String]) ?? ["target": BuildTarget.mac.rawValue]
        d["source"] = u.path; d.removeValue(forKey: "out")
        all[titleID.uppercased()] = d; store.set(all, forKey: "build.sources")
    }
    private func remember(_ j: BuildJob) {
        guard let tid = j.titleID else { return }
        var all = store.dictionary(forKey: "build.sources") ?? [:]
        var d = ["source": j.request.source.path, "target": j.request.target.rawValue, "language": j.request.language]
        if let o = j.request.outFolder { d["out"] = o.path }
        all[tid.uppercased()] = d; store.set(all, forKey: "build.sources")
    }

    func enqueue(_ r: BuildRequest) { jobs.append(BuildJob(r)); next() }
    func cancel(_ j: BuildJob) {
        if j.state == .waiting { j.state = .cancelled; return }
        j.process?.terminate()   // SIGTERM: the script stops its tools and exits 143
    }
    func clearFinished() { jobs.removeAll { if case .running = $0.state { return false }; return $0.state != .waiting } }

    private func next() {
        guard !jobs.contains(where: { $0.state == .running }), let j = jobs.first(where: { $0.state == .waiting }) else { return }
        if let why = ready { j.state = .failed(why); next(); return }
        if let why = Builder.lowSpace(j) { j.state = .failed(why); next(); return }
        start(j)
    }

    /// Free space on the drive the build writes to (beside the source: its <title ID>_build folder and the app or IPA). A first build of a large game writes about twice its
    /// files (the extraction, then the app or IPA); a rebuild reuses them. Below 5 GB nothing starts; below 30 GB the build starts with a warning in its lines
    static func freeSpace(at u: URL) -> Int64? {
        var d = u; while !FileManager.default.fileExists(atPath: d.path), d.pathComponents.count > 1 { d.deleteLastPathComponent() }
        return (try? d.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
            ?? (try? d.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
    }
    static func lowSpace(_ j: BuildJob) -> String? {
        let dest = j.request.outFolder ?? (j.request.source.pathExtension.lowercased() == "nup" ? j.request.source.deletingLastPathComponent() : j.request.source)
        guard let free = freeSpace(at: dest) else { return nil }
        let gb = Double(free) / 1e9
        if gb < 5 { return String(format: "Only %.1f GB free on the drive of %@: free some space and build again.", gb, dest.path) }
        if gb < 30 { j.lines.append(String(format: "⚠︎ %.0f GB free on this drive: a first build of a large game can need more.", gb)) }
        return nil
    }

    private func arguments(_ r: BuildRequest) -> [String] {
        var a = [script.path, r.source.path, "--progress", "json", "--platform", r.target.rawValue]
        if needsKeys(r.source), !keys.isEmpty { a += ["-k", keys] }
        if !r.language.isEmpty { a += ["-l", r.language] }
        if r.target == .ios && r.romfsSeparate { a += ["--romfs", "separate"] }
        if r.target == .mac && r.seenShaders { a.append("--seen-shaders") }
        if r.target == .mac && !r.prebake { a.append("--no-prebake") }
        if let i = r.fallbackIcon { a += ["--fallback-icon", i.path] }
        return a
    }

    private func start(_ j: BuildJob) {
        // A .nup or a dump folder carries no icon (no control data), and the app would have none, nor its cover: the store's artwork for the game's title ID is looked up
        // first (as Find Cover… does; only the title ID goes to nintendo.com) and given to the build as its icon. Not when an icon is given already (a rebuild keeps its own)
        if !j.artTried, j.request.fallbackIcon == nil, Builder.carriesNoIcon(j.request.source), let tid = Builder.titleID(in: j.request.source) {
            j.artTried = true; j.stage = "Looking up the game's artwork"
            Task { @MainActor in
                if let art = await Builder.storeArt(tid) { j.request.fallbackIcon = art; j.lines.append("Icon: the store's artwork for \(tid) (no icon in the game's files)") }
                else { j.lines.append("Icon: none in the game's files, and none found in the store for \(tid); use Find Cover… after the build") }
                self.start(j)
            }
            return
        }
        let r = j.request
        let p = Process()
        p.executableURL = URL(fileURLWithPath: runPython)
        p.arguments = arguments(r)
        p.currentDirectoryURL = URL(fileURLWithPath: runRepo)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")   // a GUI app's PATH lacks Homebrew's tools
        env["PYTHONUNBUFFERED"] = "1"
        // The code patches of the game's mods that are on are baked into its modules (DM_EXEFS_PATCHES: patch_nso.py rewrites the code they add like the game's own)
        if let tid = j.titleID ?? Builder.titleID(in: r.source) {
            let dirs = Builder.codeModFolders(tid.uppercased())
            if !dirs.isEmpty { env["DM_EXEFS_PATCHES"] = dirs.joined(separator: ":"); j.lines.append("Code mods baked in: \(dirs.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }.joined(separator: ", "))") }
        }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        var buffer = Data(), errText = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]; buffer.removeSubrange(buffer.startIndex...nl)
                if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { DispatchQueue.main.async { self.event(j, o) } }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if !d.isEmpty { errText.append(d) } }
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
                self.finished(j, proc.terminationStatus, String(decoding: errText.suffix(4000), as: UTF8.self))
            }
        }
        j.state = .running; j.stage = "Starting"
        if let o = r.outFolder { j.lines.append("Output folder: \(o.path)") }
        do { try p.run(); j.process = p } catch { j.state = .failed("Could not start Python: \(error.localizedDescription)"); next() }
    }

    private func event(_ j: BuildJob, _ o: [String: Any]) {
        func s(_ k: String) -> String { o[k] as? String ?? "" }
        func n(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        switch s("ev") {
        case "stage":
            j.stageK = Int(n("k") ?? 0); j.stageN = Int(n("n") ?? 0); j.stage = s("name"); j.step = s("step"); j.frac = 0; j.eta = nil
        case "step": j.step = s("step"); j.frac = nil
        case "progress": j.step = s("step"); j.frac = n("frac"); j.eta = n("eta")
        case "stage_end":
            j.lines.append("\((o["ok"] as? Bool ?? false) ? ((o["warn"] as? Bool ?? false) ? "⚠︎" : "✓") : "✗") \(s("name"))\(s("summary").isEmpty ? "" : ": " + s("summary"))")
            j.frac = 1
        case "game":
            j.gameName = s("name"); j.titleID = s("title_id")
            if let out = o["out"] as? String { j.out = URL(fileURLWithPath: out) }
            if let icon = o["icon"] as? String { j.icon = NSImage(contentsOfFile: icon) }   // read now: an IPA build deletes its extraction at the end
            remember(j)
        case "shaders_stale": j.lines.append("Shaders are built again: the translation changed (\(s("reason"))).")
        case "say": j.lines.append(s("msg"))
        default: break
        }
        if j.lines.count > 400 { j.lines.removeFirst(j.lines.count - 400) }
    }

    private func finished(_ j: BuildJob, _ status: Int32, _ stderr: String) {
        j.process = nil
        switch status {
        case 0:
            j.state = .done
            moveOutput(j)
            if let out = j.out {
                if j.request.target == .mac {
                    library?.addFolder(out.deletingLastPathComponent()); library?.scan()
                } else {
                    devices?.add(ipa: out, titleID: j.titleID, source: j.request.source.path, romfsSeparate: j.request.romfsSeparate)
                }
            }
        case 130, 143, 129: j.state = .cancelled
        default:
            let red = j.lines.last { $0.hasPrefix("[RED] ") }.map { String($0.dropFirst(6)) }
            let tail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
            j.state = .failed(red ?? (tail.isEmpty ? "The build stopped (exit \(status))." : tail))
        }
        next()
    }

    /// The build folder's logs (the script's tools write their whole output there)
    func logs(_ j: BuildJob) -> URL? {
        guard let tid = j.titleID else { return nil }
        let base = j.request.source.pathExtension.lowercased() == "nup" ? j.request.source.deletingLastPathComponent() : j.request.source
        return base.appendingPathComponent("\(tid)_build/logs")
    }
}

/// The output folder the player chose: -o takes a whole path, and the app's name is known only from the game event, so the finished app or IPA is moved there instead
extension Builder {
    func moveOutput(_ j: BuildJob) {
        guard let folder = j.request.outFolder, let out = j.out, out.deletingLastPathComponent() != folder else { return }
        let dest = folder.appendingPathComponent(out.lastPathComponent), fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.moveItem(at: out, to: dest); j.out = dest
            let key = out.appendingPathExtension("key")   // the Mac app's key file beside it (pack_app.py) goes along
            if fm.fileExists(atPath: key.path) { try? fm.moveItem(at: key, to: dest.appendingPathExtension("key")) }
        } catch { j.lines.append("[RED] Could not move the app to \(folder.path): \(error.localizedDescription)") }
    }
}

struct BuildView: View {
    @EnvironmentObject var builder: Builder
    @State private var req = BuildRequest(source: URL(fileURLWithPath: "/"), target: .mac)
    @State private var hasSource = false
    @State private var both = false
    @State private var intoFolder = true   // the game's files moved into the games folder first (GamesFolder)
    @State private var moving: String?
    // The game picked file by file: its base game (NSP, XCI, NSZ, XCZ, or a Switch 2 .nup, which is the whole game), its update and its DLC, from any folders.
    // At Build they are put in a folder of their own (assemble). A folder (NSPs, a dump) can still be the source as it is (req.source with no base file)
    @State private var baseFile: URL?
    @State private var updateFile: URL?
    @State private var dlcFiles: [URL] = []
    private var files: [URL] {   // what assemble puts together; none for a .nup or a folder
        guard let b = baseFile, b.pathExtension.lowercased() != "nup" else { return [] }
        return [b] + (updateFile.map { [$0] } ?? []) + dlcFiles
    }
    private var isNup: Bool { baseFile?.pathExtension.lowercased() == "nup" }

    var body: some View {
        HSplitView {
            Form {
                Section("Game") {
                    if baseFile == nil && hasSource {   // a folder chosen as it is
                        LabeledContent("Folder") {
                            HStack {
                                Text(req.source.path).lineLimit(1).truncationMode(.middle)
                                Button("Use Files Instead") { hasSource = false }
                            }
                        }
                    } else {
                        slot("Base game", baseFile, choose: { pick(.base) }, remove: baseFile == nil ? nil : { baseFile = nil; updateFile = nil; dlcFiles = []; hasSource = false })
                        if let b = baseFile, let w = BuildView.mismatch(b, wants: "Base game") { Text(w).font(.footnote).foregroundStyle(.orange) }
                        if !isNup {
                            slot("Update", updateFile, choose: { pick(.update) }, remove: updateFile == nil ? nil : { updateFile = nil })
                            if let u = updateFile, let w = BuildView.mismatch(u, wants: "Update") { Text(w).font(.footnote).foregroundStyle(.orange) }
                            LabeledContent("DLC") {
                                VStack(alignment: .trailing, spacing: 4) {
                                    ForEach(dlcFiles, id: \.self) { d in
                                        HStack {
                                            Text(d.lastPathComponent).lineLimit(1).truncationMode(.middle).help(d.path)
                                            Button { dlcFiles.removeAll { $0 == d } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                                        }
                                    }
                                    Button(dlcFiles.isEmpty ? "Add DLC…" : "Add More…") { pick(.dlc) }
                                }
                            }
                        } else {
                            Text("A Switch 2 .nup holds the whole game: no separate update or DLC files.").font(.footnote).foregroundStyle(.secondary)
                        }
                        HStack { Spacer(); Button("Use a Folder Instead…") { pickFolder() }.buttonStyle(.link).font(.footnote) }
                    }
                    if hasSource && !isNup && (!files.isEmpty || builder.needsKeys(req.source)) {
                        LabeledContent("prod.keys") {
                            HStack {
                                Text(builder.keys.isEmpty ? "Not set" : builder.keys).lineLimit(1).truncationMode(.middle)
                                Button("Choose…") { pickKeys() }
                            }
                        }
                    }
                }
                if hasSource && baseFile == nil && Packages.takes(req.source) { PackagesSection(folder: req.source) }
                Section("Build") {
                    Picker("For", selection: $req.target) { ForEach(BuildTarget.allCases) { Text($0.label).tag($0) } }
                    Toggle("Also build the other one", isOn: $both)
                    if hasSource && req.source.pathExtension.lowercased() == "nup" && (req.target == .ios || both) {
                        Text("Switch 2 games are tested on the Mac only.").font(.footnote).foregroundStyle(.orange)
                    }
                    TextField("Game language (empty: English)", text: $req.language, prompt: Text("en-GB, ja, fr, …"))
                    if hasSource, let free = Builder.freeSpace(at: req.outFolder ?? req.source) {
                        LabeledContent("Free space", value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                            .foregroundStyle(free < 30_000_000_000 ? .orange : .primary)
                    }
                    LabeledContent("Output folder") {
                        HStack {
                            Text(req.outFolder?.path ?? "Beside the source").lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { pickOut() }
                            if req.outFolder != nil { Button("Reset") { req.outFolder = nil } }
                        }
                    }
                }
                Section("Options") {
                    Toggle("Mac: only the shaders the playtests used (faster; some areas may draw incompletely)", isOn: $req.seenShaders)
                    Toggle("Mac: prepare pipelines here, so the first start is quick", isOn: $req.prebake)
                    Toggle("iPhone: keep the game files out of the IPA (copied once with push_romfs.sh)", isOn: $req.romfsSeparate)
                }
                Section {
                    if hasSource, let r = GamesFolder.root, !files.isEmpty || !GamesFolder.contains(req.source) {
                        Toggle("Put the game's files in your games folder (\(r.lastPathComponent))", isOn: $intoFolder)
                    }
                    if let m = moving { HStack { ProgressView().controlSize(.small); Text(m).font(.footnote) } }
                    Button("Build") { start() }
                    .buttonStyle(.borderedProminent).disabled(!hasSource || moving != nil || (!isNup && (!files.isEmpty || builder.needsKeys(req.source)) && builder.keys.isEmpty))
                    if let why = builder.ready { Text(why).foregroundStyle(.red).font(.footnote) }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for pr in providers { _ = pr.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { take([u]) } } } }
                return true
            }
            JobsView().frame(minWidth: 360)
        }
    }
    /// The build, after the source moved into the games folder when that is asked for (on the same drive a rename; to another a copy, asked first)
    private func start() {
        func go(_ r: BuildRequest) {
            builder.enqueue(r)
            if both { var o = r; o.target = r.target == .mac ? .ios : .mac; builder.enqueue(o) }
        }
        if !files.isEmpty { assemble(go); return }
        guard intoFolder, let root = GamesFolder.root, !GamesFolder.contains(req.source) else { go(req); return }
        guard GamesFolder.confirmCopy([req.source], to: root) else { return }
        var r = req; moving = "Moving the game's files into \(root.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let n = try GamesFolder.adopt(r.source)
                DispatchQueue.main.async { r.source = n; req.source = n; moving = nil; go(r) }
            } catch {
                DispatchQueue.main.async { moving = nil; let a = NSAlert(); a.messageText = "The files could not be moved"; a.informativeText = error.localizedDescription; a.runModal() }
            }
        }
    }
    private enum Slot { case base, update, dlc }
    @ViewBuilder private func slot(_ title: String, _ u: URL?, choose: @escaping () -> Void, remove: (() -> Void)?) -> some View {
        LabeledContent(title) {
            HStack {
                Text(u?.lastPathComponent ?? (title == "Base game" ? "None chosen" : "None")).lineLimit(1).truncationMode(.middle).foregroundStyle(u == nil ? .secondary : .primary).help(u?.path ?? "")
                Button(u == nil ? "Choose…" : "Change…", action: choose)
                if let remove { Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless) }
            }
        }
    }
    private func pick(_ slot: Slot) {
        let p = NSOpenPanel(); p.canChooseDirectories = false; p.canChooseFiles = true; p.allowsMultipleSelection = slot == .dlc
        p.message = slot == .base ? "Choose the base game: an .nsp, .xci, .nsz or .xcz file, or a Switch 2 game's .nup" : slot == .update ? "Choose the game's update file" : "Choose the game's DLC files"
        if let d = (baseFile ?? updateFile)?.deletingLastPathComponent() ?? GamesFolder.root, FileManager.default.fileExists(atPath: d.path) { p.directoryURL = d }
        guard p.runModal() == .OK else { return }
        let ok = p.urls.filter { (BuildView.packageTypes + (slot == .base ? ["nup"] : [])).contains($0.pathExtension.lowercased()) }
        guard !ok.isEmpty else { let a = NSAlert(); a.messageText = "Not a game file"; a.informativeText = "Choose an .nsp, .xci, .nsz or .xcz file\(slot == .base ? ", or a .nup" : "")."; a.runModal(); return }
        switch slot {
        case .base: setBase(ok[0])
        case .update: updateFile = ok[0]
        case .dlc: dlcFiles += ok.filter { !dlcFiles.contains($0) }
        }
    }
    private func setBase(_ u: URL) {
        baseFile = u; hasSource = true
        if u.pathExtension.lowercased() == "nup" { req.source = u; updateFile = nil; dlcFiles = [] } else { req.source = u.deletingLastPathComponent() }   // the folder: the free space shown; the build's source is made at Build
    }
    private func pickFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose a folder holding the game's files, or a dump folder"
        if let r = GamesFolder.root, FileManager.default.fileExists(atPath: r.path) { p.directoryURL = r }
        if p.runModal() == .OK, let u = p.url { baseFile = nil; updateFile = nil; dlcFiles = []; req.source = u; hasSource = true }
    }
    /// Dropped files go to their slots by what they are (a .nup or a folder as the source)
    private func take(_ urls: [URL]) {
        for u in urls {
            if u.hasDirectoryPath { baseFile = nil; updateFile = nil; dlcFiles = []; req.source = u; hasSource = true; continue }
            let e = u.pathExtension.lowercased()
            if e == "nup" { setBase(u); continue }
            guard BuildView.packageTypes.contains(e) else { continue }
            switch BuildView.kind(u) {
            case "Update": updateFile = u
            case "DLC": if !dlcFiles.contains(u) { dlcFiles.append(u) }
            default: setBase(u)
            }
        }
    }
    /// A file whose title ID says it is something else than its slot: a note under it
    static func mismatch(_ u: URL, wants: String) -> String? {
        if u.pathExtension.lowercased() == "nup" { return nil }
        let k = kind(u)
        return k == wants || k == "Game file" ? nil : "Its name says it is \(k == "DLC" ? "a DLC" : "an \(k.lowercased())"), not \(wants == "Base game" ? "the base game" : "an update")."
    }
    static let packageTypes = ["nsp", "xci", "nsz", "xcz"]
    /// What a game file is, by the title ID in its name ([0100…000] the base game, …800 its update, anything else a DLC)
    static func kind(_ u: URL) -> String {
        guard let m = u.lastPathComponent.range(of: #"\[[0-9A-Fa-f]{16}\]"#, options: .regularExpression) else { return "Game file" }
        let tid = u.lastPathComponent[m].dropFirst().dropLast().uppercased()
        return tid.hasSuffix("000") ? "Base game" : tid.hasSuffix("800") ? "Update" : "DLC"
    }
    static func order(_ u: URL) -> Int { ["Base game": 0, "Update": 1, "DLC": 2][kind(u)] ?? 3 }
    /// The picked files copied into a folder of their own (in the games folder when that is on, else beside the base game), which is then built. A copy on the same
    /// drive is an APFS clone (instant, no space taken); to another drive it is a real copy, asked first. The originals stay where they are
    private func assemble(_ go: @escaping (BuildRequest) -> Void) {
        guard let base = files.first(where: { BuildView.kind($0) == "Base game" }) ?? files.first else { return }
        let parent = intoFolder ? (GamesFolder.root ?? base.deletingLastPathComponent()) : base.deletingLastPathComponent()
        let dest = GamesFolder.unique(GamesFolder.name(for: base), in: parent)
        let far = files.filter { !GamesFolder.sameDrive($0, parent) }
        if !far.isEmpty {
            let bytes = far.reduce(0) { $0 + GamesFolder.size($1) }
            let a = NSAlert(); a.messageText = "Copy the files to \(parent.lastPathComponent)?"
            a.informativeText = "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) will be copied to the other drive. Your originals stay where they are."
            a.addButton(withTitle: "Copy"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        var r = req; let list = files; moving = "Putting the game's files in \(dest.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                for f in list { try FileManager.default.copyItem(at: f, to: dest.appendingPathComponent(f.lastPathComponent)) }
                DispatchQueue.main.async { r.source = dest; req.source = dest; baseFile = nil; updateFile = nil; dlcFiles = []; moving = nil; go(r) }
            } catch {
                DispatchQueue.main.async { moving = nil; let a = NSAlert(); a.messageText = "The files could not be put together"; a.informativeText = error.localizedDescription; a.runModal() }
            }
        }
    }
    private func pickKeys() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.message = "Choose prod.keys (dumped from your Switch)"
        if p.runModal() == .OK, let u = p.url { builder.keys = u.path }
    }
    private func pickOut() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { req.outFolder = u }
    }
}

struct JobsView: View {
    @EnvironmentObject var builder: Builder
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Builds").font(.headline)
                Spacer()
                Button("Clear Finished") { builder.clearFinished() }.disabled(!builder.jobs.contains { $0.state != .running && $0.state != .waiting })
            }.padding()
            if builder.jobs.isEmpty { Text("No builds yet.").foregroundStyle(.secondary).padding() }
            List(builder.jobs) { JobRow(job: $0) }
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: BuildJob
    @EnvironmentObject var builder: Builder
    @Environment(\.openWindow) private var openWindow
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let i = job.icon { Image(nsImage: i).resizable().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8)) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.headline).lineLimit(1)
                    Text("\(job.request.target.label) · \(status)").font(.caption).foregroundStyle(color)
                }
                Spacer()
                switch job.state {
                case .running, .waiting: Button("Stop") { builder.cancel(job) }
                case .done:
                    if job.request.target == .ios { Button("Install…") { openWindow(id: "devices") } }
                    if let o = job.out { Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([o]) } }
                default:
                    if let l = builder.logs(job) { Button("Logs") { NSWorkspace.shared.open(l) } }
                    Button("Retry") { builder.enqueue(job.request) }
                }
            }
            if job.state == .running {
                if let f = job.overall { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                Text("\(job.stage)\(job.step.isEmpty ? "" : " · \(job.step)")\(job.eta.map { " · about \(Self.time($0)) left" } ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            DisclosureGroup("Details", isExpanded: $open) {
                ScrollView {
                    Text(job.lines.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 160)
            }.font(.caption)
        }
        .padding(.vertical, 4)
    }
    private var status: String {
        switch job.state {
        case .waiting: return "Waiting"
        case .running: return job.stageN > 0 ? "Stage \(job.stageK) of \(job.stageN)" : "Starting"
        case .done: return "Done"
        case .cancelled: return "Stopped"
        case .failed(let why): return why
        }
    }
    private var color: Color {
        switch job.state { case .done: return .green; case .failed: return .red; default: return .secondary }
    }
    static func time(_ s: Double) -> String { s < 90 ? "\(Int(s)) s" : s < 5400 ? "\(Int(s / 60)) min" : String(format: "%.1f h", s / 3600) }
}

struct BuildSettingsView: View {
    @EnvironmentObject var builder: Builder
    @ObservedObject var engine = Engine.shared
    var body: some View {
        Form {
            if Engine.shared.bundled {
                Toggle("Build with the engine Cartridge carries (\(Engine.shared.version ?? ""))", isOn: Binding(get: { engine.builtIn }, set: { engine.builtIn = $0; engine.ensure() }))
                Text(engine.builtIn ? (engine.installedDir?.path ?? engine.status) : "Off: builds use your own nxnative checkout and Python, below (for working on nxnative itself).")
                    .font(.footnote).foregroundStyle(.secondary)
                if engine.builtIn, let prev = engine.previous {
                    Toggle("Use the previous engine (\(prev))", isOn: Binding(get: { engine.usePrevious }, set: { engine.usePrevious = $0 }))
                    Text("For an update whose engine builds a game worse: rebuild the game after turning this on. Turn it off to go back to the engine this Cartridge carries.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !engine.builtIn {
                TextField("nxnative repository", text: $builder.repo)
                TextField("Python", text: $builder.python)
            }
            HStack { TextField("prod.keys", text: $builder.keys); Button("Choose…") {
                let p = NSOpenPanel(); p.canChooseFiles = true; if p.runModal() == .OK, let u = p.url { builder.keys = u.path } } }
            if let why = builder.ready { Text(why).foregroundStyle(.red).font(.footnote) } else { Text("Ready to build.").foregroundStyle(.green).font(.footnote) }
        }
        .padding()
    }
}
