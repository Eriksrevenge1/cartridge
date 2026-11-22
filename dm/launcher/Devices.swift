// Installing an IPA on a connected iPhone or iPad (the IPA is universal: dm/ios/project.yml TARGETED_DEVICE_FAMILY 1,2; an iPad needs an M1 or later). The NSP script's IPA is unsigned (dm/ios/tools/build_ipa.sh: only its executable carries an ad-hoc signature with the
// entitlements it asks for), so the launcher signs it with the player's own Apple ID first:
//   1. a placeholder app with the game's bundle ID and entitlements is built once per bundle ID and team with xcodebuild -allowProvisioningUpdates, which makes the development
//      certificate, the App ID and a provisioning profile that holds the device (the Apple ID must be signed in to Xcode: Settings › Accounts);
//   2. the IPA is unpacked beside itself, gets that profile, and is signed with the placeholder's identity and entitlements (its frameworks first);
//   3. xcrun devicectl installs the app; an IPA built with --romfs separate then gets its game files with scripts/push_romfs.sh.
// A free Apple ID's apps run for 7 days, and only a few at once; a free Personal Team was granted Increased Memory Limit (dm/games/010029B0118E8000/README.md). A team that does not grant
// an entitlement gets the placeholder without it, and the log says so.
import AppKit
import SwiftUI

struct Device: Identifiable, Hashable {
    let udid, name, model, os, transport: String
    var id: String { udid }
}

struct IPAItem: Identifiable, Hashable, Codable {
    var path: String
    var bundleID: String
    var name: String
    var titleID: String
    var source: String?        // the build's source (NSP folder or .nup), for the game files of a --romfs separate build
    var romfsSeparate = false
    var id: String { path }
}

/// Runs a program and returns its exit code and output (stdout and stderr together)
@discardableResult func shell(_ exe: String, _ args: [String], cwd: URL? = nil, line: ((String) -> Void)? = nil) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
    p.environment = env
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    var all = Data(), partial = Data()
    pipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData; guard !d.isEmpty else { return }
        all.append(d); partial.append(d)
        while let nl = partial.firstIndex(of: 0x0A) {
            let l = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self); partial.removeSubrange(partial.startIndex...nl)
            line?(l)
        }
    }
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    p.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    all.append(pipe.fileHandleForReading.readDataToEndOfFile())
    return (p.terminationStatus, String(decoding: all, as: UTF8.self))
}

final class Devices: ObservableObject {
    @Published var devices: [Device] = []
    @Published var ipas: [IPAItem] = []
    @Published var team: String { didSet { UserDefaults.standard.set(team, forKey: "install.team") } }
    @Published var log: [String] = []
    @Published var busy = false
    private var timer: Timer?
    weak var builder: Builder?

