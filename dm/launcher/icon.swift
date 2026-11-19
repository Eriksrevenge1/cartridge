// Cartridge's app icon, drawn here (scripts/build_launcher.py runs it): a glossy black tile, like a console's shell, with a red game card standing on it: its corner cut
// the way it goes in, grip grooves at its top, a dark glossy label, and a thin light along the tile's top edge. Usage: swift icon.swift <out.iconset>
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
    // the tile: near-black, a little lighter at the top, with a sheen across its upper half and a fine light along its top edge
    NSGradient(colors: [rgb(0.03, 0.03, 0.035), rgb(0.13, 0.13, 0.145)])!.draw(in: tile, angle: 90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.07), NSColor.white.withAlphaComponent(0)])!.draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    let u = tile.width, cx = tile.midX, cy = tile.midY - u * 0.01
    // a red glow under the card
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0.95, 0.05, 0.10).withAlphaComponent(0.45).cgColor,
                          rgb(0.95, 0.05, 0.10).withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: cx, y: cy - u * 0.05), startRadius: 0, endCenter: CGPoint(x: cx, y: cy - u * 0.05), endRadius: u * 0.5, options: [])

    // the card: upright, its top-right corner cut off, red with a lighter top and a darker rim
    let w = u * 0.50, h = u * 0.60, r = u * 0.05, notch = u * 0.10
    let x0 = cx - w / 2, x1 = cx + w / 2, y0 = cy - h / 2, y1 = cy + h / 2
    let card = NSBezierPath()
    card.move(to: CGPoint(x: x0 + r, y: y0))
    card.line(to: CGPoint(x: x1 - r, y: y0)); card.curve(to: CGPoint(x: x1, y: y0 + r), controlPoint1: CGPoint(x: x1, y: y0), controlPoint2: CGPoint(x: x1, y: y0))
    card.line(to: CGPoint(x: x1, y: y1 - notch)); card.line(to: CGPoint(x: x1 - notch, y: y1))
    card.line(to: CGPoint(x: x0 + r, y: y1)); card.curve(to: CGPoint(x: x0, y: y1 - r), controlPoint1: CGPoint(x: x0, y: y1), controlPoint2: CGPoint(x: x0, y: y1))
    card.line(to: CGPoint(x: x0, y: y0 + r)); card.curve(to: CGPoint(x: x0 + r, y: y0), controlPoint1: CGPoint(x: x0, y: y0), controlPoint2: CGPoint(x: x0, y: y0))
    card.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.025), blur: u * 0.06, color: NSColor.black.withAlphaComponent(0.7).cgColor)
    rgb(0.85, 0.04, 0.09).setFill(); card.fill()
    ctx.restoreGState()
    NSGradient(colors: [rgb(1.0, 0.22, 0.24), rgb(0.86, 0.03, 0.10), rgb(0.62, 0.02, 0.07)])!.draw(in: card, angle: -90)
    card.lineWidth = u * 0.008; NSColor.black.withAlphaComponent(0.28).setStroke(); card.stroke()
    // a bright edge along the card's left side and top
    ctx.saveGState(); card.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0)])!.draw(in: CGRect(x: x0, y: y0, width: w * 0.12, height: h), angle: 0)
    ctx.restoreGState()

    // grip grooves across the top
    for i in 0..<4 {
        let gy = y1 - notch * 0.55 - CGFloat(i) * u * 0.026, gx = x0 + w * 0.12, gw = w * 0.56, gh = u * 0.010
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: CGRect(x: gx, y: gy, width: gw, height: gh), xRadius: gh / 2, yRadius: gh / 2).fill()
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: CGRect(x: gx, y: gy - gh * 0.6, width: gw, height: gh * 0.5), xRadius: gh / 4, yRadius: gh / 4).fill()
    }
    // the label: a dark glossy panel set into the card, with a soft reflection across its top
    let lw = w * 0.80, lh = h * 0.50, lx = cx - lw / 2, ly = y0 + h * 0.10
    let label = NSBezierPath(roundedRect: CGRect(x: lx, y: ly, width: lw, height: lh), xRadius: u * 0.03, yRadius: u * 0.03)
    NSGradient(colors: [rgb(0.05, 0.05, 0.06), rgb(0.17, 0.17, 0.19)])!.draw(in: label, angle: 90)
    ctx.saveGState(); label.addClip()
    let shine = NSBezierPath(); shine.move(to: CGPoint(x: lx, y: ly + lh)); shine.line(to: CGPoint(x: lx + lw * 0.62, y: ly + lh))
    shine.line(to: CGPoint(x: lx + lw * 0.30, y: ly)); shine.line(to: CGPoint(x: lx, y: ly)); shine.close()
    NSColor.white.withAlphaComponent(0.07).setFill(); shine.fill()
    ctx.restoreGState()
    label.lineWidth = u * 0.006; NSColor.black.withAlphaComponent(0.5).setStroke(); label.stroke()
    // a small light near the label's lower edge, as a card's printed mark would sit
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: CGRect(x: lx + lw * 0.12, y: ly + lh * 0.14, width: lw * 0.30, height: u * 0.014), xRadius: u * 0.007, yRadius: u * 0.007).fill()
    NSColor.white.withAlphaComponent(0.35).setFill()
    NSBezierPath(roundedRect: CGRect(x: lx + lw * 0.12, y: ly + lh * 0.14 + u * 0.026, width: lw * 0.48, height: u * 0.014), xRadius: u * 0.007, yRadius: u * 0.007).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
