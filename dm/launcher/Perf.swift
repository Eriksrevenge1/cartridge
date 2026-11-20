// Tuning a game to this Mac from how it actually played: the host logs a summary every 300 frames (dm/gfx/nvn/hle_nvn.c tsummary: frame time, GPU time, frames on screen
// and dropped, against the frame-rate cap), so after a session Cartridge reads the game's log and, when the session was long enough to judge, says how it ran and what to
// change. GPU time grows with the pixels drawn, the square of the render scale, so a scale that brings the GPU's p95 to 70 % of the frame budget is scale × √(0.7 budget / p95).
// Nothing is measured specially and nothing runs by itself: the suggestion is applied with one click, as if chosen in the settings below it. The host already picks how many
// screen refreshes each frame stays (its frame step), so the choices here are the ones it does not make: render scale, the frame-rate cap and MetalFX's upscaling.
import Foundation
import SwiftUI

struct SessionPerf {
    var fpsCap: Int             // the frame-rate cap the session ran at (the budget is 1000 / cap)
    var renderScale: Double?    // the 3D views' scale, when the game has the setting
    var metalFX = false         // the present upscaled with MetalFX
    var windows = 0             // 300-frame windows judged (the first minute of loading left out)
    var gpuP95 = 0.0, gpuP50 = 0.0, frameP95 = 0.0
    var dropped = 0, shown = 0
    var ended = Date.distantPast   // the log's last write: when the session ended
    var budget: Double { 1000 / Double(fpsCap) }
    var dropShare: Double { shown > 0 ? Double(dropped) / Double(shown) : 0 }
    var minutes: Double { Double(windows) * 300 / Double(fpsCap) / 60 }

    /// The game's last session from its log; nil when there is none or it was too short to judge (under about two minutes of play after loading)
    static func read(_ g: Game) -> SessionPerf? {
        guard let text = try? String(contentsOf: g.log, encoding: .utf8) else { return nil }
        var p = SessionPerf(fpsCap: 60)
        p.ended = ((try? FileManager.default.attributesOfItem(atPath: g.log.path))?[.modificationDate] as? Date) ?? .distantPast
        var gpu95: [Double] = [], gpu50: [Double] = [], frame95: [Double] = [], skip = 0
        func num(_ s: Substring, after key: String) -> Double? {
            guard let r = s.range(of: key) else { return nil }
            return Double(s[r.upperBound...].prefix { "0123456789.".contains($0) })
        }
        for line in text.split(separator: "\n") {
            if line.contains("[dm] main: ") && line.contains("capped at "), let v = num(line, after: "capped at ") { p.fpsCap = Int(v) }
            else if line.contains("3D views rendered at "), let v = num(line, after: "rendered at ") { p.renderScale = v }
            else if line.contains("present upscaling (DM_PRESENT_UPSCALE): ") { p.metalFX = line.contains("): metalfx") }
            else if line.contains("[nvn] timing up to frame ") {
                skip += 1
                guard skip > 12 else { continue }   // the first 3600 frames (a minute at 60 fps): the title, loading, pipelines being built
                guard let f = line.range(of: "frame time ").map({ line[$0.upperBound...] }), let fp = num(f, after: "p95 "),
                      let gp = line.range(of: "GPU p50 ").map({ line[$0.lowerBound...] }), let g50 = num(gp, after: "GPU p50 "), let g95 = num(gp, after: "p95 ") else { continue }
                frame95.append(fp); gpu50.append(g50); gpu95.append(g95); p.windows += 1
            } else if line.contains("[nvn] on-screen up to frame "), skip > 12, let n = num(line, after: ": "), let d = num(line, after: "dropped ") {
                p.shown += Int(n); p.dropped += Int(d)
            }
        }
        guard p.windows >= 12 else { return nil }   // two minutes or so after the first: enough windows that a cut scene or a menu does not decide
        func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
        p.gpuP95 = median(gpu95); p.gpuP50 = median(gpu50); p.frameP95 = median(frame95)
        return p
    }

    var struggling: Bool { dropShare > 0.05 || frameP95 > budget * 1.3 }

    var summary: String {
        String(format: "Last session (%.0f min): %d fps cap, %.1f %% of frames late or dropped; GPU %.1f ms of the %.1f ms each frame has (p95)",
               minutes, fpsCap, dropShare * 100, gpuP95, budget)
    }
}

