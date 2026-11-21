// HDR calibration (Settings › Display; docs/launcher.md, HDR calibration): per screen, how bright a game with HDR of its own makes its highlights next to its white. On a Mac
// the console's peak test cannot work: macOS shows EDR relative to SDR white and caps it to the screen's current brightness itself (a DELL S2725QC at a middling brightness: 1.7
// times white, where its range at full brightness is 4.18), so a pattern clips wherever the brightness setting puts it, and the host already fits the game's highlights into what
// the screen shows. What is the player's to choose is the highlights' strength: one slider per screen in Settings, from softer to the screen's whole range (the default). Kept in hdr.calibration (screen name → { peak, paper } in nits: paper the BT.2408 203, peak 203 times the strength); each game's
// launcher passes it as DM_HDR_CALIBRATION (dm/mac/launcher.c) and the host tells the game the entry of the screen its window is on (dm/gfx/hle_vi.c). Only a screen in HDR
// mode has the slider.
// Games without HDR of their own keep auto-HDR and do not read these values
import AppKit
import SwiftUI

struct HDRCalibration: Equatable {
    var peak: Int, paper: Int
    static let key = "hdr.calibration"
    static let defaultPaper = 203   // BT.2408's reference white, the host's default
    static func all() -> [String: HDRCalibration] {
        let d = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]] ?? [:]
        return d.compactMapValues { v in guard let p = v["peak"], let w = v["paper"], p > 0, w > 0 else { return nil }; return HDRCalibration(peak: p, paper: w) }
    }
    static func get(_ screen: String) -> HDRCalibration? { all()[screen] }
    static func set(_ screen: String, _ c: HDRCalibration?) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]] ?? [:]
        d[screen] = c.map { ["peak": $0.peak, "paper": $0.paper] }
        if d.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(d, forKey: key) }
    }
    /// What the host assumes without a calibration: the screen's potential EDR headroom times the paper white
    static func defaults(for s: NSScreen) -> HDRCalibration {
        HDRCalibration(peak: Int((s.maximumPotentialExtendedDynamicRangeColorComponentValue * Double(defaultPaper)).rounded()), paper: defaultPaper)
    }
}

extension NSScreen {
    var isHDR: Bool { maximumPotentialExtendedDynamicRangeColorComponentValue > 1.05 }
}

/// The library's games with HDR of their own: their main module imports the display's HDR status (nn::vi::QueryDisplayHdrStatus), read from the packed binary
final class NativeHDRGames: ObservableObject {
    static let shared = NativeHDRGames()
    @Published var names: [String]? = nil
    private var cache: [String: (Date, Bool)] = [:]
    func refresh() {
        let games = Library.shared.games
        DispatchQueue.global(qos: .utility).async {
            let needle = Data("_ZN2nn2vi21QueryDisplayHdrStatus".utf8)
            var out: [String] = []
            for g in games {
                let bin = g.dm.appendingPathComponent("main.patched.bin")
                let mod = (try? bin.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                var has: Bool
                if let c = self.cache[bin.path], c.0 == mod { has = c.1 }
                else { has = (try? Data(contentsOf: bin, options: .alwaysMapped))?.range(of: needle) != nil; self.cache[bin.path] = (mod, has) }
                if has { out.append(g.name) }
            }
            DispatchQueue.main.async { self.names = out.sorted() }
        }
    }
}

struct HDRSettingsView: View {
    @State private var screens: [NSScreen] = NSScreen.screens
    @State private var tick = 0
    @ObservedObject private var games = NativeHDRGames.shared
    var body: some View {
        Form {
            Section {
                ForEach(screens, id: \.localizedName) { s in screenRow(s) }
            } header: { Text("HDR") } footer: {
                Text(games.names.map { $0.isEmpty ? "For games with their own HDR. None in your library yet." : "For games with their own HDR: \($0.joined(separator: ", "))." } ?? "For games with their own HDR.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(tick)
        .onAppear { games.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in screens = NSScreen.screens; tick += 1 }
    }
    @ViewBuilder func screenRow(_ s: NSScreen) -> some View {
        if s.isHDR { HighlightsRow(screen: s) }
        else {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.localizedName)
                Text("Turn on HDR for this screen in System Settings › Displays to use this.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// One screen's highlights: a slider from softer to the screen's whole range (the default), saved as it moves
struct HighlightsRow: View {
    let screen: NSScreen
    @State private var value: Double = 0
    var full: Double { max(Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue), 1.5) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(screen.localizedName)
            HStack {
                Text("HDR highlights")
                Text("Softer").font(.caption).foregroundStyle(.secondary)
                Slider(value: $value, in: 1.25...full) { editing in if !editing { save() } }
                Text("Brighter").font(.caption).foregroundStyle(.secondary)
            }
            Text("Games pick this up the next time they start.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            let name = screen.localizedName
            value = HDRCalibration.get(name).map { min(max(Double($0.peak) / Double($0.paper), 1.25), full) } ?? full
        }
    }
    func save() {
        let w = HDRCalibration.defaultPaper
        HDRCalibration.set(screen.localizedName, abs(value - full) < 0.05 ? nil : HDRCalibration(peak: Int((value * Double(w)).rounded()), paper: w))
    }
}
