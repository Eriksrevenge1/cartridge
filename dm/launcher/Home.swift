import SwiftUI
import AppKit

// The library's home page: the icon's near-black lit by the two colours of the game played last (Covers.pair; the icon's cyan | red for grey art), the logo
// and wordmark split in the same two as the icon's cartridge is; the game played last as a banner over the grid. The backdrop moves only while Cartridge is the active app and
// no game runs, so it never takes GPU time from a game.

/// Cartridge's colours as a slowly drifting light: a cyan glow and a red one over the icon's near-black (a pale paper in light mode),
/// a faint blur of the last-played game's art, grain and a vignette
struct HomeBackdrop: View {
    let hero: Game?
    let moving: Bool
    var left: Color = Brand.cyan
    var right: Color = Brand.red
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving || reduceMotion)) { tl in
                mesh(t: tl.date.timeIntervalSinceReferenceDate)
            }
            if let hero {
                Color.clear.overlay(CoverArt(game: hero))   // the art fills the page's frame, never sizes it
                    .blur(radius: 90).saturation(0.6)
                    .opacity(scheme == .dark ? 0.14 : 0.10)
                    .clipped()
            }
            Grain().opacity(scheme == .dark ? 0.06 : 0.04).blendMode(.overlay)
            RadialGradient(colors: [.clear, .black.opacity(scheme == .dark ? 0.45 : 0.06)], center: .center, startRadius: 250, endRadius: 1200)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func mesh(t: Double) -> some View {
        let s = Float(t * 0.1)   // one slow cycle in about a minute
        func w(_ a: Float, _ k: Float, _ r: Float = 0.2) -> Float { 0.5 + r * sin(s * k + a) }
        let dark = scheme == .dark
        let base = dark ? Brand.ink : Brand.paper
        let mid = dark ? Brand.lift : Color.white
        let cyan = dark ? left.mix(with: Brand.ink, by: 0.45) : left.mix(with: .white, by: 0.72)
        let red = dark ? right.mix(with: Brand.ink, by: 0.5) : right.mix(with: .white, by: 0.78)
        return MeshGradient(width: 3, height: 3, points: [
            [0, 0], [w(0, 1), 0], [1, 0],
            [0, w(1, 0.8)], [w(2, 1.1, 0.25), w(3, 0.9, 0.25)], [1, w(4, 0.7)],
            [0, 1], [w(5, 1.2), 1], [1, 1],
        ], colors: [
            cyan, base, base,
            base, mid, base,
            base, base, red,
        ], smoothsColors: true)
    }
}

/// Static film grain: one noise tile drawn once
private struct Grain: View {
    private static let tile: NSImage = {
        let n = 160
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false,
                                   isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: n, bitsPerPixel: 8)!
        var g = SystemRandomNumberGenerator()
        if let d = rep.bitmapData { for i in 0..<(n * n) { d[i] = UInt8.random(in: 0...255, using: &g) } }
        let img = NSImage(size: NSSize(width: n, height: n)); img.addRepresentation(rep); return img
    }()
    var body: some View { Rectangle().fill(.image(Image(nsImage: Self.tile), scale: 1)) }
}

/// The logo and "cartridge" beside it, heavy and plain, so the logo carries the page's colours
struct Wordmark: View {
    var left: Color = Brand.cyan
    var right: Color = Brand.red
    var size: CGFloat = 34
    var body: some View {
        HStack(spacing: size * 0.35) {
            LogoMark(left: left, right: right, size: size * 1.9)
            Text("cartridge").font(.custom("Avenir Next", size: size * 1.15).weight(.heavy)).tracking(-size * 0.015).foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Cartridge")
    }
}

/// The game played last, large: its art, how long it has been played, and Continue
struct HeroBanner: View {
    let game: Game
    let playing: Bool
    var open: () -> Void
    var play: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 28) {
            Color.clear.aspectRatio(1, contentMode: .fit).frame(width: 190)
                .overlay(CoverArt(game: game).scaleEffect(hover ? 1.06 : 1))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
            VStack(alignment: .leading, spacing: 10) {
                Text(playing ? "NOW PLAYING" : "CONTINUE PLAYING").font(.caption.weight(.heavy)).tracking(2).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(game.title).font(.system(size: 30, weight: .bold, design: .rounded)).lineLimit(2)
                    if game.isSwitch2 { Switch2Badge() }
                }
                if let s = Stats.describe(Stats.shared.of(game)) { Text(s).font(.callout).foregroundStyle(.secondary) }
                HStack(spacing: 10) {
                    Button(action: play) {
                        Label(playing ? "Playing" : "Play", systemImage: playing ? "gamecontroller.fill" : "play.fill")
                            .font(.title3.bold()).padding(.horizontal, 22).padding(.vertical, 9)
                    }
                    .buttonStyle(.plain).foregroundStyle(.black).background(.white, in: Capsule())
                    .shadow(color: .white.opacity(hover ? 0.5 : 0.2), radius: hover ? 16 : 8)
                    Button("Game Page", action: open).buttonStyle(.plain).font(.callout.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9).background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .background {
            ZStack {
                Color.clear.overlay(CoverArt(game: game)).blur(radius: 40).opacity(0.35).clipped()
                Rectangle().fill(.ultraThinMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(LinearGradient(gradient: Brand.split, startPoint: .leading, endPoint: .trailing).opacity(hover ? 0.7 : 0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 14)
        .onHover { h in withAnimation(.easeOut(duration: 0.6)) { hover = h } }
        .onTapGesture(count: 2, perform: play)
    }
}
