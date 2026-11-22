// Cartridge's logo and colours, in one place for the app, its widget (dm/launcher/widget) and its icon (icon.swift, which build_launcher.py runs with this
// file before it): a classic cartridge with a ribbed, stepped top and a controller on its label.
import SwiftUI
import AppKit

/// The icon's colours (icon.swift: cyan, red, and the tile's lift over black)
enum Brand {
    static let cyan = Color(.sRGB, red: 0.05, green: 0.82, blue: 1.0)
    static let red = Color(.sRGB, red: 1.0, green: 0.18, blue: 0.30)
    static let ink = Color(.sRGB, red: 0.045, green: 0.04, blue: 0.07)
    static let lift = Color(.sRGB, red: 0.16, green: 0.14, blue: 0.22)
    static let paper = Color(.sRGB, red: 0.965, green: 0.965, blue: 0.98)
    /// The icon's split: cyan to the middle, red after it
    static let split = Gradient(stops: [.init(color: cyan, location: 0), .init(color: cyan, location: 0.47), .init(color: red, location: 0.53), .init(color: red, location: 1)])
}

/// Cartridge's logo: a classic cartridge with a ribbed, stepped top and a label with a controller on it. The shell takes `left` (a lighter top and a darker
/// edge from it, for depth), the label `right`, so the logo follows each page's colours (Covers.pair; the icon's cyan and red by default)
struct LogoMark: View {
    let left: Color
    let right: Color
    var size: CGFloat = 52
    var body: some View {
        let shell = left, light = left.mix(with: .white, by: 0.28), dark = left.mix(with: .black, by: 0.32)
        let label = right, labelLight = right.mix(with: .white, by: 0.35), labelDark = right.mix(with: .black, by: 0.3)
        let s = size, w = s * 0.9, h = s * 0.66, x = (s - w) / 2, y = (s - h) / 2 + s * 0.04
        let lw = w * 0.8, lh = h * 0.56, lx = x + w * 0.1, ly = y + h * 0.34, m = min(lw, lh)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: s * 0.04, style: .continuous).fill(dark).frame(width: w, height: h).offset(x: x, y: y + s * 0.03)   // the edge
            RoundedRectangle(cornerRadius: s * 0.04, style: .continuous).fill(shell).frame(width: w, height: h).offset(x: x, y: y)
            RoundedRectangle(cornerRadius: s * 0.03, style: .continuous).fill(light).frame(width: w * 0.88, height: h * 0.36).offset(x: x + w * 0.06, y: y - h * 0.1)   // the stepped top
            ForEach(0..<6, id: \.self) { i in   // its ribs
                Rectangle().fill(dark.opacity(0.5)).frame(width: w * 0.8, height: h * 0.025).offset(x: x + w * 0.1, y: y - h * 0.05 + h * 0.045 * Double(i))
            }
            ZStack(alignment: .topLeading) {   // the label: a lighter stripe over a darker rule, and the controller
                RoundedRectangle(cornerRadius: m * 0.08, style: .continuous).fill(label)
                Rectangle().fill(labelLight).frame(width: lw, height: lh * 0.16)
                Rectangle().fill(labelDark).frame(width: lw, height: lh * 0.05).offset(y: lh * 0.16)
                ZStack {
                    Rectangle().frame(width: m * 0.30, height: m * 0.10)
                    Rectangle().frame(width: m * 0.10, height: m * 0.30)
                }.position(x: lw * 0.3, y: lh * 0.6)
                Circle().frame(width: m * 0.12, height: m * 0.12).position(x: lw * 0.66, y: lh * 0.66)
                Circle().frame(width: m * 0.12, height: m * 0.12).position(x: lw * 0.8, y: lh * 0.54)
            }
            .foregroundStyle(.white.opacity(0.95))
            .frame(width: lw, height: lh)
            .clipShape(RoundedRectangle(cornerRadius: m * 0.08, style: .continuous))
            .offset(x: lx, y: ly)
        }
        .frame(width: s, height: s, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.5), value: "\(left)\(right)")
        .accessibilityHidden(true)
    }
}

/// The logo for the menu bar, in one colour as macOS draws its menu bar icons (a template image it tints): the cartridge's silhouette with its stepped top,
/// three ribs and the label window cut out, the controller inside the window
struct LogoGlyph: View {
    var size: CGFloat = 18
    var body: some View {
        let s = size, w = s * 0.94, h = s * 0.62, x = (s - w) / 2, y = s * 0.3
        let lw = w * 0.78, lh = h * 0.6, lx = x + w * 0.11, ly = y + h * 0.26, m = min(lw, lh)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: s * 0.08, style: .continuous).frame(width: w, height: h).offset(x: x, y: y)
            RoundedRectangle(cornerRadius: s * 0.06, style: .continuous).frame(width: w * 0.86, height: s * 0.3).offset(x: x + w * 0.07, y: s * 0.08)
            ForEach(0..<2, id: \.self) { i in   // ribs, cut out
                Rectangle().frame(width: w * 0.66, height: s * 0.05).offset(x: x + w * 0.17, y: s * (0.15 + 0.09 * Double(i))).blendMode(.destinationOut)
            }
            RoundedRectangle(cornerRadius: s * 0.05, style: .continuous).frame(width: lw, height: lh).offset(x: lx, y: ly).blendMode(.destinationOut)   // the window
            ZStack {   // the controller
                Rectangle().frame(width: m * 0.42, height: m * 0.16)
                Rectangle().frame(width: m * 0.16, height: m * 0.42)
            }.position(x: lx + lw * 0.3, y: ly + lh * 0.52)
            Circle().frame(width: m * 0.2, height: m * 0.2).position(x: lx + lw * 0.66, y: ly + lh * 0.62)
            Circle().frame(width: m * 0.2, height: m * 0.2).position(x: lx + lw * 0.82, y: ly + lh * 0.4)
        }
        .foregroundStyle(.black)
        .frame(width: s, height: s, alignment: .topLeading)
        .compositingGroup()
    }
}

@MainActor enum LogoTemplate {
    static let image: NSImage = {
        let r = ImageRenderer(content: LogoGlyph(size: 18)); r.scale = 2
        let img = r.nsImage ?? NSImage(); img.isTemplate = true; return img
    }()
}
