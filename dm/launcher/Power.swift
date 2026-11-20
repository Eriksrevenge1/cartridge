// On battery: a game Cartridge starts while the Mac runs on its battery gets lighter settings, as launch values (launch values beat the saved choices, launcher.c
// saved_choices), so the player's saved choices stay as they are and apply again on the charger. Only rows the game has, and only to lower what it would use: the frame
// rate to 30, the render scale to the chosen cap. A value an env file sets is left alone. It is decided at the start: plugging in or out during the
// game changes nothing until the next start.
import Foundation
import IOKit.ps
import SwiftUI

enum Power {
    /// The Mac has a battery (a laptop)
    static var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { (IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any])?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
    }
    /// The Mac runs on its battery now
    static var onBattery: Bool {
        if let f = ProcessInfo.processInfo.environment["DM_CARTRIDGE_ON_BATTERY"] { return f == "1" }   // diagnostics: a Mac without a battery, or one on the charger
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue
    }
}

/// The player's battery plan (Settings › Battery)
struct BatteryPlan {
    @AppStorage("battery.enabled") var enabled = true
    @AppStorage("battery.fps30") var fps30 = true
    @AppStorage("battery.scale") var scale = 0.75   // 1.0: the game's own setting

    /// The launch values for this game now: none on the charger, with the plan off, or where the game already uses less
    func overrides(for g: Game) -> [String: String] {
        guard enabled, Power.onBattery else { return [:] }
        let rows = Dictionary(g.settings().map { ($0.env, $0) }, uniquingKeysWith: { a, _ in a })
        let fixed = g.envFileValues(), env = ProcessInfo.processInfo.environment
        let saved = UserDefaults(suiteName: g.bundleID)
        func current(_ s: Setting) -> String {
            if let v = saved?.object(forKey: "launcher." + s.env) as? String, s.accepts(v) { return v }
            return s.def
        }
        var out: [String: String] = [:]
        func set(_ k: String, _ v: String) { if fixed[k] == nil, env[k] == nil { out[k] = v } }
        if fps30, let s = rows["DM_FPS_TARGET"], s.accepts("30"), (Int(current(s)) ?? 0) > 30 { set(s.env, "30") }
        if scale < 1, let s = rows["DM_RENDER_SCALE"], (Double(current(s)) ?? 1) > scale + 1e-6 {
            let v = max(scale, s.min ?? scale)
            if s.accepts(String(format: "%.2f", v)) { set(s.env, String(format: "%.2f", v)) }
        }
        return out
    }
    /// What the plan did, for the log and the game page
    static func describe(_ o: [String: String]) -> String? {
        var parts: [String] = []
        if let v = o["DM_FPS_TARGET"] { parts.append("\(v) fps") }
        if let v = o["DM_RENDER_SCALE"], let d = Double(v) { parts.append("render scale \(Int((d * 100).rounded())) %") }
        return parts.isEmpty ? nil : "On battery: " + parts.joined(separator: ", ")
    }
}

struct BatterySettingsView: View {
    @AppStorage("battery.enabled") private var enabled = true
    @AppStorage("battery.fps30") private var fps30 = true
    @AppStorage("battery.scale") private var scale = 0.75
    private let battery = Power.hasBattery
    var body: some View {
        Form {
            if !battery { Text("This Mac has no battery: these settings apply only on a Mac laptop.").foregroundStyle(.secondary) }
            Toggle("Use lighter settings when a game starts on battery", isOn: $enabled)
            Group {
                Toggle("Frame rate 30 fps", isOn: $fps30)
                Picker("Render scale at most", selection: $scale) {
                    Text("The game's setting").tag(1.0)
                    ForEach([0.9, 0.8, 0.75, 0.7, 0.6, 0.5], id: \.self) { Text("\(Int(($0 * 100).rounded())) %").tag($0) }
                }
            }
            .disabled(!enabled)
            Text("Each one applies only where the game has the setting and uses more than this. Your saved settings are not changed: they apply again on the charger. Plugging in or out takes effect at the game's next start.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
