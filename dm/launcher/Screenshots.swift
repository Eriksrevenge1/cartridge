// A game's screenshots: the PNGs the game saves at its own resolution when the player presses Capture (or Share) on a controller or ⌘⇧S in the game (dm/host/front_mac.m
// shot_take), in <Application Support>/nxnative/<title ID>/Screenshots/. The game page's Screenshots tab shows them newest first; any one can become the game's cover.
import AppKit
import SwiftUI

extension Game {
    var screenshotsFolder: URL { support.appendingPathComponent("Screenshots") }
    /// The game's screenshots, newest first
    func screenshots() -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(at: screenshotsFolder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast }
        return names.filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }.sorted { date($0) > date($1) }
    }
}

/// Small pictures for the grid, made off the main thread and kept while Cartridge runs
final class Thumbs {
    static let shared = Thumbs()
    private let cache = NSCache<NSURL, NSImage>()
    func image(_ u: URL, size: CGFloat) async -> NSImage? {
        if let i = cache.object(forKey: u as NSURL) { return i }
        let img: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size * 2,
                                                                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
        if let img { cache.setObject(img, forKey: u as NSURL) }
        return img
    }
}

struct ScreenshotsView: View {
    let game: Game
    @State private var shots: [URL] = []
    var body: some View {
        ScrollView {
            if shots.isEmpty {
                ContentUnavailableView {
                    Label("No screenshots yet", systemImage: "camera")
                } description: {
                    Text("In the game, press Capture (Share) on a controller or ⌘⇧S. Screenshots are saved at the game's own resolution and appear here; any one can become the cover.")
                }
                .padding(.top, 60)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                ForEach(shots, id: \.self) { u in
                    ShotTile(url: u)
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(u) }
                        .contextMenu {
                            Button("Use as Cover") { Covers.shared.setCustom(game, from: u) }
                            Button("Open") { NSWorkspace.shared.open(u) }
                            Button("Copy") { if let i = NSImage(contentsOf: u) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([i]) } }
                            ShareLink(item: u)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                            Divider()
                            Button("Move to Trash") { NSWorkspace.shared.recycle([u]) { _, _ in DispatchQueue.main.async(execute: reload) } }
                        }
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(shots.isEmpty ? "" : "\(shots.count) screenshot\(shots.count == 1 ? "" : "s") · right-click one to make it the cover").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: game.screenshotsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(game.screenshotsFolder)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
        }
        .onAppear(perform: reload)
        .onChange(of: game) { reload() }
        // a screenshot taken while the page is open shows up when Cartridge comes back to the front
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }
    private func reload() { shots = game.screenshots() }
}

private struct ShotTile: View {
    let url: URL
    @State private var img: NSImage?
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.black.aspectRatio(16 / 9, contentMode: .fit)
                .overlay { if let img { Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit) } else { ProgressView().controlSize(.small) } }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(hover ? 0.35 : 0.15), radius: hover ? 12 : 5, y: hover ? 6 : 2)
                .scaleEffect(hover ? 1.02 : 1)
            Text(url.deletingPathExtension().lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .task(id: url) { img = await Thumbs.shared.image(url, size: 480) }
    }
}
