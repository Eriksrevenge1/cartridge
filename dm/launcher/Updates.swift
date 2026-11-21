// Updates (Settings › Updates; Cartridge › Check for Updates…): Cartridge's new versions from the GitHub releases of the fork it was built from (Info.plist DMUpdateRepo,
// scripts/build_launcher.py; scripts/release_cartridge.py publishes them). A release is tagged cartridge-<build> (the commit count, Info.plist CFBundleVersion) with the app as
// Cartridge.zip; Stable takes releases, Experimental pre-releases too. The repository is public, so nothing signs in. Checked at start once a day (or never), and on Check Now.
// An update downloads to the games folder's drive (the home drive is kept free), replaces Cartridge (the old one goes to the Trash) and starts the new one, which unpacks its
// engine beside the previous (Engine.swift keeps one to go back to). Games built with an older engine then say so on their page (Health.swift): Rebuild to update
import AppKit
import SwiftUI

struct CartridgeRelease: Equatable {
    let tag: String, build: Int, prerelease: Bool, notes: String, asset: URL, size: Int64
}

final class Updates: ObservableObject {
    static let shared = Updates()
    enum State: Equatable { case idle, checking, upToDate, available(CartridgeRelease), downloading(Double), failed(String) }
    @Published var state: State = .idle
    private let store = UserDefaults.standard
    let repo: String? = Bundle.main.infoDictionary?["DMUpdateRepo"] as? String
    let build: Int = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0

    var experimental: Bool { get { store.bool(forKey: "updates.experimental") } set { store.set(newValue, forKey: "updates.experimental"); objectWillChange.send() } }
    var automatic: Bool { get { store.object(forKey: "updates.auto") as? Bool ?? true } set { store.set(newValue, forKey: "updates.auto"); objectWillChange.send() } }

    /// At start: a check once a day, when automatic
    func startCheck() {
        guard automatic, repo != nil else { return }
        if let last = store.object(forKey: "updates.last") as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        check(ask: true)
    }
    /// ask: a check of its own (at start) asks whether to update when it finds one
    func check(ask: Bool = false) {
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
            let best = found.filter { $0.build > build && (experimental || !$0.prerelease) }.max { $0.build < $1.build }
            state = best.map { .available($0) } ?? .upToDate
            if ask, let best {
                let a = NSAlert(); a.messageText = "Cartridge 1.\(best.build) is available"
                a.informativeText = (best.prerelease ? "An experimental version. " : "") + String(best.notes.prefix(600))
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
                Picker("Channel", selection: Binding(get: { u.experimental }, set: { u.experimental = $0 })) {
                    Text("Stable").tag(false); Text("Experimental (newer, less tested)").tag(true)
                }
                Toggle("Check for updates once a day", isOn: Binding(get: { u.automatic }, set: { u.automatic = $0 }))
                HStack {
                    Button("Check Now") { u.check() }.disabled(u.state == .checking)
                    switch u.state {
                    case .idle: EmptyView()
                    case .checking: ProgressView().controlSize(.small)
                    case .upToDate: Text("Cartridge is up to date.").foregroundStyle(.secondary)
                    case .available(let r): Text(verbatim: "Cartridge 1.\(r.build)\(r.prerelease ? " (experimental)" : "") is available.")   // verbatim: no digit grouping ("1.1,844")
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
