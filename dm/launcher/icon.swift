// Cartridge's app icon, drawn here (scripts/build_launcher.py runs it): a black glass tile with a game card's outline in neon, cyan on its left half and red on its
// right like a console's two controllers, a row of glowing contacts along the card's bottom, and the glow's reflection on the tile. Usage: swift icon.swift <out.iconset>
import AppKit
import CoreImage

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
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let u = tile.width, cx = tile.midX, cy = tile.midY + u * 0.03
    let cyan = rgb(0.05, 0.82, 1.0), red = rgb(1.0, 0.18, 0.30)

    // the tile: black glass, a faint lift in the middle, darker at the edges, a sheen across the top
    NSGradient(colors: [rgb(0.015, 0.015, 0.025), rgb(0.06, 0.06, 0.08)])!.draw(in: tile, angle: 90)
    let lift = CGGradient(colorsSpace: space, colors: [rgb(0.16, 0.14, 0.22).withAlphaComponent(0.55).cgColor, rgb(0, 0, 0).withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(lift, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: u * 0.62, options: [])

    // the card: upright, its top-right corner cut off
    let w = u * 0.46, h = u * 0.56, r = u * 0.06, notch = u * 0.11
    let x0 = cx - w / 2, x1 = cx + w / 2, y0 = cy - h / 2, y1 = cy + h / 2
    let card = NSBezierPath()
    card.move(to: CGPoint(x: x0 + r, y: y0))
    card.line(to: CGPoint(x: x1 - r, y: y0)); card.curve(to: CGPoint(x: x1, y: y0 + r), controlPoint1: CGPoint(x: x1, y: y0), controlPoint2: CGPoint(x: x1, y: y0))
    card.line(to: CGPoint(x: x1, y: y1 - notch)); card.line(to: CGPoint(x: x1 - notch, y: y1))
    card.line(to: CGPoint(x: x0 + r, y: y1)); card.curve(to: CGPoint(x: x0, y: y1 - r), controlPoint1: CGPoint(x: x0, y: y1), controlPoint2: CGPoint(x: x0, y: y1))
    card.line(to: CGPoint(x: x0, y: y0 + r)); card.curve(to: CGPoint(x: x0 + r, y: y0), controlPoint1: CGPoint(x: x0, y: y0), controlPoint2: CGPoint(x: x0, y: y0))
    card.close()
    card.lineJoinStyle = .round; card.lineCapStyle = .round

    // inside the card: a very dark tint, so the neon frames something
    NSGradient(colors: [rgb(0.06, 0.07, 0.10).withAlphaComponent(0.9), rgb(0.02, 0.02, 0.03).withAlphaComponent(0.9)])!.draw(in: card, angle: -90)

    // the contacts: short pins along the bottom, in the same split colours
    let pins = NSBezierPath(), n = 6, pw = w * 0.055, ph = h * 0.13, span = w * 0.62, gap = (span - CGFloat(n) * pw) / CGFloat(n - 1)
    for i in 0..<n { pins.append(NSBezierPath(roundedRect: CGRect(x: cx - span / 2 + CGFloat(i) * (pw + gap), y: y0 + h * 0.10, width: pw, height: ph), xRadius: pw / 2, yRadius: pw / 2)) }

    // neon: the tube and the pins drawn once, coloured cyan on the left and red on the right with a short blend between, into an image of their own; then that image
    // blurred at three sizes and added on (bloom), the sharp tube on top with a white-hot core, and the whole once more mirrored below as a faint reflection
    let px = Int(s), bounds = CGRect(x: 0, y: 0, width: s, height: s)
    func layer(_ draw: (CGContext) -> Void) -> CGImage {
        let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        draw(c); NSGraphicsContext.restoreGraphicsState(); return c.makeImage()!
    }
    let split = CGGradient(colorsSpace: space, colors: [cyan.cgColor, cyan.cgColor, red.cgColor, red.cgColor] as CFArray, locations: [0, 0.47, 0.53, 1])!
    let tube = layer { c in
        card.lineWidth = u * 0.028
        let outline = NSBezierPath(); outline.append(card)
        c.saveGState()
        c.addPath(card.cgPath); c.setLineWidth(u * 0.028); c.setLineJoin(.round); c.replacePathWithStrokedPath()
        c.addPath(pins.cgPath); c.clip()
        c.drawLinearGradient(split, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }
    let core = layer { c in
        c.addPath(card.cgPath); c.setLineWidth(u * 0.006); c.setLineJoin(.round); c.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor); c.strokePath()
        c.addPath(pins.cgPath); c.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor); c.fillPath()
    }
    let ci = CIContext(options: [.workingColorSpace: space])
    func blurred(_ img: CGImage, _ radius: CGFloat) -> CGImage {
        let out = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: Double(radius)).cropped(to: CIImage(cgImage: img).extent)
        return ci.createCGImage(out, from: out.extent)!
    }
    let blooms = [(u * 0.09, 0.75), (u * 0.035, 0.9), (u * 0.012, 1.0)].map { (blurred(tube, $0.0), CGFloat($0.1)) }
    func neon() {
        ctx.saveGState(); ctx.setBlendMode(.screen)
        for (img, a) in blooms { ctx.setAlpha(a); ctx.draw(img, in: bounds) }
        ctx.setAlpha(1); ctx.draw(tube, in: bounds)
        ctx.setBlendMode(.normal); ctx.draw(core, in: bounds)
        ctx.restoreGState()
    }
    // the reflection: mirrored about the card's bottom edge (a little below it), faint, only below the card
    ctx.saveGState()
    ctx.clip(to: CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: y0 - u * 0.02 - tile.minY))
    ctx.translateBy(x: 0, y: 2 * (y0 - u * 0.02)); ctx.scaleBy(x: 1, y: -1); ctx.setAlpha(0.14)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil); neon(); ctx.endTransparencyLayer()
    ctx.restoreGState()
    neon()

    // glass: a soft sheen over the top of the tile
    let sheen = NSBezierPath(roundedRect: CGRect(x: tile.minX, y: tile.midY + u * 0.08, width: tile.width, height: tile.height / 2), xRadius: 0, yRadius: 0)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.06), NSColor.white.withAlphaComponent(0)])!.draw(in: sheen, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
