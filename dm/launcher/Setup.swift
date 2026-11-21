// The setup assistant (Cartridge › Setup Assistant…, and by itself at the first start while something needed is missing): a checklist of what building and playing
// games needs on this Mac, each with what was found and a button that fixes it where Cartridge can. What it checks is what the NSP script checks before it starts
// (scripts/build_ipa_from_nsp.py check_prereqs; README.md, Build from the command line): Xcode (the version the shaders are built with) selected and set up, its Metal
// toolchain, the iOS platform for iPhone builds only, Homebrew with xcodegen, zstd and glslang, an arm64 Python 3.12 or newer with the script's modules, and the
// nxnative repository. Your own prod.keys and game files are needed too: the assistant says so and lets you point to where they are on this Mac; it offers no way to get them.
// Xcode cannot be shipped with Cartridge (its licence): its page opens, and the steps after it (the licence, the first launch, the Metal toolchain) run from here. Xcode and
// its components go on the startup disk; a Python environment goes on the drive you choose (its free space checked there)
import AppKit
import SwiftUI

enum SetupState { case checking, ok, missing, warn, optional }

struct SetupItem: Identifiable {
    let id: String
    var title: String
    var state: SetupState = .checking
    var detail = ""
    var fix: String?          // the button's label; nil: nothing to do here
    var required = true
}

final class Setup: ObservableObject {
    static let shared = Setup()
    static let xcodeVersion = "27.2"   // README.md: the shaders are built with this Xcode's Metal compiler
    static let pythonModules = ["lz4", "capstone", "fontTools", "nsz", "zbic"]   // and backports.zstd before Python 3.14
    @Published var items: [SetupItem] = []
    @Published var busy: String?      // the item a fix is running for
    @Published var lastFix: String?   // the item the last fix ran for: its output stays under it
    @Published var log = ""           // the last fix's output, its last lines
    private var cleared = Set<String>()   // DM_SETUP_PRETEND items whose fix has run without an error: read as they are from then on
    private let store = UserDefaults.standard

    var repo: String { store.string(forKey: "build.repo") ?? (Bundle.main.infoDictionary?["DMRepo"] as? String ?? "") }
    var python: String { store.string(forKey: "build.python") ?? (Bundle.main.infoDictionary?["DMPython"] as? String ?? "/usr/bin/python3") }
    var keys: String { store.string(forKey: "build.keys") ?? "" }
    /// Something a build needs is missing (the assistant opens by itself at a start then)
    var incomplete: Bool { items.contains { $0.required && ($0.state == .missing) } }

    func check() {
        let order = ["repo", "xcode", "xcodeSetup", "metal", "ios", "brew", "tools", "python", "keys", "games"]
        items = order.map { SetupItem(id: $0, title: Setup.titles[$0] ?? $0) }
        // DM_SETUP_PRETEND=python,tools,…: those items read as missing, to try their fixes on a Mac that has everything (they do nothing harmful there)
        let pretend = Set((ProcessInfo.processInfo.environment["DM_SETUP_PRETEND"] ?? "").split(separator: ",").map(String.init)).subtracting(cleared)
        DispatchQueue.global(qos: .userInitiated).async {
            let found = order.map { id -> SetupItem in
                var it = self.probe(id)
                if pretend.contains(id) { it.state = .missing; it.fix = ["python": "Install Modules", "tools": "Install", "metal": "Download", "keys": "Choose File…", "games": "Add Folder…", "repo": "Choose Folder…"][id] ?? it.fix; it.detail = "(pretend) " + it.detail }
                return it
            }
            DispatchQueue.main.async { self.items = found }
        }
    }
    static let titles = ["repo": "Engine (nxnative)", "xcode": "Xcode", "xcodeSetup": "Xcode's licence and first launch", "metal": "Metal toolchain",
                         "ios": "iOS platform (iPhone and iPad builds only)", "brew": "Homebrew", "tools": "xcodegen, zstd and glslang", "python": "Python and its modules",
                         "keys": "Your prod.keys", "games": "Games folder"]

