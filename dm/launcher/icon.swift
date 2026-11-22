// Cartridge's app icon, drawn here (scripts/build_launcher.py runs it after Logo.swift, whose LogoMark and Brand it uses): the logo, a classic
// cartridge with a ribbed top and a controller on its label, in the icon's own colours (a cyan shell, a red label) on a dark tile lit by both.
// Usage: swift icon.swift <out.iconset>
/// The tile: macOS's icon grid leaves about 10 % around the rounded square
struct Icon: View {
    let px: CGFloat
    var body: some View {
        let t = px * 0.8
        ZStack {
            RoundedRectangle(cornerRadius: t * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(.sRGB, red: 0.10, green: 0.10, blue: 0.15), Color(.sRGB, red: 0.03, green: 0.03, blue: 0.05)], startPoint: .top, endPoint: .bottom))
                .overlay(RadialGradient(colors: [Brand.cyan.opacity(0.30), .clear], center: .topLeading, startRadius: 0, endRadius: t * 0.8))
                .overlay(RadialGradient(colors: [Brand.red.opacity(0.26), .clear], center: .bottomTrailing, startRadius: 0, endRadius: t * 0.8))
                .clipShape(RoundedRectangle(cornerRadius: t * 0.225, style: .continuous))
                .frame(width: t, height: t)
                .shadow(color: .black.opacity(0.35), radius: px * 0.015, y: px * 0.01)
            LogoMark(left: Brand.cyan, right: Brand.red, size: t * 0.78)
                .shadow(color: .black.opacity(0.45), radius: t * 0.03, y: t * 0.02)
                .offset(y: -t * 0.01)
        }
        .frame(width: px, height: px)
    }
}

@MainActor func draw(_ px: Int) -> Data {
    let r = ImageRenderer(content: Icon(px: CGFloat(px))); r.scale = 1
    return NSBitmapImageRep(data: r.nsImage!.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    for base in [16, 32, 128, 256, 512] {
        try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
        try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
}
