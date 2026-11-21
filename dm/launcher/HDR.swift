// HDR calibration (Settings › Display; docs/launcher.md, HDR calibration): per screen, the peak brightness and paper white a game with HDR of its own is told, like the
// Switch 2's HDR adjustment. Kept in hdr.calibration (screen name → { peak, paper } in nits); each game's launcher passes it as DM_HDR_CALIBRATION (dm/mac/launcher.c) and the
// host answers the game's QueryDisplayHdrStatus / QueryDisplayHdrPaperWhite with the entry of the screen its window is on (dm/gfx/hle_vi.c). Only a screen in HDR mode can be
// calibrated: the patterns are drawn in EDR on that screen (extended linear sRGB, SDR white = 1.0 = the paper white), which a screen without HDR cannot show.
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
            } header: { Text("HDR calibration") } footer: {
                Text("Tells Switch 2 games with HDR of their own (they draw HDR when the screen is in HDR mode) how bright this screen can go and how bright their whites should be, like the Switch 2's HDR adjustment. Games read it when they start. macOS manages the screen's brightness itself: these values describe what the screen shows. Other games keep auto-HDR.")
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
                    Button("Calibrate…") { CalibrationWindows.open(for: s) }
                    if HDRCalibration.get(name) != nil { Button("Reset") { HDRCalibration.set(name, nil); tick += 1 } }
                }
            }
            if s.isHDR {
                let c = HDRCalibration.get(name), d = HDRCalibration.defaults(for: s)
                Text(c.map { "Peak \($0.peak) nits, paper white \($0.paper) nits (calibrated)" } ?? "Peak \(d.peak) nits, paper white \(d.paper) nits (defaults: not calibrated)")
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
    enum Step: Int { case peak, paper }
    @State private var step = Step.peak
    @State private var peak: Double = 600
    @State private var paper: Double = Double(HDRCalibration.defaultPaper)
    @State private var onScreen: String? = nil
    @State private var loaded = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var target: NSScreen? { NSScreen.screens.first { $0.localizedName == screenName } }
    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $step) { Text("1. Peak brightness").tag(Step.peak); Text("2. Paper white").tag(Step.paper) }.pickerStyle(.segmented).labelsHidden()
            if let t = target, !t.isHDR {
                Spacer(); Text("\(screenName) is not in HDR mode: turn on High Dynamic Range in System Settings › Displays to calibrate it.").multilineTextAlignment(.center); Spacer()
            } else if onScreen != nil && onScreen != screenName {
                Spacer()
                Text("Move this window to \(screenName): the patterns have to be shown on the screen being calibrated.").multilineTextAlignment(.center)
                Button("Move It There") { if let t = target, let w = CalibrationWindows.open[screenName] { CalibrationWindows.place(w, on: t) } }
                Spacer()
            } else {
                EDRPattern(mode: step == .peak ? 0 : 1, peak: Float(peak / paper)).frame(minHeight: 300)
                if step == .peak {
                    Text("Raise the slider until the symbol in the square just disappears.").font(.callout)
                    HStack { Text("Peak"); Slider(value: $peak, in: max(paper, 200)...4000, step: 10); Text("\(Int(peak)) nits").monospacedDigit().frame(width: 90, alignment: .trailing) }
                } else {
                    Text("Set how bright the game's whites are next to its highlights: the card is the game's white, the disc its brightest highlight. Lower makes highlights stand out more.").font(.callout)
                    HStack { Text("Paper white"); Slider(value: $paper, in: 80...400, step: 1); Text("\(Int(paper)) nits").monospacedDigit().frame(width: 90, alignment: .trailing) }
                }
            }
            HStack {
                Button("Reset to Defaults") { if let t = target { let d = HDRCalibration.defaults(for: t); peak = Double(d.peak); paper = Double(d.paper) } }
                Spacer()
                Button("Cancel") { close() }
                Button("Save") { HDRCalibration.set(screenName, HDRCalibration(peak: Int(peak), paper: Int(paper))); close() }.keyboardShortcut(.defaultAction)
            }
            Text("Games read these values when they start.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            guard !loaded else { return }; loaded = true
            let c = HDRCalibration.get(screenName) ?? target.map(HDRCalibration.defaults(for:)) ?? HDRCalibration(peak: 600, paper: HDRCalibration.defaultPaper)
            peak = Double(c.peak); paper = Double(c.paper); onScreen = CalibrationWindows.open[screenName]?.screen?.localizedName
        }
        .onReceive(timer) { _ in onScreen = CalibrationWindows.open[screenName]?.screen?.localizedName }
    }
}

/// The calibration patterns, drawn in EDR (extended linear sRGB in half floats; 1.0 = SDR white = the paper white).
/// mode 0, peak: a dark field, a square at the candidate peak and a symbol inside it far brighter than any screen shows; once the square reaches what the screen can show both clip
/// to it and the symbol disappears. mode 1, paper white: a dim scene with a white card (1.0) carrying lines of text and a highlight disc at the peak
struct EDRPattern: NSViewRepresentable {
    let mode: Int
    let peak: Float
    func makeNSView(context: Context) -> EDRView { EDRView() }
    func updateNSView(_ v: EDRView, context: Context) { v.mode = mode; v.peak = peak; v.draw() }
}

final class EDRView: NSView {
    var mode = 0, peak: Float = 3
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
        var u: [Float] = [Float(mode), peak, Float(size.width / size.height), 0]
        en.setRenderPipelineState(pso); en.setFragmentBytes(&u, length: MemoryLayout<Float>.size * 4, index: 0)
        en.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); en.endEncoding()
        cb.present(dr); cb.commit()
    }
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 p [[position]]; float2 uv; };
    vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
    struct U { float mode, peak, aspect, pad; };
    fragment float4 fs(V in [[stage_in]], constant U& u [[buffer(0)]]) {
        float2 p = (in.uv - 0.5) * float2(u.aspect, 1);   // centred, height 1
        if (u.mode < 0.5) {
            float3 c = float3(0.02);
            if (all(abs(p) < 0.28)) {
                c = float3(u.peak);
                float r = length(p);
                bool ring = abs(r - 0.13) < 0.025, bar = abs(p.x) < 0.025 && abs(p.y) < 0.13;
                if (ring || bar) c = float3(64.0);   // far above any screen: clips to the screen's peak
            }
            return float4(c, 1);
        }
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
        return float4(c, 1);
    }
    """
}
