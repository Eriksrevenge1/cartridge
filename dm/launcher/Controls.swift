// The player's controls (dm/host/controls.h; docs/frontends.md, Controls): the model of the file, the same lines the host reads, and its editor. Two files: every game's
// (~/Library/Application Support/nxnative/controls.txt) and a game's own, read after it. Each file holds only what differs from the level under it (built in, then every game's),
// so a change to every game's controls reaches each game that did not change that control itself.
import AppKit
import SwiftUI

enum Ctl {
    static let buttons = ["A", "B", "X", "Y", "L", "R", "ZL", "ZR", "LS", "RS", "Plus", "Minus", "Left", "Up", "Right", "Down", "LSL", "LSR", "RSL", "RSR"]
    static let directions = ["LUp", "LDown", "LLeft", "LRight", "RUp", "RDown", "RLeft", "RRight"]
    static let actions = buttons + directions + ["Shake"]
    static let labels: [String: String] = [
        "LS": "Left stick press", "RS": "Right stick press", "Plus": "+", "Minus": "−", "Left": "D-pad left", "Up": "D-pad up", "Right": "D-pad right", "Down": "D-pad down",
        "LSL": "Left Joy-Con SL", "LSR": "Left Joy-Con SR", "RSL": "Right Joy-Con SL", "RSR": "Right Joy-Con SR",
        "LUp": "Left stick up", "LDown": "Left stick down", "LLeft": "Left stick left", "LRight": "Left stick right",
        "RUp": "Right stick up", "RDown": "Right stick down", "RLeft": "Right stick left", "RRight": "Right stick right", "Shake": "Shake",
    ]
    static func label(_ a: String) -> String { labels[a] ?? a }
    static func canonical(_ name: String) -> String? { actions.first { $0.caseInsensitiveCompare(name) == .orderedSame } }
    /// "A+ZR" → ["A", "ZR"]; "none" → []; nil when a name is unknown
    static func parse(_ s: String) -> [String]? {
        if s.caseInsensitiveCompare("none") == .orderedSame { return [] }
        var out: [String] = []
        for part in s.split(separator: "+", omittingEmptySubsequences: false) {
            guard let c = canonical(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            if !out.contains(c) { out.append(c) }
        }
        return out.isEmpty ? nil : actions.filter(out.contains)   // in one order, so two lists of the same actions compare equal
    }
    static func text(_ a: [String]) -> String { a.isEmpty ? "none" : actions.filter(a.contains).joined(separator: "+") }
    static func describe(_ a: [String]) -> String { a.isEmpty ? "Nothing" : actions.filter(a.contains).map(label).joined(separator: " + ") }

    /// controls.h CTL_KEY_DEFAULTS
    static let keyDefaults: [Int: [String]] = [13: ["LUp"], 0: ["LLeft"], 1: ["LDown"], 2: ["LRight"], 38: ["A"], 40: ["B"], 32: ["X"], 34: ["Y"], 3: ["LS"], 5: ["RS"],
                                                12: ["L"], 14: ["R"], 6: ["ZL"], 8: ["ZR"], 36: ["Plus"], 48: ["Minus"], 123: ["Left"], 126: ["Up"], 124: ["Right"], 125: ["Down"], 49: ["Shake"]]
    /// macOS virtual key codes (kVK_*) by name, for the keys an ANSI keyboard has
    static let keyNames: [Int: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S",
        17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\",
        41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 117: "Forward Delete", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2",
        85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 65: "Keypad .", 76: "Keypad Enter",
        69: "Keypad +", 78: "Keypad -", 67: "Keypad *", 75: "Keypad /",
    ]
    static func keyName(_ code: Int) -> String { keyNames[code] ?? "Key \(code)" }
}

struct Controls: Equatable {
    var pad: [String: [String]] = Dictionary(uniqueKeysWithValues: Ctl.buttons.map { ($0, [$0]) })
    var swapSticks = false
    var keys: [Int: [String]] = Ctl.keyDefaults
    var mouse = "off"
    var mouseSpeed = 1.0
    var mouseInvertY = false
    var mouseButtons: [String: [String]] = ["left": ["ZR"], "right": ["ZL"], "middle": ["RS"]]

    static let builtIn = Controls()

