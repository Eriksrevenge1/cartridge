// nxnative Launcher's app icon, drawn here (scripts/build_launcher.py runs it): a rounded square in a red-to-violet gradient with a white game controller, its D-pad and
// four face buttons cut out. Usage: swift icon.swift <out.iconset>
import AppKit

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // the tile: macOS's icon grid leaves about 10 % around the rounded square
    let inset = s * 0.1, tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); tilePath.fill()
    ctx.restoreGState()
    tilePath.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.96, green: 0.26, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.45, green: 0.20, blue: 0.85, alpha: 1)])!.draw(in: tile, angle: -60)
    // a soft light from the top
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!.draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)

    // the controller: a wide body with two grips, in tile units
    let u = tile.width, cx = tile.midX, cy = tile.midY - u * 0.02
    let body = NSBezierPath()
    let w = u * 0.62, h = u * 0.30, gripW = u * 0.17, gripH = u * 0.22
    body.append(NSBezierPath(roundedRect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), xRadius: h * 0.5, yRadius: h * 0.5))
    for side in [-1.0, 1.0] {
        let gx = cx + CGFloat(side) * (w / 2 - gripW * 0.55)
        let grip = NSBezierPath(roundedRect: CGRect(x: gx - gripW / 2, y: cy - h / 2 - gripH * 0.55, width: gripW, height: gripH + h * 0.3), xRadius: gripW / 2, yRadius: gripW / 2)
        body.append(grip)
    }
    body.windingRule = .nonZero
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.015), blur: u * 0.04, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.setFill(); body.fill()
    ctx.restoreGState()

    // the D-pad and the face buttons, cut in the gradient's darker colour
    let cut = NSColor(srgbRed: 0.42, green: 0.20, blue: 0.70, alpha: 1)
    cut.setFill()
    let dx = cx - w * 0.27, arm = u * 0.115, thick = u * 0.04
    NSBezierPath(roundedRect: CGRect(x: dx - arm / 2, y: cy - thick / 2, width: arm, height: thick), xRadius: thick * 0.25, yRadius: thick * 0.25).fill()
    NSBezierPath(roundedRect: CGRect(x: dx - thick / 2, y: cy - arm / 2, width: thick, height: arm), xRadius: thick * 0.25, yRadius: thick * 0.25).fill()
    let bx = cx + w * 0.27, r = u * 0.026, d = u * 0.042
    for (ox, oy) in [(0.0, 1.0), (1.0, 0.0), (0.0, -1.0), (-1.0, 0.0)] {
        NSBezierPath(ovalIn: CGRect(x: bx + CGFloat(ox) * d - r, y: cy + CGFloat(oy) * d - r, width: 2 * r, height: 2 * r)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
