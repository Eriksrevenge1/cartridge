// One launcher setting as a row (a menu, a slider with its percentage, a toggle), shared by the iOS launcher (Launcher.swift) and the Mac app's settings window (dm/mac/Launcher.swift).
// A row whose setting is fixed by an env file or by the launch environment is shown but disabled. A row the player moved off the value the game was tested with is marked:
// a dot, "Tested: <value>" under its label, and a button that puts the tested value back.
import SwiftUI

extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.values[s.env] = $0 }) }
}

struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.fixed.contains(s.env) }
    private var note: String {
        guard locked else { return s.note }
        return (s.note.isEmpty ? "" : s.note + " · ") + (m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file")
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var percentage: String { m.rangeLabel(s, rangeValue.wrappedValue) }

    private var changed: Bool { !locked && !s.isDefault(m.values[s.env] ?? s.def) }
    /// The tested value as the row shows values: the option's label, the slider's percentage, On or Off
    private var tested: String {
        switch s.kind {
        case "choice": return s.options?.first { $0[0] == s.def }?[1] ?? s.def
        case "range": return m.rangeLabel(s, Double(s.def) ?? 0)
        default: return s.def == s.onValue ? "On" : "Off"
        }
    }

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if changed { Circle().fill(Color.accentColor).frame(width: 7, height: 7).accessibilityLabel("Changed") }
                Text(s.label)
            }
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
            if changed {
                HStack(spacing: 6) {
                    Text("Tested: \(tested)").font(.footnote).foregroundStyle(.secondary)
                    Button("Use Tested") { m.values[s.env] = s.def }
                        .font(.footnote).buttonStyle(.borderless)
                        .accessibilityLabel("Use the tested value for \(s.label)")
                }
            }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice":
                Picker(selection: m.binding(s)) {
                    ForEach(offeredOptions(s, current: m.values[s.env]), id: \.[0]) { Text($0[1]).tag($0[0]) }
                } label: {
                    settingLabel
                }
                .pickerStyle(.menu)
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .accessibilityLabel(s.label)
                        .accessibilityValue(percentage)
                }
            default:
                Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })) {
                    settingLabel
                }
            }
        }
        .disabled(locked)
    }
}