    /// One line of the file (controls.h ctl_line); false when it is not understood
    @discardableResult mutating func apply(_ raw: Substring) -> Bool {
        var line = String(raw); if let h = line.firstIndex(of: "#") { line = String(line[..<h]) }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return true }
        let word = String(line.prefix { !$0.isWhitespace && $0 != "=" }).lowercased()
        let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        if word == "key", rest.lowercased() == "clear" { keys = [:]; return true }
        var lhs: String?, rhs: String
        if rest.hasPrefix("=") { rhs = rest.dropFirst().trimmingCharacters(in: .whitespaces) }
        else if let eq = rest.firstIndex(of: "=") { lhs = rest[..<eq].trimmingCharacters(in: .whitespaces); rhs = rest[rest.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
        else { return false }
        switch (word, lhs) {
        case ("pad", let l?):
            if l.lowercased() == "swap_sticks" { swapSticks = (Int(rhs) ?? 0) != 0; return true }
            guard let b = Ctl.canonical(l), Ctl.buttons.contains(b), let a = Ctl.parse(rhs), a.allSatisfy(Ctl.buttons.contains) else { return false }
            pad[b] = a; return true
        case ("key", let l?):
            guard let code = Int(l), (0..<128).contains(code), let a = Ctl.parse(rhs) else { return false }
            keys[code] = a; return true
        case ("mouse", nil):
            guard ["off", "right", "left"].contains(rhs.lowercased()) else { return false }
            mouse = rhs.lowercased(); return true
        case ("mouse_speed", nil):
            guard let v = Double(rhs), v >= 0.1, v <= 10 else { return false }
            mouseSpeed = v; return true
        case ("mouse_invert_y", nil): mouseInvertY = (Int(rhs) ?? 0) != 0; return true
        case ("mouse_button", let l?):
            guard ["left", "right", "middle"].contains(l.lowercased()), let a = Ctl.parse(rhs) else { return false }
            mouseButtons[l.lowercased()] = a; return true
        default: return false
        }
    }
    mutating func load(_ url: URL) {
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { return }
        for l in t.split(whereSeparator: \.isNewline) { apply(l) }
    }
    func with(_ url: URL) -> Controls { var c = self; c.load(url); return c }

    /// The lines that make `base` this (only what differs)
    func lines(over base: Controls) -> [String] {
        var out: [String] = []
        for b in Ctl.buttons where pad[b] != base.pad[b] { out.append("pad \(b)=\(Ctl.text(pad[b] ?? [b]))") }
        if swapSticks != base.swapSticks { out.append("pad swap_sticks=\(swapSticks ? 1 : 0)") }
        for code in Set(keys.keys).union(base.keys.keys).sorted() where (keys[code] ?? []) != (base.keys[code] ?? []) {
            out.append("key \(code)=\(Ctl.text(keys[code] ?? []))   # \(Ctl.keyName(code))")
        }
        if mouse != base.mouse { out.append("mouse=\(mouse)") }
        if abs(mouseSpeed - base.mouseSpeed) > 1e-6 { out.append(String(format: "mouse_speed=%.2f", mouseSpeed)) }
        if mouseInvertY != base.mouseInvertY { out.append("mouse_invert_y=\(mouseInvertY ? 1 : 0)") }
        for b in ["left", "right", "middle"] where mouseButtons[b] != base.mouseButtons[b] { out.append("mouse_button \(b)=\(Ctl.text(mouseButtons[b] ?? []))") }
        return out
    }
    func write(to url: URL, over base: Controls, scope: String) throws {
        let body = lines(over: base)
        if body.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = (["# nxnative controls (\(scope)), written by nxnative Launcher: dm/host/controls.h"] + body).joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The editor of one file: every game's, or one game's over every game's
final class ControlsModel: ObservableObject {
    static var globalFile: URL { Game.supportRoot.appendingPathComponent("controls.txt") }
    let file: URL
    let base: Controls          // the level under this file
    let scope: String
    @Published var c: Controls { didSet { if c != oldValue { save() } } }
    @Published var error: String?

    init(game: Game?) {
        let global = Controls.builtIn.with(ControlsModel.globalFile)
        if let game { file = game.controlsFile; base = global; scope = "this game: \(game.name)" }
        else { file = ControlsModel.globalFile; base = .builtIn; scope = "every game" }
        c = base.with(file)
    }
    private func save() {
        do { try c.write(to: file, over: base, scope: scope); error = nil } catch { self.error = error.localizedDescription }
    }
    func reset() { c = base }
    var changedCount: Int { c.lines(over: base).count }
}

struct ActionPicker: View {
    let title: String
    @Binding var value: [String]
    var options: [String] = Ctl.actions
    var body: some View {
        Picker(title, selection: Binding(get: { value.count == 1 ? value[0] : value.isEmpty ? "" : Ctl.text(value) },
                                         set: { value = $0.isEmpty ? [] : (Ctl.parse($0) ?? []) })) {
            Text("Nothing").tag("")
            ForEach(options, id: \.self) { Text(Ctl.label($0)).tag($0) }
            if value.count > 1 { Text(Ctl.describe(value)).tag(Ctl.text(value)) }   // a combination written in the file
        }
    }
}

/// A sheet that waits for one key press: its key code, or nil (Escape cancels; Escape itself is not bindable: it gives the pointer back)
struct KeyCatcher: NSViewRepresentable {
    let onKey: (Int?) -> Void
    final class V: NSView {
        var onKey: ((Int?) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
        override func keyDown(with e: NSEvent) { onKey?(e.keyCode == 53 ? nil : Int(e.keyCode)) }
        override func flagsChanged(with e: NSEvent) {}
    }
    func makeNSView(context: Context) -> V { let v = V(); v.onKey = onKey; return v }
    func updateNSView(_ v: V, context: Context) { v.onKey = onKey }
}

struct ControlsView: View {
    let game: Game
    @State private var scopeGame = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Controls for", selection: $scopeGame) {
                Text("This game").tag(true)
                Text("Every game").tag(false)
            }
            .pickerStyle(.segmented).padding([.horizontal, .top]).frame(maxWidth: 360)
            if scopeGame { ControlsEditor(m: ControlsModel(game: game)).id("game-\(game.id)") }
            else { ControlsEditor(m: ControlsModel(game: nil)).id("global") }
        }
    }
}

struct ControlsEditor: View {
    @StateObject var m: ControlsModel
    @State private var catching = false
    init(m: ControlsModel) { _m = StateObject(wrappedValue: m) }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(m.changedCount == 0 ? "Nothing changed from \(m.scope.hasPrefix("this") ? "every game's controls" : "the built-in controls")."
                                             : "\(m.changedCount) change\(m.changedCount == 1 ? "" : "s") for \(m.scope).")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { m.reset() }.disabled(m.changedCount == 0)
                    Button("Open File") { NSWorkspace.shared.activateFileViewerSelecting([m.file]) }.disabled(!FileManager.default.fileExists(atPath: m.file.path))
                }
                if let e = m.error { Text(e).foregroundStyle(.red) }
                Text("Changes take effect at the game's next start.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Controller") {
                Text("Each button of every controller, by position: a Nintendo pad's labels; another pad's right, bottom, top and left face buttons are A, B, X and Y.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Swap the sticks", isOn: $m.c.swapSticks)
                ForEach(Ctl.buttons, id: \.self) { b in
                    ActionPicker(title: Ctl.label(b), value: Binding(get: { m.c.pad[b] ?? [b] }, set: { m.c.pad[b] = $0 }), options: Ctl.buttons)
                }
            }
            Section("Keyboard") {
                ForEach(m.c.keys.keys.sorted(by: { Ctl.keyName($0) < Ctl.keyName($1) }), id: \.self) { code in
                    HStack {
                        ActionPicker(title: Ctl.keyName(code), value: Binding(get: { m.c.keys[code] ?? [] }, set: { m.c.keys[code] = $0 }))
                        Button { m.c.keys[code] = [] } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Unbind this key")
                    }
                }
                Button("Add a Key…") { catching = true }
                Text("Shift with an arrow key that keeps its built-in action is the right stick. Escape gives back a captured pointer.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Mouse") {
                Picker("The mouse is", selection: $m.c.mouse) {
                    Text("The touch screen").tag("off")
                    Text("The right stick (camera)").tag("right")
                    Text("The left stick").tag("left")
                }
                if m.c.mouse != "off" {
                    Text("Click in the game to capture the pointer; Escape gives it back.").font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Text("Speed")
                        Slider(value: $m.c.mouseSpeed, in: 0.1...10)
                        Text(String(format: "%.1f×", m.c.mouseSpeed)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    Toggle("Invert up and down", isOn: $m.c.mouseInvertY)
                    ForEach(["left", "right", "middle"], id: \.self) { b in
                        ActionPicker(title: "\(b.capitalized) button", value: Binding(get: { m.c.mouseButtons[b] ?? [] }, set: { m.c.mouseButtons[b] = $0 }))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $catching) {
            VStack(spacing: 16) {
                Text("Press a key").font(.title2)
                Text("Escape cancels.").foregroundStyle(.secondary)
                KeyCatcher { code in
                    catching = false
                    if let code, m.c.keys[code]?.isEmpty ?? true { m.c.keys[code] = ["A"] }
                }.frame(width: 1, height: 1)
            }
            .padding(40)
        }
    }
}