    private func probe(_ id: String) -> SetupItem {
        var it = SetupItem(id: id, title: Setup.titles[id] ?? id)
        let fm = FileManager.default
        switch id {
        case "repo" where Engine.shared.builtIn:
            let e = Engine.shared
            if e.isInstalled { it.state = .ok; it.detail = "Built in: \(e.version ?? "") at \(e.dir?.path ?? "")" }
            else if GamesFolder.root == nil { it.state = .missing; it.detail = "Choose your games folder below first: the engine is unpacked on its drive." }
            else { it.state = .missing; it.fix = "Unpack"; it.detail = e.status.isEmpty ? "Cartridge's engine \(e.version ?? "") is not unpacked yet." : e.status }
        case "repo":
            if fm.fileExists(atPath: repo + "/scripts/build_ipa_from_nsp.py") { it.state = .ok; it.detail = repo }
            else { it.state = .missing; it.detail = repo.isEmpty ? "Not set." : "No nxnative checkout at \(repo)."; it.fix = "Choose Folder…" }
        case "xcode":
            let (c, path) = shell("/usr/bin/xcode-select", ["-p"]), (vc, ver) = shell("/usr/bin/xcrun", ["xcodebuild", "-version"])
            let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if c != 0 || !p.contains(".app/") {
                it.state = .missing; it.fix = "Get Xcode"
                it.detail = "Xcode \(Setup.xcodeVersion) is needed (the Command Line Tools alone are not enough). It installs on the startup disk."
            } else {
                let v = ver.split(separator: "\n").first.map(String.init) ?? "Xcode"
                it.state = vc == 0 && v.contains(Setup.xcodeVersion) ? .ok : .warn
                it.detail = "\(v) at \(p.replacingOccurrences(of: "/Contents/Developer", with: ""))" + (it.state == .warn ? ". The games' shaders are built with Xcode \(Setup.xcodeVersion); another version may build them differently." : "")
                if it.state == .warn { it.fix = "Get Xcode \(Setup.xcodeVersion)" }
            }
        case "xcodeSetup":
            let (c, out) = shell("/usr/bin/xcrun", ["xcodebuild", "-checkFirstLaunchStatus"])
            if c == 0 { it.state = .ok; it.detail = "Done." }
            else { it.state = .missing; it.fix = "Set Up Xcode…"; it.detail = "Xcode's licence must be accepted and its first-launch setup run (asks for your password). " + out.suffix(120) }
        case "metal":
            let (c, out) = shell("/usr/bin/xcrun", ["metal", "--version"])
            if c == 0 { it.state = .ok; it.detail = out.split(separator: "\n").first.map(String.init) ?? "" }
            else { it.state = .missing; it.fix = "Download"; it.detail = "Xcode's Metal compiler is a separate download (about 700 MB, on the startup disk)." }
        case "ios":
            it.required = false
            let (_, out) = shell("/usr/bin/xcrun", ["xcodebuild", "-showsdks"])
            if out.contains("iphoneos") { it.state = .ok; it.detail = out.split(separator: "\n").first { $0.contains("iphoneos") }.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
            else { it.state = .optional; it.fix = "Download"; it.detail = "Only for building games for iPhone or iPad (several GB, on the startup disk)." }
        case "brew":
            if let b = Setup.brew { it.state = .ok; it.detail = b }
            else { it.state = .missing; it.fix = "Get Homebrew"; it.detail = "Homebrew installs the command-line tools below. Its installer runs in Terminal." }
        case "tools":
            let need = ["xcodegen", "zstd", "glslangValidator"].filter { Setup.which($0) == nil }
            if need.isEmpty { it.state = .ok; it.detail = "All three are installed." }
            else { it.state = .missing; it.detail = "Missing: \(need.map { $0 == "glslangValidator" ? "glslang" : $0 }.joined(separator: ", "))."; it.fix = Setup.brew == nil ? nil : "Install" }
        case "python" where Engine.shared.builtIn:
            it.state = .ok; it.detail = "Built in: Python with every module, in the engine."
        case "python":
            let script = "import sys,platform,importlib.util; m=[n for n in [\(Setup.pythonModules.map { "'\($0)'" }.joined(separator: ","))] + (['backports.zstd'] if sys.version_info < (3,14) else []) if importlib.util.find_spec(n) is None]; print(sys.version.split()[0], platform.machine(), ','.join(m))"
            let (c, out) = fm.isExecutableFile(atPath: python) ? shell(python, ["-c", script]) : (1, "")
            let f = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if c != 0 || f.count < 2 { it.state = .missing; it.fix = "New Environment…"; it.detail = "\(python) does not run. Python 3.12 or newer for Apple silicon is needed (python.org's installer, or Homebrew's)." }
            else {
                let v = f[0].split(separator: ".").compactMap { Int($0) }, okVer = v.count >= 2 && (v[0] > 3 || (v[0] == 3 && v[1] >= 12)), arm = f[1] == "arm64"
                let miss = f.count > 2 ? f[2] : ""
                if !okVer || !arm { it.state = .missing; it.fix = "New Environment…"; it.detail = "\(python) is Python \(f[0]) for \(f[1]): 3.12 or newer for Apple silicon (arm64) is needed." }
                else if !miss.isEmpty { it.state = .missing; it.fix = "Install Modules"; it.detail = "Python \(f[0]) at \(python); missing: \(miss.replacingOccurrences(of: ",", with: ", "))." }
                else { it.state = .ok; it.detail = "Python \(f[0]) at \(python), with every module." }
            }
        case "keys":
            // never read out: only whether the file is there, readable and holds key lines
            if keys.isEmpty { it.state = .missing; it.fix = "Choose File…"; it.detail = "Building from NSP files needs your own prod.keys, dumped from your Switch. Point to where it is on this Mac." }
            else if let d = fm.contents(atPath: keys), let t = String(data: d, encoding: .utf8), t.contains("=") { it.state = .ok; it.detail = keys; it.fix = "Change…" }
            else { it.state = .missing; it.fix = "Choose File…"; it.detail = "\(keys) is missing, unreadable or holds no keys." }
            it.required = false   // a .nup or a dump folder builds without it
        case "games":
            it.required = false
            if let r = GamesFolder.root, fm.fileExists(atPath: r.path) {
                it.state = .ok; it.fix = "Change…"
                it.detail = r.path + (Builder.freeSpace(at: r).map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free)" } ?? "")
            } else {
                it.state = .optional; it.fix = "Choose Folder…"
                it.detail = "One folder, on the drive you choose, for your own game files (NSP, XCI, NSZ, .nup, or a dump folder): each game gets a folder there with its files, its build and its app. Building moves new games' files in; games you have already built move in from their menu."
            }
        default: break
        }
        return it
    }

    static var brew: String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    static func which(_ tool: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: fixes
    func fix(_ id: String) {
        switch id {
        case "repo" where Engine.shared.builtIn: Engine.shared.ensure(); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.check() }
        case "repo": if let u = pick(dir: true, "Choose your nxnative folder (the one with scripts/ and dm/ in it)") { store.set(u.path, forKey: "build.repo"); check() }
        case "xcode": NSWorkspace.shared.open(URL(string: "https://developer.apple.com/download/all/?q=Xcode%20\(Setup.xcodeVersion)")!)
        case "xcodeSetup":
            let dev = shell("/usr/bin/xcode-select", ["-p"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
            var app = dev.replacingOccurrences(of: "/Contents/Developer", with: "")
            if !app.hasSuffix(".app") { app = "/Applications/Xcode.app" }
            admin("xcode-select -s '\(app)' && xcodebuild -license accept && xcodebuild -runFirstLaunch", for: id)
        case "metal": run("/usr/bin/xcrun", ["xcodebuild", "-downloadComponent", "MetalToolchain"], for: id)
        case "ios": run("/usr/bin/xcrun", ["xcodebuild", "-downloadPlatform", "iOS"], for: id)
        case "brew": NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
        case "tools": if let b = Setup.brew { run(b, ["install", "xcodegen", "zstd", "glslang"], for: id) }
        case "python":
            if let it = items.first(where: { $0.id == id }), it.fix == "Install Modules" { installModules(python, for: id) }
            else { newEnvironment() }
        case "keys": if let u = pick(dir: false, "Choose your prod.keys") { store.set(u.path, forKey: "build.keys"); check() }
        case "games":
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.message = "Choose or make your games folder (on the drive with room for your games)"
            if p.runModal() == .OK, let u = p.url { GamesFolder.set(u); Engine.shared.ensure(); check() }
        default: break
        }
    }
    private func pick(dir: Bool, _ msg: String) -> URL? {
        let p = NSOpenPanel(); p.canChooseDirectories = dir; p.canChooseFiles = !dir; p.message = msg
        return p.runModal() == .OK ? p.url : nil
    }
    /// A command run for an item, its output's last lines shown as it goes; the list is checked again when it ends
    private func run(_ exe: String, _ args: [String], for id: String) {
        busy = id; lastFix = id; log = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let (c, out) = shell(exe, args) { line in DispatchQueue.main.async { self.log = String((self.log + line + "\n").suffix(600)) } }
            DispatchQueue.main.async {
                self.busy = nil
                if c != 0 { self.log = "Failed (\(c)):\n" + String(out.suffix(500)) } else { self.cleared.insert(id) }
                self.check()
            }
        }
    }
    /// A command that needs administrator rights: macOS asks for the password
    private func admin(_ cmd: String, for id: String) {
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        run("/usr/bin/osascript", ["-e", script], for: id)
    }
    private func installModules(_ py: String, for id: String) {
        var mods = ["lz4", "capstone>=5,<6", "fonttools", "nsz", "zbic", "backports.zstd; python_version < '3.14'"]
        if !FileManager.default.isWritableFile(atPath: URL(fileURLWithPath: py).deletingLastPathComponent().path) { mods.insert("--user", at: 0) }
        run(py, ["-m", "pip", "install"] + mods, for: id)
    }
    /// A Python environment of its own on the drive you choose, with the modules, made the one Cartridge builds with
    private func newEnvironment() {
        let base = ["/opt/homebrew/bin/python3", "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/usr/local/bin/python3"]
            .first { p in FileManager.default.isExecutableFile(atPath: p) && shell(p, ["-c", "import sys,platform; sys.exit(0 if sys.version_info >= (3,12) and platform.machine() == 'arm64' else 1)"]).0 == 0 }
        guard let base else {
            let a = NSAlert(); a.messageText = "Python 3.12 or newer is needed first"
            a.informativeText = "Install it from python.org (the macOS installer) or with Homebrew (brew install python), then come back here."
            a.addButton(withTitle: "Open python.org"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://www.python.org/downloads/macos/")!) }
            return
        }
        guard let dir = pick(dir: true, "Choose where the Python environment goes (about 300 MB; any drive)") else { return }
        if let free = Builder.freeSpace(at: dir), free < 1_000_000_000 {
            let a = NSAlert(); a.messageText = "Not enough space there"; a.informativeText = String(format: "%.1f GB free on that drive; about 1 GB is needed.", Double(free) / 1e9); a.runModal(); return
        }
        let venv = dir.appendingPathComponent("nxnative-venv").path, py = venv + "/bin/python3"
        busy = "python"; log = "Making \(venv)…\n"
        DispatchQueue.global(qos: .userInitiated).async {
            let (c, out) = shell(base, ["-m", "venv", venv])
            DispatchQueue.main.async {
                guard c == 0 else { self.busy = nil; self.log = "Failed:\n" + out; return }
                self.store.set(py, forKey: "build.python")
                self.installModules(py, for: "python")
            }
        }
    }
}

struct SetupView: View {
    @ObservedObject var setup = Setup.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Cartridge").font(.title.bold())
            Text("What building and playing games needs on this Mac. Cartridge fixes what it can; the rest opens where you get it.").foregroundStyle(.secondary)
            List(setup.items) { it in
                HStack(alignment: .top, spacing: 10) {
                    icon(it.state).font(.title3).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.title).font(.headline)
                        if !it.detail.isEmpty { Text(it.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                        if setup.lastFix == it.id && !setup.log.isEmpty { Text(setup.log).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(6) }
                    }
                    Spacer()
                    if setup.busy == it.id { ProgressView().controlSize(.small) }
                    else if let f = it.fix { Button(f) { setup.fix(it.id) }.disabled(setup.busy != nil) }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Text("Building a game needs your own prod.keys and game files. Cartridge does not provide them.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { setup.check() }.disabled(setup.busy != nil)
                Button("Done") { UserDefaults.standard.set(true, forKey: "setup.seen"); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { setup.check() }
    }
    @ViewBuilder private func icon(_ s: SetupState) -> some View {
        switch s {
        case .checking: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .optional: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}
