// Cartridge's app icon, drawn here (scripts/build_launcher.py runs it): a rounded square in a red-to-violet gradient with a white game cartridge on it, its label cut out
// with a play mark, and its contacts along the bottom. Usage: swift icon.swift <out.iconset>
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

    // the cartridge: a white card, a little taller than wide, its top-right corner cut off (the way one goes in), in tile units
    let u = tile.width, cx = tile.midX, cy = tile.midY
    let w = u * 0.52, h = u * 0.62, r = u * 0.05, notch = u * 0.11
    let x0 = cx - w / 2, x1 = cx + w / 2, y0 = cy - h / 2, y1 = cy + h / 2
    let card = NSBezierPath()
    card.move(to: CGPoint(x: x0 + r, y: y0))
    card.line(to: CGPoint(x: x1 - r, y: y0)); card.curve(to: CGPoint(x: x1, y: y0 + r), controlPoint1: CGPoint(x: x1, y: y0), controlPoint2: CGPoint(x: x1, y: y0))
    card.line(to: CGPoint(x: x1, y: y1 - notch))
    card.line(to: CGPoint(x: x1 - notch, y: y1))
    card.line(to: CGPoint(x: x0 + r, y: y1)); card.curve(to: CGPoint(x: x0, y: y1 - r), controlPoint1: CGPoint(x: x0, y: y1), controlPoint2: CGPoint(x: x0, y: y1))
    card.line(to: CGPoint(x: x0, y: y0 + r)); card.curve(to: CGPoint(x: x0 + r, y: y0), controlPoint1: CGPoint(x: x0, y: y0), controlPoint2: CGPoint(x: x0, y: y0))
    card.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.02), blur: u * 0.05, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.white.setFill(); card.fill()
    ctx.restoreGState()

    // the label: a rounded window in the upper part, in the gradient's colours, with a white play mark
    let lw = w * 0.78, lh = h * 0.52, lx = cx - lw / 2, ly = y1 - notch * 0.55 - lh
    let label = NSBezierPath(roundedRect: CGRect(x: lx, y: ly, width: lw, height: lh), xRadius: u * 0.035, yRadius: u * 0.035)
    NSGradient(colors: [NSColor(srgbRed: 0.93, green: 0.29, blue: 0.36, alpha: 1), NSColor(srgbRed: 0.50, green: 0.23, blue: 0.86, alpha: 1)])!.draw(in: label, angle: -60)
    let pc = CGPoint(x: lx + lw / 2 + lw * 0.03, y: ly + lh / 2), ps = lh * 0.42
    let play = NSBezierPath()
    play.move(to: CGPoint(x: pc.x - ps * 0.42, y: pc.y + ps / 2)); play.line(to: CGPoint(x: pc.x + ps * 0.5, y: pc.y)); play.line(to: CGPoint(x: pc.x - ps * 0.42, y: pc.y - ps / 2)); play.close()
    play.lineJoinStyle = .round; play.lineWidth = ps * 0.18
    NSColor.white.setFill(); NSColor.white.setStroke(); play.fill(); play.stroke()

    // the contacts: a row of short ridges along the bottom edge
    NSColor(srgbRed: 0.42, green: 0.20, blue: 0.70, alpha: 0.85).setFill()
    let n = 7, cw = w * 0.06, gap = (w * 0.72 - CGFloat(n) * cw) / CGFloat(n - 1), ch = h * 0.12, cx0 = cx - w * 0.36
    for i in 0..<n {
        NSBezierPath(roundedRect: CGRect(x: cx0 + CGFloat(i) * (cw + gap), y: y0 + h * 0.07, width: cw, height: ch), xRadius: cw * 0.4, yRadius: cw * 0.4).fill()
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