    init() {
        team = UserDefaults.standard.string(forKey: "install.team") ?? Devices.xcodeTeam() ?? Devices.keychainTeam() ?? ""
        if let d = UserDefaults.standard.data(forKey: "install.ipas"), let l = try? JSONDecoder().decode([IPAItem].self, from: d) {
            ipas = l.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }
    private func persist() { if let d = try? JSONEncoder().encode(ipas) { UserDefaults.standard.set(d, forKey: "install.ipas") } }

    /// The team of the Apple ID signed in to Xcode, when Xcode has one (its personal team or the first one)
    static func xcodeTeam() -> String? {
        guard let teams = UserDefaults(suiteName: "com.apple.dt.Xcode")?.dictionary(forKey: "IDEProvisioningTeams") else { return nil }
        for case let list as [[String: Any]] in teams.values { if let t = list.first?["teamID"] as? String { return t } }
        return nil
    }
    /// The team of an Apple Development certificate in the keychain: its subject's OU (Xcode › Settings › Accounts › Manage Certificates › + makes one)
    static func keychainTeam() -> String? {
        let (c, pem) = shell("/usr/bin/security", ["find-certificate", "-a", "-c", "Apple Development", "-p"])
        guard c == 0, let first = pem.components(separatedBy: "-----END CERTIFICATE-----").first, first.contains("BEGIN") else { return nil }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("nxl-cert-\(UUID().uuidString).pem")
        defer { try? FileManager.default.removeItem(at: f) }
        try? (first + "-----END CERTIFICATE-----\n").write(to: f, atomically: true, encoding: .utf8)
        let (k, subject) = shell("/usr/bin/openssl", ["x509", "-noout", "-subject", "-nameopt", "multiline", "-in", f.path])
        guard k == 0, let line = subject.split(separator: "\n").first(where: { $0.contains("organizationalUnitName") }) else { return nil }
        let t = line.split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return t.count == 10 ? t : nil
    }

    func watch(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
    }
    // ---- Your games on this iPhone (library sync): which of the library's games the device has, and whether Cartridge's copy there is older than the Mac's ----
    /// The apps on the chosen device: bundle ID → its version (devicectl device info apps)
    @Published var onDevice: [String: String] = [:]
    /// Games whose iPhone build is under way for a device: title ID → device UDID. The IPA that build makes is installed there when it lands (add(ipa:))
    @Published var pending: [String: String] = [:]
    /// What Cartridge installed: "<UDID>|<bundle ID>" → the IPA's DMCommit (the engine it was built with)
    var installedCommits: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "install.commits") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "install.commits") }
    }
    func readApps(_ udid: String) {
        DispatchQueue.global().async {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("nxl-apps-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: f) }
            shell("/usr/bin/xcrun", ["devicectl", "device", "info", "apps", "--device", udid, "--json-output", f.path, "--quiet"])
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let apps = (o["result"] as? [String: Any])?["apps"] as? [[String: Any]] else { return }
            var found: [String: String] = [:]
            for a in apps { if let b = a["bundleIdentifier"] as? String, b.hasPrefix("org.nxnative.") { found[b] = (a["version"] as? String) ?? (a["bundleVersion"] as? String) ?? "" } }
            DispatchQueue.main.async { if found != self.onDevice { self.onDevice = found } }
        }
    }
    enum PhoneState { case absent, current, older, outside }
    /// A library game's state on a device: not there; there from Cartridge with the Mac app's engine (current) or another (older); or there, not installed by Cartridge
    func state(of g: Game, on udid: String) -> PhoneState {
        guard onDevice[g.bundleID] != nil else { return .absent }
        guard let theirs = installedCommits["\(udid)|\(g.bundleID)"] else { return .outside }
        let mine = NSDictionary(contentsOf: g.contents.appendingPathComponent("Info.plist"))?["DMCommit"] as? String
        return mine == nil || theirs == mine ? .current : .older
    }

    func refresh() {
        DispatchQueue.global().async {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("nxl-devices-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: f) }
            shell("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", f.path, "--quiet"])
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let list = (o["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return }
            let found: [Device] = list.compactMap { x in
                let hw = x["hardwareProperties"] as? [String: Any] ?? [:], dp = x["deviceProperties"] as? [String: Any] ?? [:], cp = x["connectionProperties"] as? [String: Any] ?? [:]
                guard hw["platform"] as? String == "iOS", hw["reality"] as? String == "physical", let udid = hw["udid"] as? String else { return nil }
                guard cp["pairingState"] as? String == "paired" else { return nil }
                return Device(udid: udid, name: dp["name"] as? String ?? (hw["deviceType"] as? String ?? "Device"), model: hw["marketingName"] as? String ?? "", os: dp["osVersionNumber"] as? String ?? "",
                              transport: (cp["transportType"] as? String) == "wired" ? "USB" : "network")
            }
            DispatchQueue.main.async { if found != self.devices { self.devices = found } }
        }
    }

    /// An IPA's app name and bundle ID, from its Info.plist
    func add(ipa: URL, titleID: String? = nil, source: String? = nil, romfsSeparate: Bool = false) {
        let (code, list) = shell("/usr/bin/unzip", ["-Z1", ipa.path])
        guard code == 0, let plistPath = list.split(separator: "\n").first(where: { $0.hasPrefix("Payload/") && $0.hasSuffix(".app/Info.plist") && $0.split(separator: "/").count == 3 }) else {
            say("[RED] \(ipa.lastPathComponent): not an IPA"); return
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-p", ipa.path, String(plistPath)]
        let pipe = Pipe(); p.standardOutput = pipe; try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
        let item = IPAItem(path: ipa.path, bundleID: info["CFBundleIdentifier"] as? String ?? "", name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ipa.lastPathComponent,
                           titleID: titleID ?? (info["DMTitleID"] as? String ?? ""), source: source, romfsSeparate: romfsSeparate || (info["DMRomfsSeparate"] as? Bool ?? false))
        ipas.removeAll { $0.path == item.path }; ipas.insert(item, at: 0); persist()
        // an iPhone build asked for by Update on iPhone: installed on its device now that it is here
        let tid = item.titleID.uppercased()
        if let udid = pending[tid] {
            pending[tid] = nil
            if let d = devices.first(where: { $0.udid == udid }) { install(item, on: d, pushFiles: true) }
            else { say("\(item.name) is built for iPhone; connect the device and press Install.") }
        }
    }
    /// Update on iPhone: the game's iPhone build from its known source, installed on the device when it lands
    func update(_ g: Game, on d: Device) -> Bool {
        guard let builder, var r = builder.rebuildRequest(for: g) else { say("[RED] \(g.name): its files were not found; rebuild it once from its page."); return false }
        r.target = .ios; r.outFolder = nil
        pending[g.titleID.uppercased()] = d.udid
        builder.enqueue(r)
        say("Building \(g.name) for iPhone; it is installed on \(d.name) when the build finishes.")
        return true
    }
    func remove(_ i: IPAItem) { ipas.removeAll { $0 == i }; persist() }

    private func say(_ s: String) { DispatchQueue.main.async { self.log.append(s); if self.log.count > 500 { self.log.removeFirst(100) } } }

    func install(_ ipa: IPAItem, on d: Device, pushFiles: Bool) {
        guard !busy else { return }
        guard team.count == 10 else { say("[RED] Set your Team ID first (Xcode › Settings › Accounts, your team)."); return }
        busy = true; log = []
        let team = self.team, repo = builder?.repo ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            defer { DispatchQueue.main.async { self.busy = false } }
            do { try self.installSteps(ipa, d, team: team, repo: repo, pushFiles: pushFiles) }
            catch { self.say("[RED] \(error.localizedDescription)") }
        }
    }

    struct Failure: LocalizedError { let errorDescription: String? ; init(_ s: String) { errorDescription = s } }

    private func installSteps(_ ipa: IPAItem, _ d: Device, team: String, repo: String, pushFiles: Bool) throws {
        let fm = FileManager.default, ipaURL = URL(fileURLWithPath: ipa.path)
        let work = ipaURL.deletingLastPathComponent().appendingPathComponent(".\(ipaURL.deletingPathExtension().lastPathComponent).install")   // on the IPA's drive: it is as big as the game
        try? fm.removeItem(at: work); try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        say("Unpacking \(ipaURL.lastPathComponent)…")
        var (c, out) = shell("/usr/bin/ditto", ["-x", "-k", ipa.path, work.path])
        guard c == 0 else { throw Failure("Could not unpack the IPA: \(out)") }
        guard let appName = try fm.contentsOfDirectory(atPath: work.appendingPathComponent("Payload").path).first(where: { $0.hasSuffix(".app") }) else { throw Failure("The IPA has no app") }
        let app = work.appendingPathComponent("Payload").appendingPathComponent(appName)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        let exe = app.appendingPathComponent(info["CFBundleExecutable"] as? String ?? "")

        // The entitlements the app asks for (its ad-hoc signature), as the placeholder's capabilities
        (c, out) = shell("/usr/bin/codesign", ["-d", "--entitlements", ":-", exe.path])
        var wanted = (try? PropertyListSerialization.propertyList(from: Data(out.utf8.drop { $0 != UInt8(ascii: "<") }), format: nil)) as? [String: Any] ?? [:]
        wanted = wanted.filter { $0.key.hasPrefix("com.apple.developer.kernel.") }

        say("Signing for team \(team)…")
        let stub = try provision(bundleID: ipa.bundleID, team: team, device: d, entitlements: wanted)
        try fm.copyItem(at: stub.appendingPathComponent("embedded.mobileprovision"), to: app.appendingPathComponent("embedded.mobileprovision"))
        let ent = work.appendingPathComponent("entitlements.plist")
        (c, out) = shell("/usr/bin/codesign", ["-d", "--entitlements", ent.path, "--xml", stub.path])
        guard c == 0 else { throw Failure("Could not read the placeholder's entitlements: \(out)") }
        (c, out) = shell("/usr/bin/codesign", ["-dvv", stub.path])
        guard let authority = out.split(separator: "\n").first(where: { $0.hasPrefix("Authority=") }).map({ String($0.dropFirst(10)) }) else { throw Failure("The placeholder is not signed: \(out)") }
        // nested code first, then the app with the entitlements
        let e = fm.enumerator(at: app, includingPropertiesForKeys: nil)
        var nested: [URL] = []
        while let u = e?.nextObject() as? URL { if ["framework", "dylib", "appex"].contains(u.pathExtension) { nested.append(u) } }
        for u in nested.sorted(by: { $0.path.count > $1.path.count }) {
            (c, out) = shell("/usr/bin/codesign", ["--force", "--sign", authority, "--timestamp=none", u.path])
            guard c == 0 else { throw Failure("Could not sign \(u.lastPathComponent): \(out)") }
        }
        (c, out) = shell("/usr/bin/codesign", ["--force", "--sign", authority, "--timestamp=none", "--entitlements", ent.path, app.path])
        guard c == 0 else { throw Failure("Could not sign the app: \(out)") }
        say("Signed with \(authority).")

        say("Installing on \(d.name) (\(d.transport))… a large game takes a few minutes.")
        (c, out) = shell("/usr/bin/xcrun", ["devicectl", "device", "install", "app", "--device", d.udid, app.path]) { [weak self] l in
            if l.contains("%") || l.lowercased().contains("install") { self?.say(l.trimmingCharacters(in: .whitespaces)) }
        }
        guard c == 0 else {
            if out.contains("Developer Mode") { throw Failure("Turn on Developer Mode on the device (Settings › Privacy & Security), then try again.") }
            throw Failure("The install failed: \(out.split(separator: "\n").suffix(4).joined(separator: "\n"))")
        }
        say("✓ Installed \(ipa.name). The first start may ask you to trust your developer certificate: Settings › General › VPN & Device Management.")
        let commit = info["DMCommit"] as? String ?? ""
        DispatchQueue.main.async { self.installedCommits["\(d.udid)|\(ipa.bundleID)"] = commit; self.readApps(d.udid) }

        if pushFiles, ipa.romfsSeparate, let files = gameFiles(ipa) {
            say("Copying the game files (\(files.lastPathComponent))…")
            (c, out) = shell("/bin/bash", ["\(repo)/scripts/push_romfs.sh", d.udid, ipa.bundleID, files.path], cwd: URL(fileURLWithPath: repo)) { [weak self] l in self?.say(l) }
            guard c == 0 else { throw Failure("Copying the game files failed (push_romfs.sh). Install libimobiledevice for large games: brew install libimobiledevice") }
            say("✓ Game files copied.")
        }
    }

    /// What push_romfs.sh takes for a --romfs separate build: the Xcode project's resources.env, else the newest extracted RomFS.img
    func gameFiles(_ ipa: IPAItem) -> URL? {
        guard let src = ipa.source, !ipa.titleID.isEmpty else { return nil }
        var base = URL(fileURLWithPath: src); if base.pathExtension.lowercased() == "nup" { base.deleteLastPathComponent() }
        let build = base.appendingPathComponent("\(ipa.titleID)_build"), fm = FileManager.default
        let env = build.appendingPathComponent("xcode/Gen/resources.env")
        if fm.fileExists(atPath: env.path) { return env }
        let ex = build.appendingPathComponent("extract")
        let imgs = ((try? fm.contentsOfDirectory(atPath: ex.path)) ?? []).map { ex.appendingPathComponent($0).appendingPathComponent("RomFS.img") }.filter { fm.fileExists(atPath: $0.path) }
        return imgs.max { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast <
                          (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
    }

    /// The placeholder app for a bundle ID and team (kept in the launcher's caches, made again when its inputs change): Xcode makes the certificate, App ID and profile
    private func provision(bundleID: String, team: String, device: Device, entitlements: [String: Any]) throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("org.nxnative.launcher/provision/\(team)/\(bundleID)")
        let products = dir.appendingPathComponent("dd/Build/Products/Debug-iphoneos/Placeholder.app")
        func build(_ ent: [String: Any]) -> (Int32, String) {
            try? fm.removeItem(at: dir); try? fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
            try? "int main(void) { return 0; }\n".write(to: dir.appendingPathComponent("src/main.c"), atomically: true, encoding: .utf8)
            if let d = try? PropertyListSerialization.data(fromPropertyList: ent, format: .xml, options: 0) { try? d.write(to: dir.appendingPathComponent("Placeholder.entitlements")) }
            let yml = """
            name: Placeholder
            options: { bundleIdPrefix: org.nxnative }
            targets:
              Placeholder:
                type: application
                platform: iOS
                deploymentTarget: "26.0"
                sources: [src]
                settings:
                  PRODUCT_BUNDLE_IDENTIFIER: \(bundleID)
                  DEVELOPMENT_TEAM: \(team)
                  CODE_SIGN_STYLE: Automatic
                  GENERATE_INFOPLIST_FILE: YES
                  CODE_SIGN_ENTITLEMENTS: Placeholder.entitlements
                  TARGETED_DEVICE_FAMILY: "1,2"
            """
            try? yml.write(to: dir.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
            let (c, o) = shell("/usr/bin/env", ["xcodegen", "generate", "--quiet"], cwd: dir)
            if c != 0 { return (c, "xcodegen: \(o) (install it: brew install xcodegen)") }
            return shell("/usr/bin/xcrun", ["xcodebuild", "-project", "Placeholder.xcodeproj", "-scheme", "Placeholder", "-configuration", "Debug", "-destination", "id=\(device.udid)",
                                            "-derivedDataPath", "dd", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "build"], cwd: dir)
        }
        var (c, out) = build(entitlements)
        if c != 0, !entitlements.isEmpty {
            say("⚠︎ Your team could not give the app \(entitlements.keys.sorted().joined(separator: ", ")) : signing without it. A large game may run out of memory.")
            (c, out) = build([:])
        }
        guard c == 0, fm.fileExists(atPath: products.appendingPathComponent("embedded.mobileprovision").path) else {
            let why = out.split(separator: "\n").filter { $0.contains("error") }.suffix(3).joined(separator: "\n")
            throw Failure("Xcode could not sign for \(bundleID). Sign in to your Apple ID in Xcode › Settings › Accounts, check the Team ID, and keep the device unlocked.\n\(why)")
        }
        return products
    }
}

struct DevicesView: View {
    @EnvironmentObject var devices: Devices
    @EnvironmentObject var library: Library
    @State private var device: String?
    @State private var ipa: String?
    @State private var pushFiles = true

    var body: some View {
        HSplitView {
            Form {
                Section("iPhone or iPad") {
                    if devices.devices.isEmpty {
                        Text("No iPhone or iPad. Connect it with a cable, unlock it and trust this Mac; Developer Mode must be on (Settings › Privacy & Security).").foregroundStyle(.secondary)
                    }
                    Picker("Device", selection: $device) {
                        ForEach(devices.devices) { Text("\($0.name) · \($0.model) · iOS \($0.os) · \($0.transport)").tag(Optional($0.udid)) }
                    }
                    .disabled(devices.devices.isEmpty)
                }
                if let d = devices.devices.first(where: { $0.udid == device }) {
                    Section("Your games on this \(d.model.lowercased().contains("ipad") ? "iPad" : "iPhone")") {
                        ForEach(library.games) { g in
                            let st = devices.state(of: g, on: d.udid)
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(g.name)
                                    Text(devices.pending[g.titleID.uppercased()] != nil ? "Building for iPhone…"
                                         : st == .absent ? "Not on this device" : st == .current ? "Up to date" : st == .older ? "Older than the Mac's: update it" : "On this device (installed another way)")
                                        .font(.footnote).foregroundStyle(st == .older ? .orange : .secondary)
                                }
                                Spacer()
                                if st != .current && devices.pending[g.titleID.uppercased()] == nil {
                                    Button(st == .absent ? "Install" : "Update") { _ = devices.update(g, on: d) }
                                        .disabled(devices.busy || devices.team.count != 10)
                                }
                            }
                        }
                        Button("Check Again") { devices.readApps(d.udid) }
                        Text("An update builds the game for iPhone from its files and installs it. Saves carry over through Cloud saves (Settings), not through installing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("App") {
                    Picker("IPA", selection: $ipa) {
                        ForEach(devices.ipas) { Text("\($0.name) — \(URL(fileURLWithPath: $0.path).lastPathComponent)").tag(Optional($0.id)) }
                    }
                    HStack {
                        Button("Add IPA…") {
                            let p = NSOpenPanel(); p.allowedContentTypes = [.init(filenameExtension: "ipa")!]; p.allowsMultipleSelection = true
                            if p.runModal() == .OK { p.urls.forEach { devices.add(ipa: $0) }; ipa = devices.ipas.first?.id }
                        }
                        if let i = devices.ipas.first(where: { $0.id == ipa }) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.path)]) }
                            Button("Remove from List") { devices.remove(i); ipa = nil }
                        }
                    }
                    if let i = devices.ipas.first(where: { $0.id == ipa }), i.romfsSeparate {
                        Toggle("Copy the game files after installing (this build keeps them out of the IPA)", isOn: $pushFiles)
                    }
                }
                Section("Signing") {
                    HStack {
                        TextField("Team ID", text: $devices.team, prompt: Text("10 characters"))
                        Button("Find") { devices.team = Devices.xcodeTeam() ?? Devices.keychainTeam() ?? devices.team }
                    }
                    if devices.team.count != 10 {
                        Text("Not found yet: in Xcode › Settings › Accounts, select your Apple ID, click Manage Certificates…, add an Apple Development certificate with +, then click Find.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text("The app is signed with your Apple ID: sign in to Xcode once (Settings › Accounts) and put your team's ID here. A free Apple ID works: its apps stop opening after 7 days (install again; the save stays) and only a few can be installed at once. A paid developer account has neither limit.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button(devices.busy ? "Installing…" : "Install") {
                        if let d = devices.devices.first(where: { $0.udid == device }), let i = devices.ipas.first(where: { $0.id == ipa }) { devices.install(i, on: d, pushFiles: pushFiles) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(devices.busy || device == nil || ipa == nil || devices.team.count != 10)
                    Text("Other ways: open the IPA in AltStore, SideStore, Sideloadly or LiveContainer.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).frame(minWidth: 420)
            ScrollView {
                Text(devices.log.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .frame(minWidth: 320)
        }
        .onAppear {
            devices.watch(true)
            if ipa == nil { ipa = devices.ipas.first?.id }
        }
        .onDisappear { devices.watch(false) }
        .onChange(of: devices.devices) { if device == nil || !devices.devices.contains(where: { $0.udid == device }) { device = devices.devices.first?.udid } }
        .onChange(of: device) { if let device { devices.readApps(device) } }
        .onDrop(of: [.fileURL], isTargeted: nil) { ps in
            for p in ps { _ = p.loadObject(ofClass: URL.self) { u, _ in if let u, u.pathExtension == "ipa" { DispatchQueue.main.async { devices.add(ipa: u); ipa = devices.ipas.first?.id } } } }
            return true
        }
    }
}