struct PerfSuggestion {
    let env: String, value: String, text: String
}

extension SessionPerf {
    /// What to change, if anything: a struggling session is lightened (render scale down, else MetalFX off, else a lower cap); a session with room to spare is sharpened
    /// (render scale up, else a higher cap the game offers). Rows an env file fixes are not suggested
    /// ceiling: per setting, a raised value that did not hold on this Mac (PerfMemory): nothing at or above it is suggested again, so a game does not go back and forth
    func suggestion(rows: [Setting], fixed: Set<String>, ceiling: [String: Double] = [:]) -> PerfSuggestion? {
        let row = Dictionary(rows.map { ($0.env, $0) }, uniquingKeysWith: { a, _ in a })
        func free(_ k: String) -> Setting? { fixed.contains(k) ? nil : row[k] }
        let roomy = dropShare < 0.01 && frameP95 <= budget * 1.1 && gpuP95 < budget * 0.6
        let gpuBound = gpuP95 > budget * 0.8
        func scaled(_ s: Double, _ r: Setting, down: Bool) -> String? {
            let want = s * (budget * 0.7 / max(gpuP95, 0.1)).squareRoot()
            let step = r.step ?? 0.05, lo = r.min ?? 0.5, hi = r.max ?? 1.0
            var v = (want / step).rounded(.down) * step
            v = min(max(v, lo), hi)
            if !down, let c = ceiling[r.env] { v = min(v, c - step) }
            if down ? v > s - step / 2 : v < s + step / 2 { return nil }
            return String(format: "%.2f", v)
        }
        if struggling {
            if gpuBound, let r = free("DM_RENDER_SCALE"), let v = scaled(renderScale ?? 1, r, down: true) {
                return PerfSuggestion(env: r.env, value: v, text: "The GPU ran out of time: render scale \(v) should hold \(fpsCap) fps.")
            }
            if gpuBound, metalFX, let r = free("DM_PRESENT_UPSCALE"), r.accepts("off") {
                return PerfSuggestion(env: r.env, value: "off", text: "The GPU ran out of time: MetalFX upscaling off saves some of it.")
            }
            if let r = free("DM_FPS_TARGET"), let lower = (r.options ?? []).compactMap({ Int($0[0]) }).filter({ $0 < fpsCap }).max() {
                return PerfSuggestion(env: r.env, value: String(lower), text: "\(fpsCap) fps did not hold\(gpuBound ? "" : " (the CPU, not the GPU, was the limit)"): \(lower) fps plays steadier.")
            }
        } else if roomy {
            if let r = free("DM_RENDER_SCALE"), let v = scaled(renderScale ?? 1, r, down: false) {
                return PerfSuggestion(env: r.env, value: v, text: "The GPU had time to spare: render scale \(v) looks sharper and should still hold \(fpsCap) fps.")
            }
            if let r = free("DM_FPS_TARGET"), let higher = (r.options ?? []).compactMap({ Int($0[0]) }).filter({ $0 > fpsCap && Double($0) < ceiling[r.env] ?? .infinity }).min(),
               gpuP95 < 1000 / Double(higher) * 0.6, frameP95 <= budget * 1.05 {
                return PerfSuggestion(env: r.env, value: String(higher), text: "The GPU had time to spare: \(higher) fps should hold.")
            }
        }
        return nil
    }
}

/// What tuning learned per game, in Cartridge's own defaults: the last raise applied (setting and value), and the raises that then did not hold (ceilings)
enum PerfMemory {
    private static var store: UserDefaults { .standard }
    static func ceilings(_ g: Game) -> [String: Double] { (store.dictionary(forKey: "perf.ceiling.\(g.titleID)") as? [String: Double]) ?? [:] }
    static func applied(_ g: Game, _ s: PerfSuggestion, raise: Bool) {
        if raise { store.set([s.env, s.value, String(Date().timeIntervalSince1970)], forKey: "perf.raised.\(g.titleID)") } else { store.removeObject(forKey: "perf.raised.\(g.titleID)") }
    }
    /// The first session after a raise, still at the raised value: when it struggled, that value is too much for this Mac. Sessions from before the raise are not judged
    static func judge(_ g: Game, _ p: SessionPerf, current: [String: String]) {
        guard let r = store.stringArray(forKey: "perf.raised.\(g.titleID)"), r.count == 3, let at = Double(r[2]), p.ended.timeIntervalSince1970 > at else { return }
        guard current[r[0]] == r[1], let v = Double(r[1]) else { store.removeObject(forKey: "perf.raised.\(g.titleID)"); return }   // the player changed it since
        if p.struggling { var c = ceilings(g); c[r[0]] = v; store.set(c, forKey: "perf.ceiling.\(g.titleID)") }
        store.removeObject(forKey: "perf.raised.\(g.titleID)")   // judged once, at the first session long enough to judge
    }
}

