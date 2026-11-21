// Updates (Settings › Updates; Cartridge › Check for Updates…): Cartridge's new versions from the GitHub releases of the fork it was built from (Info.plist DMUpdateRepo,
// scripts/build_launcher.py; scripts/release_cartridge.py publishes them). A release is tagged cartridge-<build> (the commit count, Info.plist CFBundleVersion) with the app as
// Cartridge.zip; one channel: every release (and the pre-releases published before there was one) counts. The repository is public, so nothing signs in. Checked at start once a day (or never), and on Check Now.
// An update downloads to the games folder's drive (the home drive is kept free), replaces Cartridge (the old one goes to the Trash) and starts the new one, which unpacks its
// engine beside the previous (Engine.swift keeps one to go back to). Games built with an older engine then say so on their page (Health.swift): Rebuild to update.
// While Cartridge stays open it checks again every few hours, and asks only about a version it has not asked about yet. Releases come from the fork's follow-upstream
// workflow: every upstream change that merges and passes its tests becomes a release. Upstream publishes no stable versions (only main), so there is no Stable channel
import AppKit
import SwiftUI

struct CartridgeRelease: Equatable {
    let tag: String, build: Int, prerelease: Bool, notes: String, asset: URL, size: Int64
}

final class Updates: ObservableObject {
    static let shared = Updates()
    enum State: Equatable {
        case idle, checking, upToDate, available(CartridgeRelease), downloading(Double), failed(String)
        var isDownloading: Bool { if case .downloading = self { return true }; return false }
    }
    @Published var state: State = .idle
    private let store = UserDefaults.standard
    let repo: String? = Bundle.main.infoDictionary?["DMUpdateRepo"] as? String
    let build: Int = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0

    var automatic: Bool { get { store.object(forKey: "updates.auto") as? Bool ?? true } set { store.set(newValue, forKey: "updates.auto"); objectWillChange.send() } }

    private var timer: Timer?
    static let every: TimeInterval = 6 * 3600
    /// At start: a check once a day, when automatic; then every few hours while Cartridge is open
    func startCheck() {
        guard repo != nil else { return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
                guard let self, self.automatic, self.state != .checking, !(self.state.isDownloading) else { return }
                self.check(ask: true, onlyNew: true)
            }
        }
        guard automatic else { return }
        if let last = store.object(forKey: "updates.last") as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        check(ask: true)
    }
    /// ask: a check of its own (at start, or the periodic one) asks whether to update when it finds one; onlyNew: not about a version it asked about already
    func check(ask: Bool = false, onlyNew: Bool = false) {
        guard let repo, let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30") else { state = .failed("This Cartridge was built without an update source."); return }
        state = .checking
        Task { @MainActor in
            var r = URLRequest(url: url, timeoutInterval: 20); r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { state = .failed("Could not reach GitHub."); return }
            store.set(Date(), forKey: "updates.last")
            let found: [CartridgeRelease] = list.compactMap { o in
                guard let tag = o["tag_name"] as? String, tag.hasPrefix("cartridge-"), let b = Int(tag.dropFirst("cartridge-".count)),
                      (o["draft"] as? Bool) != true, let assets = o["assets"] as? [[String: Any]],
                      let a = assets.first(where: { ($0["name"] as? String) == "Cartridge.zip" }), let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
                return CartridgeRelease(tag: tag, build: b, prerelease: o["prerelease"] as? Bool ?? false, notes: o["body"] as? String ?? "", asset: u, size: (a["size"] as? NSNumber)?.int64Value ?? 0)
            }
            let best = found.filter { $0.build > build }.max { $0.build < $1.build }
            state = best.map { .available($0) } ?? .upToDate
            if ask, let best, !(onlyNew && store.integer(forKey: "updates.asked") >= best.build) {
                store.set(best.build, forKey: "updates.asked")
                let a = NSAlert(); a.messageText = "Cartridge 1.\(best.build) is available"
                a.informativeText = String(best.notes.prefix(600))
                a.addButton(withTitle: "Update and Restart"); a.addButton(withTitle: "Later")
                if a.runModal() == .alertFirstButtonReturn { install(best) }
            }
        }
    }
    /// Download, replace, restart
    func install(_ rel: CartridgeRelease) {
        guard let root = GamesFolder.root else { state = .failed("Choose a games folder first (Setup Assistant): updates download to its drive."); return }
        let dir = root.appendingPathComponent(".cartridge-update"), zip = dir.appendingPathComponent("Cartridge.zip"), unz = dir.appendingPathComponent("new")
        state = .downloading(0)
        let me = Bundle.main.bundleURL
        Task.detached {
            let fm = FileManager.default
            try? fm.removeItem(at: dir); try? fm.createDirectory(at: unz, withIntermediateDirectories: true)
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: rel.asset)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "Cartridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "The download failed."]) }
                try fm.moveItem(at: tmp, to: zip)
                await MainActor.run { self.state = .downloading(1) }
                guard shell("/usr/bin/ditto", ["-x", "-k", zip.path, unz.path]).0 == 0, let app = try fm.contentsOfDirectory(at: unz, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
                      (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String).flatMap(Int.init) == rel.build
                else { throw NSError(domain: "Cartridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "The downloaded Cartridge is not the expected version."]) }
                // the running app goes to the Trash (its files stay open until it quits) and the new one takes its place
                try fm.trashItem(at: me, resultingItemURL: nil)
                try fm.moveItem(at: app, to: me)
                try? fm.removeItem(at: dir)
                await MainActor.run {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 1; open \"\(me.path)\""]; try? p.run()
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
        }
    }
}

struct UpdatesSettingsView: View {
    @ObservedObject var u = Updates.shared
    var body: some View {
        Form {
            LabeledContent("This version", value: "1.\(u.build)\(Engine.shared.version.map { " (engine \($0))" } ?? "")")
            if u.repo == nil {
                Text("This Cartridge was built without an update source (no fork remote).").foregroundStyle(.secondary)
            } else {
                Toggle("Check for updates automatically (at start once a day, and every few hours while open)", isOn: Binding(get: { u.automatic }, set: { u.automatic = $0 }))
                HStack {
                    Button("Check Now") { u.check() }.disabled(u.state == .checking)
                    switch u.state {
                    case .idle: EmptyView()
                    case .checking: ProgressView().controlSize(.small)
                    case .upToDate: Text("Cartridge is up to date.").foregroundStyle(.secondary)
                    case .available(let r): Text(verbatim: "Cartridge 1.\(r.build) is available.")   // verbatim: no digit grouping ("1.1,844")
                    case .downloading: ProgressView().controlSize(.small); Text("Downloading…").foregroundStyle(.secondary)
                    case .failed(let m): Text(m).foregroundStyle(.red)
                    }
                }
                if case .available(let r) = u.state {
                    if !r.notes.isEmpty { Text(r.notes).font(.callout).lineLimit(8).foregroundStyle(.secondary) }
                    Button("Update and Restart") { u.install(r) }.buttonStyle(.borderedProminent)
                    Text("Games built with the older engine will ask to be rebuilt; your saves and settings stay.").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Updates come from github.com/\(u.repo ?? "")'s releases.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
