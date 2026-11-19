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
    let request: BuildRequest
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
    }

    var script: URL { URL(fileURLWithPath: repo).appendingPathComponent("scripts/build_ipa_from_nsp.py") }
    var ready: String? {   // why a build cannot start, or nil
        if !FileManager.default.fileExists(atPath: script.path) { return "Set the nxnative repository folder (Build Settings): \(script.path) is missing." }
        if !FileManager.default.isExecutableFile(atPath: python) { return "Set Python (Build Settings): \(python) is not a program." }
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
    /// The app's current icon as a PNG for --fallback-icon, so a rebuild keeps an icon the player gave a game that has none of its own; nil when the app has no icon file
    static func iconPNG(of g: Game) -> URL? {
        guard let info = NSDictionary(contentsOf: g.contents.appendingPathComponent("Info.plist")), let name = info["CFBundleIconFile"] as? String else { return nil }
        let icns = g.contents.appendingPathComponent("Resources").appendingPathComponent(name.hasSuffix(".icns") ? name : name + ".icns")
        guard let img = NSImage(contentsOf: icns), let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("nxnative-icon-\(g.titleID).png")
        return (try? png.write(to: out)) != nil ? out : nil
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
        let r = j.request
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = arguments(r)
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")   // a GUI app's PATH lacks Homebrew's tools
        env["PYTHONUNBUFFERED"] = "1"
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

    var body: some View {
        HSplitView {
            Form {
                Section("Game") {
                    LabeledContent("Source") {
                        HStack {
                            Text(hasSource ? req.source.path : "None").lineLimit(1).truncationMode(.middle).foregroundStyle(hasSource ? .primary : .secondary)
                            Button("Choose…") { pickSource() }
                        }
                    }
                    Text("A folder with the game's NSPs (base game, update, DLC), a dump folder, or a Switch 2 game's .nup file. You can also drop it here.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if hasSource && builder.needsKeys(req.source) {
                        LabeledContent("prod.keys") {
                            HStack {
                                Text(builder.keys.isEmpty ? "Not set" : builder.keys).lineLimit(1).truncationMode(.middle)
                                Button("Choose…") { pickKeys() }
                            }
                        }
                    }
                }
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
                    Button("Build") {
                        builder.enqueue(req)
                        if both { var o = req; o.target = req.target == .mac ? .ios : .mac; builder.enqueue(o) }
                    }
                    .buttonStyle(.borderedProminent).disabled(!hasSource || (builder.needsKeys(req.source) && builder.keys.isEmpty))
                    if let why = builder.ready { Text(why).foregroundStyle(.red).font(.footnote) }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                providers.first?.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { req.source = u; hasSource = true } } }
                return true
            }
            JobsView().frame(minWidth: 360)
        }
    }
    private func pickSource() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true
        p.message = "Choose the game's NSP folder, a dump folder or a .nup file"
        if p.runModal() == .OK, let u = p.url { req.source = u; hasSource = true }
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
    var body: some View {
        Form {
            TextField("nxnative repository", text: $builder.repo)
            TextField("Python", text: $builder.python)
            HStack { TextField("prod.keys", text: $builder.keys); Button("Choose…") {
                let p = NSOpenPanel(); p.canChooseFiles = true; if p.runModal() == .OK, let u = p.url { builder.keys = u.path } } }
            if let why = builder.ready { Text(why).foregroundStyle(.red).font(.footnote) } else { Text("Ready to build.").foregroundStyle(.green).font(.footnote) }
        }
        .padding()
    }
}