/// The section at the top of a game's Settings: how the last session ran and, when something should change, the change with an Apply button. The settings view reads the
/// session (SessionPerf.read) while the game is not running
struct PerfSection: View {
    let game: Game
    let perf: SessionPerf?
    @ObservedObject var m: LauncherModel
    @State private var applied: String?
    var body: some View {
        if let p = perf {
            Section("Performance on this Mac") {
                Text(p.summary).font(.callout).foregroundStyle(.secondary)
                if let s = p.suggestion(rows: m.settings, fixed: m.fixed, ceiling: PerfMemory.ceilings(game)), m.values[s.env] != s.value {
                    HStack {
                        Label(s.text, systemImage: "wand.and.stars")
                        Spacer()
                        Button("Apply") {
                            let raise = (Double(s.value) ?? 0) > (Double(m.values[s.env] ?? "") ?? .infinity)
                            m.values[s.env] = s.value; applied = s.text; PerfMemory.applied(game, s, raise: raise)
                        }.buttonStyle(.borderedProminent)
                    }
                } else if let a = applied {
                    Label("Applied: \(a) It takes effect at the next start.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Label("These settings suit this Mac.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 120 fps on a Switch 2 game: the game chooses it itself, in its own options or by default, once it has told the system it can run at 120 Hz (dm/gfx/hle_vi.c logs
/// "vi::SetDisplay120HzRefreshRateCapability 1"). Its files cannot say so beforehand: Ocarina of Time's engine has the call and passes 0. So Cartridge learns it from the game's
/// log after a session, remembers it, and says on the Settings page where 120 fps is chosen: the Frame rate setting offers only 30 and 60 (the app's own cap), which read as "no 120"
enum Game120 {
    struct Seen { var capable: Bool; var ran120: Bool }
    private static func key(_ g: Game) -> String { "fps120.\(g.titleID)" }
    /// What the last session's log shows, nil when it does not mention the 120 Hz capability
    static func scan(_ g: Game) -> Seen? {
        guard let text = try? String(contentsOf: g.log, encoding: .utf8) else { return nil }
        var s: Seen?
        for line in text.split(separator: "\n") where line.contains("vi::SetDisplay120HzRefreshRateCapability ") || line.contains("vi: display refresh rate ") {
            if line.contains("SetDisplay120HzRefreshRateCapability 1") { s = Seen(capable: true, ran120: s?.ran120 ?? false || line.contains("display runs at 120 Hz")) }
            else if line.contains("SetDisplay120HzRefreshRateCapability 0") { s = s ?? Seen(capable: false, ran120: false) }
            else if line.contains("→ 120 Hz") { s?.ran120 = true }
        }
        return s
    }
    /// Read the last session and remember a game that turned 120 Hz on (once seen, it stays known: a session spent in a 60 fps mode does not undo it)
    static func learn(_ g: Game) -> Seen? {
        let s = scan(g)
        if s?.capable == true { UserDefaults.standard.set(true, forKey: key(g)) }
        return s
    }
    static func known(_ g: Game) -> Bool { UserDefaults.standard.bool(forKey: key(g)) }
}

/// The line beside Frame rate for a game known to run at 120 fps
struct Game120Row: View {
    let ranLast: Bool
    let hostCapped: Bool   // the profile's Frame rate row: a cap of 30 or 60 that the app applies, which holds the game below 120
    var body: some View {
        LabeledContent {
            Text(hostCapped ? "Not in this build" : "In the game's own options").foregroundStyle(.secondary)
        } label: {
            Text("120 fps")
            Text(hostCapped
                 ? "This game can run at 120 fps, but this build caps its frame rate with the setting above, so it plays at 30 or 60."
                 : "This game can run at 120 fps. Turn it on in the game's own settings (often called Performance mode or Frame rate). It plays at 120 fps on a screen running at 120 Hz, and at 60 on a 60 Hz screen.\(ranLast ? " Your last session ran at 120 fps." : "")")
        }
    }
}
