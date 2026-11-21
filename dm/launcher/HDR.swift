// HDR calibration (Settings › Display; docs/launcher.md, HDR calibration): per screen, how bright a game with HDR of its own makes its highlights next to its white. On a Mac
// the console's peak test cannot work: macOS shows EDR relative to SDR white and caps it to the screen's current brightness itself (a DELL S2725QC at a middling brightness: 1.7
// times white, where its range at full brightness is 4.18), so a pattern clips wherever the brightness setting puts it, and the host already fits the game's highlights into what
// the screen shows. What is the player's to choose is the highlights' strength: one slider, from subtle to the screen's whole range, with a preview drawn the way the host draws
// the game (rolled into the current headroom). Kept in hdr.calibration (screen name → { peak, paper } in nits: paper the BT.2408 203, peak 203 times the strength); each game's
// launcher passes it as DM_HDR_CALIBRATION (dm/mac/launcher.c) and the host tells the game the entry of the screen its window is on (dm/gfx/hle_vi.c). Only a screen in HDR
// mode can be set: the preview is drawn in EDR on that screen (extended linear sRGB, SDR white = 1.0), which a screen without HDR cannot show.
// Games without HDR of their own keep auto-HDR and do not read these values
import AppKit
import Metal
import QuartzCore
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
            } header: { Text("HDR highlights") } footer: {
                Text("How bright Switch 2 games with HDR of their own (they draw HDR when the screen is in HDR mode) make their highlights next to their white. macOS sets how much of that the screen shows at its current brightness: raise the brightness for brighter highlights. Games read it when they start. Other games keep auto-HDR.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Games with HDR of their own") {
                if let n = games.names { Text(n.isEmpty ? "None in the library." : n.joined(separator: ", ")).foregroundStyle(.secondary) }
                else { ProgressView().controlSize(.small) }
            }
        }
        .formStyle(.grouped)
        .id(tick)
        .onAppear { games.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in screens = NSScreen.screens; tick += 1 }
    }
    @ViewBuilder func screenRow(_ s: NSScreen) -> some View {
        let name = s.localizedName
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                if s.isHDR {
                    Button("Adjust…") { CalibrationWindows.open(for: s) }
                    if HDRCalibration.get(name) != nil { Button("Reset") { HDRCalibration.set(name, nil); tick += 1 } }
                }
            }
            if s.isHDR {
                let c = HDRCalibration.get(name), d = HDRCalibration.defaults(for: s)
                Text(c.map { String(format: "Highlights up to %.1f times the game's white (set)", Double($0.peak) / Double($0.paper)) }
                     ?? String(format: "Highlights up to %.1f times the game's white: the screen's whole range (default)", Double(d.peak) / Double(d.paper)))
                    .font(.callout)
                Text(String(format: "HDR range up to %.2f times SDR white", s.maximumPotentialExtendedDynamicRangeColorComponentValue)).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("This screen is not in HDR mode (turn on High Dynamic Range in System Settings › Displays).").font(.callout).foregroundStyle(.secondary)
            }
        }
        .opacity(s.isHDR ? 1 : 0.55)
    }
}

/// One calibration window per screen, placed on that screen (its EDR patterns must be drawn there)
enum CalibrationWindows {
    static var open: [String: NSWindow] = [:]
    static func open(for s: NSScreen) {
        let name = s.localizedName
        if let w = open[name] { place(w, on: s); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "HDR Calibration – \(name)"; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: CalibrationView(screenName: name, close: { [weak w] in w?.close() }))
        place(w, on: s)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in open[name] = nil }
        open[name] = w
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    static func place(_ w: NSWindow, on s: NSScreen) {
        let f = s.visibleFrame, sz = w.frame.size
        w.setFrameOrigin(NSPoint(x: f.midX - sz.width / 2, y: f.midY - sz.height / 2))
    }
}

