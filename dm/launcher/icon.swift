// Cartridge's app icon, drawn here (scripts/build_launcher.py runs it): a deep indigo tile with a bold game cartridge on it, tilted, in a red-to-orange gradient, with a
// white label carrying a play mark, grip ridges at its top, and a soft glow behind it. Usage: swift icon.swift <out.iconset>
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
    let rgb = { (r: CGFloat, g: CGFloat, b: CGFloat) in NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    // the tile: deep indigo, lighter towards the top
    NSGradient(colors: [rgb(0.10, 0.06, 0.22), rgb(0.24, 0.12, 0.46)])!.draw(in: tile, angle: 90)
    let u = tile.width, cx = tile.midX, cy = tile.midY
    // a warm glow behind the cartridge
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(1.0, 0.36, 0.30).withAlphaComponent(0.5).cgColor,
                          rgb(1.0, 0.36, 0.30).withAlphaComponent(0.18).cgColor, rgb(1.0, 0.36, 0.30).withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: u * 0.62, options: [])

    // the cartridge, drawn upright about the tile's centre, then turned 12° to the left
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy); ctx.rotate(by: 12 * .pi / 180)
    let w = u * 0.56, h = u * 0.66, r = u * 0.06, notch = u * 0.12
    let x0 = -w / 2, x1 = w / 2, y0 = -h / 2, y1 = h / 2
    let card = NSBezierPath()
    card.move(to: CGPoint(x: x0 + r, y: y0))
    card.line(to: CGPoint(x: x1 - r, y: y0)); card.curve(to: CGPoint(x: x1, y: y0 + r), controlPoint1: CGPoint(x: x1, y: y0), controlPoint2: CGPoint(x: x1, y: y0))
    card.line(to: CGPoint(x: x1, y: y1 - notch)); card.line(to: CGPoint(x: x1 - notch, y: y1))
    card.line(to: CGPoint(x: x0 + r, y: y1)); card.curve(to: CGPoint(x: x0, y: y1 - r), controlPoint1: CGPoint(x: x0, y: y1), controlPoint2: CGPoint(x: x0, y: y1))
    card.line(to: CGPoint(x: x0, y: y0 + r)); card.curve(to: CGPoint(x: x0 + r, y: y0), controlPoint1: CGPoint(x: x0, y: y0), controlPoint2: CGPoint(x: x0, y: y0))
    card.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.03), blur: u * 0.08, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    rgb(1, 1, 1).setFill(); card.fill()
    ctx.restoreGState()
    NSGradient(colors: [rgb(1.0, 0.56, 0.20), rgb(1.0, 0.22, 0.36), rgb(0.86, 0.12, 0.42)])!.draw(in: card, angle: -90)
    // a highlight along the left edge, and a thin darker rim
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!.draw(in: CGRect(x: x0, y: y0, width: w * 0.22, height: h), angle: 0)
    card.lineWidth = u * 0.008; NSColor.black.withAlphaComponent(0.18).setStroke(); card.stroke()

    // grip ridges across the top
    NSColor.black.withAlphaComponent(0.22).setFill()
    for i in 0..<3 {
        let gy = y1 - notch * 0.42 - CGFloat(i) * u * 0.032
        NSBezierPath(roundedRect: CGRect(x: x0 + w * 0.1, y: gy, width: w * 0.55, height: u * 0.013), xRadius: u * 0.006, yRadius: u * 0.006).fill()
    }
    // the label: white, with a bold play mark in the cartridge's red
    let lw = w * 0.76, lh = h * 0.46, lx = -lw / 2, ly = y0 + h * 0.13
    let label = NSBezierPath(roundedRect: CGRect(x: lx, y: ly, width: lw, height: lh), xRadius: u * 0.04, yRadius: u * 0.04)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.006), blur: u * 0.012, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    rgb(1, 0.98, 0.96).setFill(); label.fill()
    ctx.restoreGState()
    let pc = CGPoint(x: lx + lw / 2 + lw * 0.04, y: ly + lh / 2), ps = lh * 0.5
    let play = NSBezierPath()
    play.move(to: CGPoint(x: pc.x - ps * 0.45, y: pc.y + ps / 2)); play.line(to: CGPoint(x: pc.x + ps * 0.5, y: pc.y)); play.line(to: CGPoint(x: pc.x - ps * 0.45, y: pc.y - ps / 2)); play.close()
    play.lineJoinStyle = .round; play.lineWidth = ps * 0.22
    rgb(0.96, 0.20, 0.36).setFill(); rgb(0.96, 0.20, 0.36).setStroke(); play.fill(); play.stroke()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
