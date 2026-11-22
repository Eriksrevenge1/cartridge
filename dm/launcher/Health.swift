// The health check on a game's page: whether the app is whole, whether nxnative (the checkout Cartridge builds from) has changed what this game would be built with since
// its build, and whether there is room to play. "Ready" when nothing is found; otherwise each finding with what to do. The app's Info.plist names the commit it was built
// from (DMCommit) and the shader chain its libraries were translated with (DMChain, dm/gfx/nvn/dmsh_chain.h); the host loads only libraries of its own chain, so a
// newer chain means the game's shaders are rebuilt by a Rebuild.
import Foundation
import SwiftUI

struct HealthFinding: Identifiable, Hashable {
    enum Level { case info, warn, stop }
    let level: Level
    let text: String
    var id: String { text }
}

enum Health {
    /// The space a game needs to start and play: its pipeline cache and save grow in Application Support, on the home drive
    static let minFree: Int64 = 2_000_000_000

    static func check(_ g: Game) -> [HealthFinding] {
        var out: [HealthFinding] = []
        let fm = FileManager.default
        for (path, what) in [("MacOS/nxnative", "its launcher"), ("MacOS/dmhost", "the game's host"), ("Resources/dm/launcher.json", "its settings list")]
            where !fm.fileExists(atPath: g.contents.appendingPathComponent(path).path) {
            out.append(HealthFinding(level: .stop, text: "The app is missing \(what) (\(path)): Rebuild it."))
        }
        if let free = Builder.freeSpace(at: Game.supportRoot), free < minFree {
            out.append(HealthFinding(level: .warn, text: String(format: "Only %.1f GB free on your home drive, where the game keeps its save and caches: free some space before playing.", Double(free) / 1e9)))
        }
        let info = NSDictionary(contentsOf: g.contents.appendingPathComponent("Info.plist"))
        // built with the engine Cartridge carries: an app from another engine version asks for a rebuild (an update brought a newer one)
        // compared by the fingerprint of what reaches a game, not the commit: a Cartridge-only change asks for nothing.
        // An app without one (built before, or from your own checkout) is not judged
        // An app packed with the split fingerprints (DMEngineSharedHash, DMProfile and DMProfileHash; ENGINE_SHAREDHASH and ENGINE_PROFILEHASHES in the engine) asks only when the
        // update reaches it: the shared engine changed (every game), or its own profile did; changes to other games' profiles ask nothing
        if Engine.shared.builtIn, let dir = Engine.shared.installedDir {
            func read(_ n: String) -> String? { (try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
            let c = read("ENGINE_COMMIT") ?? ""
            // two fingerprint schemes: the current one leaves out tests and notes (.md), which never reach a game; .v1 counts them, as for the apps packed before. An app's
            // fingerprint matching either scheme's is up to date (each app was packed with one of them; they never coincide)
            func profileHash(_ table: String?, _ prof: String) -> String? {
                table?.split(separator: "\n").first { $0.split(separator: "\t").first.map { $0.uppercased() == prof.uppercased() } ?? false }?
                    .split(separator: "\t").dropFirst().first.map(String.init)
            }
            if let builtShared = info?["DMEngineSharedHash"] as? String, let nowShared = read("ENGINE_SHAREDHASH") {
                // scheme 3 (current) and 2 share the shared fingerprint and differ in the profile tables (3 leaves out the harness's smoke / bench / validated files);
                // a profile matching any scheme of the same shared fingerprint is up to date
                let schemes: [(shared: String, profiles: String?)] = [(nowShared, read("ENGINE_PROFILEHASHES")), (nowShared, read("ENGINE_PROFILEHASHES.v2"))]
                    + (read("ENGINE_SHAREDHASH.v1").map { [($0, read("ENGINE_PROFILEHASHES.v1"))] } ?? [])
                let matching = schemes.filter { $0.shared == builtShared }
                if matching.isEmpty {
                    out.append(HealthFinding(level: .info, text: "An update to nxnative reaches every game (\(c)): Rebuild to update."))
                    return out
                }
                if let prof = info?["DMProfile"] as? String, let builtProf = info?["DMProfileHash"] as? String {
                    let nows = matching.compactMap { profileHash($0.profiles, prof) }
                    if !nows.isEmpty && !nows.contains(builtProf) {
                        out.append(HealthFinding(level: .info, text: "An update changed this game's profile (\(c)): Rebuild to update."))
                    }
                }
                return out
            }
            if let now = read("ENGINE_GAMEHASH"), let built = info?["DMEngineHash"] as? String, built != now {   // an app packed before the split
                out.append(HealthFinding(level: .info, text: "Built with another nxnative than the one Cartridge builds with (\(c)): Rebuild to update."))
            }
            return out
        }
        let repo = UserDefaults.standard.string(forKey: "build.repo") ?? (Bundle.main.infoDictionary?["DMRepo"] as? String ?? "")
        guard !repo.isEmpty, fm.fileExists(atPath: repo + "/.git") else { return out }
        if let chain = info?["DMChain"] as? String, let h = try? String(contentsOfFile: repo + "/dm/gfx/nvn/dmsh_chain.h", encoding: .utf8),
           let now = h.split(separator: "\n").first(where: { $0.hasPrefix("#define DMSH_CHAIN ") })?.split(separator: "\"").dropFirst().first, String(now) != chain {
            out.append(HealthFinding(level: .warn, text: "nxnative's shader translator has changed since this build: Rebuild to get its fixes (the shaders are made again)."))
        }
        if let commit = info?["DMCommit"] as? String, !commit.isEmpty {
            // what a rebuild would take in: the host, graphics, the Mac app's own parts, the tools that rewrite and pack, the settings list and this game's profile
            var paths = ["dm/host", "dm/gfx", "dm/mac", "dm/tools", "dm/games/settings.tsv", "dm/games/settings.py"]
            if fm.fileExists(atPath: "\(repo)/dm/games/\(g.titleID)") { paths.append("dm/games/\(g.titleID)") }
            let (code, text) = shell("/usr/bin/git", ["-C", repo, "rev-list", "--count", "\(commit)..HEAD", "--"] + paths)
            if code == 0, let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
                out.append(HealthFinding(level: .info, text: "nxnative has \(n) newer change\(n == 1 ? "" : "s") that may reach this game: Rebuild to get \(n == 1 ? "it" : "them")."))
            }
        }
        return out
    }
}

/// The check's line on a game's page, run when the page opens and again after the game ends or the library changes
struct HealthLine: View {
    let game: Game
    @EnvironmentObject var library: Library
    @EnvironmentObject var builder: Builder
    @State private var findings: [HealthFinding]?
    private var trigger: String { "\(game.id)|\(library.running.contains(game.id))|\(game.buildStamp)|\(builder.jobs.count)" }
    var body: some View {
        // a VStack, not a Group: modifiers on a Group go to its children, and before the first check it has none, so its task would never start
        VStack(alignment: .leading, spacing: 0) {
            if let f = findings {
                if f.isEmpty {
                    Label("Ready to play", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(f) { x in
                            Label(x.text, systemImage: x.level == .stop ? "xmark.octagon.fill" : x.level == .warn ? "exclamationmark.triangle.fill" : "info.circle")
                                .foregroundStyle(x.level == .stop ? Color.red : x.level == .warn ? Color.orange : Color.secondary)
                        }
                    }
                }
            }
        }
        .font(.callout).frame(maxWidth: 640, alignment: .leading).padding(.horizontal).padding(.top, 6)
        .task(id: trigger) {
            let g = game
            findings = await Task.detached(priority: .utility) { Health.check(g) }.value
        }
    }
}
