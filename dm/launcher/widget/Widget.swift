// Cartridge's widget (scripts/build_launcher.py builds it into Contents/PlugIns/CartridgeWidget.appex): the game played last, or the last four, from what Cartridge wrote
// for it (RecentFile in dm/launcher/Recent.swift: <Application Support>/nxnative/cartridge/recent.json and a cover thumbnail per game). A widget runs in a sandbox, so
// it reads only that folder (its entitlements' read-only exception). Clicking a game opens cartridge://play?game=<title ID>: Cartridge starts it.
import SwiftUI
import WidgetKit

struct RecentGame: Decodable, Identifiable { let titleID, title: String; let last: Date?; var id: String { titleID } }

enum Shared {
    static var dir: URL {
        // the real home, not the sandbox container's
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/nxnative/cartridge")
    }
    static func games() -> [RecentGame] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("recent.json")) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([RecentGame].self, from: d)) ?? []
    }
    static func cover(_ tid: String) -> NSImage? { NSImage(contentsOf: dir.appendingPathComponent("covers/\(tid).png")) }
}

struct Entry: TimelineEntry { let date: Date; let games: [RecentGame] }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, games: []) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now, games: Shared.games())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // Cartridge asks for a reload when it writes the file; the hourly one keeps "2 hours ago" true
        completion(Timeline(entries: [Entry(date: .now, games: Shared.games())], policy: .after(.now.addingTimeInterval(3600))))
    }
}

func link(_ g: RecentGame) -> URL { URL(string: "cartridge://play?game=\(g.titleID)")! }

struct Cover: View {
    let g: RecentGame
    var body: some View {
        if let i = Shared.cover(g.titleID) { Image(nsImage: i).resizable().aspectRatio(contentMode: .fill) }
        else { Rectangle().fill(.gray.opacity(0.3)).overlay(LogoMark(left: Brand.cyan, right: Brand.red, size: 40)) }
    }
}

struct WidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if entry.games.isEmpty {
            VStack(spacing: 6) { LogoMark(left: Brand.cyan, right: Brand.red, size: 44); Text("Play a game in Cartridge").font(.caption).multilineTextAlignment(.center) }
                .foregroundStyle(.secondary)
        } else if family == .systemSmall, let g = entry.games.first {
            ZStack(alignment: .bottomLeading) {
                Color.clear.overlay(Cover(g: g)).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.title).font(.headline).lineLimit(2)
                    if let l = g.last { Text(l, style: .relative).font(.caption2).opacity(0.8) }
                }
                .foregroundStyle(.white).padding(10)
            }
            .widgetURL(link(g))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Continue Playing").font(.caption.bold()).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(entry.games.prefix(4)) { g in
                        Link(destination: link(g)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Color.clear.aspectRatio(1, contentMode: .fit).overlay(Cover(g: g)).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Text(g.title).font(.caption2).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct CartridgeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "org.nxnative.launcher.recent", provider: Provider()) { e in
            WidgetView(entry: e).containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Last Played")
        .description("The games you played last in Cartridge. Click one to play it.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct CartridgeWidgets: WidgetBundle { var body: some Widget { CartridgeWidget() } }