struct CalibrationView: View {
    let screenName: String
    let close: () -> Void
    @State private var strength: Double = 3   // highlights' peak, in times the game's white
    @State private var current: Double = 1    // what the screen shows now (its EDR headroom at the current brightness)
    @State private var onScreen: String? = nil
    @State private var loaded = false
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    var target: NSScreen? { NSScreen.screens.first { $0.localizedName == screenName } }
    var full: Double { max(Double(target?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 2), 1.5) }
    var body: some View {
        VStack(spacing: 12) {
            if let t = target, !t.isHDR {
                Spacer(); Text("\(screenName) is not in HDR mode: turn on High Dynamic Range in System Settings › Displays to adjust it.").multilineTextAlignment(.center); Spacer()
            } else if onScreen != nil && onScreen != screenName {
                Spacer()
                Text("Move this window to \(screenName): the preview has to be shown on that screen.").multilineTextAlignment(.center)
                Button("Move It There") { if let t = target, let w = CalibrationWindows.open[screenName] { CalibrationWindows.place(w, on: t) } }
                Spacer()
            } else {
                EDRPattern(mode: 1, peak: Float(strength), headroom: Float(current)).frame(minHeight: 300)
                Text("The card is the game's white; the sun and the disc are its brightest highlights, drawn as the game will be.").font(.callout)
                HStack {
                    Text("Highlights")
                    Text("Subtle").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $strength, in: 1.25...full)
                    Text("Full").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.1f×", strength)).monospacedDigit().frame(width: 50, alignment: .trailing)
                }
                Text(current + 0.05 < min(strength, full)
                     ? String(format: "At its current brightness this screen shows up to %.1f times white: raise the brightness to see the highlights fully.", current)
                     : String(format: "This screen shows up to %.1f times white at its current brightness.", current))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button("Default (Full)") { strength = full }
                Spacer()
                Button("Cancel") { close() }
                Button("Save") {
                    let w = HDRCalibration.defaultPaper
                    HDRCalibration.set(screenName, abs(strength - full) < 0.05 ? nil : HDRCalibration(peak: Int((strength * Double(w)).rounded()), paper: w)); close()
                }.keyboardShortcut(.defaultAction)
            }
            Text("Games read this when they start.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            guard !loaded else { return }; loaded = true
            if let c = HDRCalibration.get(screenName) { strength = min(max(Double(c.peak) / Double(c.paper), 1.25), full) } else { strength = full }
            onScreen = CalibrationWindows.open[screenName]?.screen?.localizedName
            current = Double(target?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        }
        .onReceive(timer) { _ in
            onScreen = CalibrationWindows.open[screenName]?.screen?.localizedName
            current = max(Double(target?.maximumExtendedDynamicRangeColorComponentValue ?? 1), 1)
        }
    }
}

/// The preview, drawn in EDR (extended linear sRGB in half floats; 1.0 = SDR white = the game's white): a dusk scene with a white card (1.0) carrying lines of text, a sun and
/// a disc at the highlights' peak, its luminance rolled off into the screen's current headroom above three quarters of it as the host's present does (present.metal, src_pq)
struct EDRPattern: NSViewRepresentable {
    let mode: Int
    let peak: Float
    var headroom: Float = 64
    func makeNSView(context: Context) -> EDRView { EDRView() }
    func updateNSView(_ v: EDRView, context: Context) { v.mode = mode; v.peak = peak; v.headroom = headroom; v.draw() }
}

final class EDRView: NSView {
    var mode = 0, peak: Float = 3, headroom: Float = 64
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private var pso: MTLRenderPipelineState?
    private var metal: CAMetalLayer { layer as! CAMetalLayer }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metal.device = device; metal.pixelFormat = .rgba16Float; metal.wantsExtendedDynamicRangeContent = true
        metal.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metal.isOpaque = true; metal.framebufferOnly = true
        if let d = device, let lib = try? d.makeLibrary(source: Self.shader, options: nil) {
            let pd = MTLRenderPipelineDescriptor(); pd.vertexFunction = lib.makeFunction(name: "vs"); pd.fragmentFunction = lib.makeFunction(name: "fs"); pd.colorAttachments[0].pixelFormat = .rgba16Float
            pso = try? d.makeRenderPipelineState(descriptor: pd)
        }
    }
    required init?(coder: NSCoder) { nil }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override func layout() { super.layout(); draw() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); draw() }
    func draw() {
        let scale = window?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        let size = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        if metal.drawableSize != size { metal.drawableSize = size }
        guard let pso, let q = queue, let dr = metal.nextDrawable(), let cb = q.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor(); rp.colorAttachments[0].texture = dr.texture; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        guard let en = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        var u: [Float] = [Float(mode), peak, Float(size.width / size.height), headroom]
        en.setRenderPipelineState(pso); en.setFragmentBytes(&u, length: MemoryLayout<Float>.size * 4, index: 0)
        en.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); en.endEncoding()
        cb.present(dr); cb.commit()
    }
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 p [[position]]; float2 uv; };
    vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
    struct U { float mode, peak, aspect, headroom; };
    static float3 fit(float3 l, float h) {   // as the host's present: above 3/4 of the headroom the luminance rolls off into it
        float y = dot(l, float3(0.2126, 0.7152, 0.0722)), k = 0.75 * h;
        if (h > 1.0 && y > k) l *= (k + (h - k) * (1.0 - exp(-(y - k) / (h - k)))) / y;
        return l;
    }
    fragment float4 fs(V in [[stage_in]], constant U& u [[buffer(0)]]) {
        float2 p = (in.uv - 0.5) * float2(u.aspect, 1);   // centred, height 1
        float3 c = float3(0.06 + 0.06 * in.uv.y);
        float2 card = p - float2(-0.18, 0.02);
        if (all(abs(card) < float2(0.3, 0.2))) {
            c = float3(1.0);
            float row = fmod(card.y + 0.2, 0.06);
            if (card.y > -0.14 && card.y < 0.14 && row < 0.02 && card.x > -0.25 && card.x < 0.2 - 0.1 * step(0.08, card.y)) c = float3(0.08);
        }
        float d = length(p - float2(0.42, 0.12));
        if (d < 0.11) c = float3(u.peak) * float3(1.0, 0.97, 0.9);
        else if (d < 0.16) c = mix(c, float3(u.peak * 0.4), 1.0 - (d - 0.11) / 0.05);
        float sd = length(p - float2(0.42, -0.3));   // a sun low over the horizon, a gradient up to the peak
        if (sd < 0.09) c = max(c, float3(u.peak * (1.0 - sd / 0.09 * 0.6)) * float3(1.0, 0.85, 0.6));
        return float4(fit(c, u.headroom), 1);
    }
    """
}
