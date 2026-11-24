// A game's page: the sheet that rises over its art when you scroll or press down on the home (Shell.swift). Its screenshots (the store's, and for a Switch game the
// ones you took), what it is and the facts, how it runs on this Mac and what Cartridge changes in it (a Switch game only: other launchers' games have no mods or
// cheats here), when you played it, and games like it on your shelf.
import AppKit
import SwiftUI

struct GamePage: View {
    let title: Title
    let play: () -> Void
    let options: () -> Void
    let pages: () -> Void
    @ObservedObject private var details = DetailsStore.shared
    @ObservedObject private var titles = Titles.shared
    @State private var captures: [URL] = []
    @State private var viewing: Int?

    var body: some View {
        let d = details.details(title)
        let shots = (d?.shots ?? []).map { DetailsStore.folder(title).appendingPathComponent($0) }   // files: thumbnails here, full size in the viewer
        VStack(alignment: .leading, spacing: 44) {
            Capsule().fill(.white.opacity(0.35)).frame(width: 60, height: 5).frame(maxWidth: .infinity)
            header(d)
            if !shots.isEmpty { mosaic(shots) }
            story(d)
            yourCaptures
            if let g = title.game { OnThisMac(game: g, pages: pages) }
            activity
            similar(d)
        }
        .padding(.horizontal, 80).padding(.top, 14).padding(.bottom, 120)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 36, topTrailingRadius: 36, style: .continuous)
                .fill(LinearGradient(colors: [Brand.ink.opacity(0.82), Brand.ink.opacity(0.96)], startPoint: .top, endPoint: .bottom))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 36, topTrailingRadius: 36, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Brand.cyan.opacity(0.6), Brand.red.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
        )
        .padding(.horizontal, 32)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .task(id: title.id) { captures = GamePage.captures(of: title) }
        .sheet(item: Binding(get: { viewing.map { ViewerIndex(i: $0) } }, set: { viewing = $0?.i })) { v in
            ShotViewer(images: [], files: v.i >= 1000 ? captures : shots, start: v.i % 1000, close: { viewing = nil }).frame(minWidth: 1100, minHeight: 700)
        }
    }

    /// The screenshots you took, newest first: a Switch game's (Capture, or ⌘⇧S in the game: <Application Support>/nxnative/<title ID>/Screenshots), a Steam
    /// game's (Steam's F12: userdata/<user>/760/remote/<app ID>/screenshots)
    static func captures(of t: Title) -> [URL] {
        if let g = t.game { return g.screenshots() }
        guard let e = t.external, e.store == .steam, e.runtime == nil, let id = e.id.split(separator: ":").last else { return [] }
        let ud = Places.mac.support.appendingPathComponent("Steam/userdata")
        let files = children(ud).flatMap { children($0.appendingPathComponent("760/remote/\(id)/screenshots")) }.filter { ["jpg", "png"].contains($0.pathExtension.lowercased()) }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast }
        return files.sorted { date($0) > date($1) }
    }

    @ViewBuilder private var yourCaptures: some View {
        if !captures.isEmpty || title.game != nil {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionTitle("YOUR CAPTURES")
                    if !captures.isEmpty { Text("\(captures.count)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.5)) }
                    Spacer()
                    if let g = title.game, !captures.isEmpty { Button("Show in Finder") { NSWorkspace.shared.open(g.screenshotsFolder) }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7)) }
                }
                if captures.isEmpty {
                    Text("Press Capture on your controller, or ⌘⇧S, while you play: your screenshots appear here.").font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 14) {
                            ForEach(Array(captures.prefix(24).enumerated()), id: \.offset) { i, u in
                                AsyncThumb(url: u).frame(width: 320, height: 180).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .contentShape(Rectangle()).onTapGesture { viewing = 1000 + i }
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            }
        }
    }

    private func header(_ d: Details?) -> some View {
        HStack(spacing: 20) {
            CoverImage(title: title).frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title.name).font(.custom("Avenir Next", size: 32).weight(.heavy))
                Text([title.platform, d?.maker, d?.released].compactMap { $0 }.joined(separator: "  ·  ")).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if titles.isRunning(title) {
                Button { titles.stop(title) } label: { Label("Stop", systemImage: "stop.fill").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 11).background(Capsule().fill(.white.opacity(0.14))) }.buttonStyle(.plain)
            }
            Button(action: options) { Label("Options", systemImage: "slider.horizontal.3").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 11).background(Capsule().fill(.white.opacity(0.14))) }.buttonStyle(.plain)
            Button(action: play) { Label(titles.isRunning(title) ? "Resume" : "Play", systemImage: "play.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(.black).padding(.horizontal, 26).padding(.vertical, 12).background(Capsule().fill(.white)) }.buttonStyle(.plain)
        }
    }

    /// One large picture and four beside it; the store's first, then yours
    private func mosaic(_ shots: [URL]) -> some View {
        let all: [ShotSource] = shots.map { .file($0) }
        return HStack(spacing: 14) {
            tile(all, 0).aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity)
            if all.count > 1 {
                VStack(spacing: 14) {
                    HStack(spacing: 14) { tile(all, 1); tile(all, 2) }
                    HStack(spacing: 14) {
                        tile(all, 3)
                        tile(all, 4).overlay { if all.count > 5 { Text("+\(all.count - 5)").font(.system(size: 30, weight: .heavy)).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.45)) } }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }.frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: 520)
    }
    private enum ShotSource { case image(NSImage), file(URL) }
    @ViewBuilder private func tile(_ all: [ShotSource], _ i: Int) -> some View {
        Group {
            if i < all.count {
                switch all[i] {
                case .image(let img): Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                case .file(let u): AsyncThumb(url: u)
                }
            } else { Color.white.opacity(0.04) }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if i < all.count { viewing = i } }
    }

    private func story(_ d: Details?) -> some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle("THE GAME")
                Text(d?.about ?? (DetailsStore.online ? "Looking for details…" : "Details are off (Settings › Library & sources)."))
                    .font(.system(size: 20, weight: .medium)).lineSpacing(6).foregroundStyle(.white.opacity(0.9)).frame(maxWidth: 820, alignment: .leading)
                if let g = d?.genres, !g.isEmpty {
                    HStack(spacing: 8) { ForEach(g.prefix(5), id: \.self) { Text($0).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(.white.opacity(0.1))) } }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(facts(d).enumerated()), id: \.offset) { i, f in
                    HStack { Text(f.0.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(2).foregroundStyle(.white.opacity(0.5)); Spacer(); Text(f.1).font(.system(size: 15, weight: .semibold)).lineLimit(1) }
                        .padding(.vertical, 12)
                    if i < facts(d).count - 1 { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
                }
            }
            .padding(20).frame(width: 480)
            .background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.05)))
        }
    }
    private func facts(_ d: Details?) -> [(String, String)] {
        var f: [(String, String)] = []
        if let m = d?.maker { f.append(("Made by", m)) }
        if let r = d?.released { f.append(("Released", r)) }
        if let g = title.game { f.append(("Version", g.version.isEmpty ? g.titleID : "\(g.version) · \(g.titleID)")) }
        if let e = title.external {
            f.append(("From", e.store.rawValue))
            if let b = e.bottle, let r = e.runtime { f.append(("Runs in", "\(r.rawValue) · \(b)")) }
            if let s = e.size, s > 0 { f.append(("Size", ByteCountFormatter.string(fromByteCount: s, countStyle: .file))) }
        }
        if let folder = title.folder { f.append(("Installed in", folder.path.hasPrefix("/Volumes/") ? folder.pathComponents.dropFirst(2).first ?? folder.path : "This Mac")) }
        return f
    }

    /// The last sixteen weeks, a square a day, brighter the longer you played
    private var activity: some View {
        let sessions = Stats.shared.sessions(key: title.statsKey)
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        var perDay: [Date: Double] = [:]
        for s in sessions { perDay[cal.startOfDay(for: s.start), default: 0] += s.seconds }
        // play from before the session log began (Cartridge counted only a total then): on the day it was last played, so the calendar is not empty
        let logged = sessions.reduce(0) { $0 + $1.seconds }
        if title.stats.seconds - logged > 60, let last = title.stats.last { perDay[cal.startOfDay(for: last), default: 0] += title.stats.seconds - logged }
        let most = max(1, perDay.values.max() ?? 1)
        let week = sessions.filter { $0.start > Date().addingTimeInterval(-7 * 86400) }.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 16) {
            SectionTitle("YOUR TIME")
            HStack(alignment: .top, spacing: 40) {
                HStack(alignment: .top, spacing: 5) {
                    ForEach(0..<16, id: \.self) { w in
                        VStack(spacing: 5) {
                            ForEach(0..<7, id: \.self) { d in
                                let day = cal.date(byAdding: .day, value: -((15 - w) * 7 + (6 - d)), to: today)!
                                let v = (perDay[day] ?? 0) / most
                                RoundedRectangle(cornerRadius: 4).fill(v == 0 ? AnyShapeStyle(.white.opacity(0.06)) : AnyShapeStyle(Brand.cyan.mix(with: Brand.red, by: v).opacity(0.4 + 0.6 * v)))
                                    .frame(width: 22, height: 22).help(v == 0 ? day.formatted(date: .abbreviated, time: .omitted) : "\(day.formatted(date: .abbreviated, time: .omitted)): \(Stats.duration(perDay[day]!))")
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 18) {
                    big("THIS WEEK", week > 0 ? Stats.duration(week) : "—")
                    big("LONGEST", sessions.map(\.seconds).max().map(Stats.duration) ?? "—")
                    big("IN TOTAL", title.stats.seconds > 0 ? Stats.duration(title.stats.seconds) : "—")
                }
            }
            .padding(24).background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.05)))
        }
    }
    private func big(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(k).font(.system(size: 10, weight: .heavy)).tracking(2).foregroundStyle(.white.opacity(0.5)); Text(v).font(.system(size: 22, weight: .bold)) }
    }

    /// Games on your shelf that share a genre with this one, else the ones from the same place
    private func similar(_ d: Details?) -> some View {
        let genres = Set(d?.genres ?? [])
        let others = titles.all.filter { $0.id != title.id && !titles.hidden.contains($0.id) }
        let alike = others.filter { !genres.isDisjoint(with: details.details($0)?.genres ?? []) }
        let list = Array((alike.isEmpty ? others.filter { $0.platform == title.platform } : alike).prefix(6))
        return Group {
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle("ALSO ON YOUR SHELF")
                    HStack(spacing: 22) {
                        ForEach(list) { t in
                            VStack(spacing: 8) { CartridgeShape(title: t, width: 96); Text(t.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(width: 110) }
                                .onTapGesture { UserDefaults.standard.set(t.id, forKey: "shell.selected") }
                        }
                    }
                }
            }
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: 12, weight: .heavy)).tracking(3).foregroundStyle(LinearGradient(colors: [Brand.cyan, Brand.red], startPoint: .leading, endPoint: .trailing))
    }
}

/// How a Switch game runs here, and what Cartridge changes in it: the last session's frame rate and picture, HDR, mods and cheats that are on, cloud saves
struct OnThisMac: View {
    let game: Game
    let pages: () -> Void
    @State private var perf: SessionPerf?
    @State private var mods = 0
    @State private var cheats = 0
    @ObservedObject private var hdr = NativeHDRGames.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle("ON THIS MAC")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 220), spacing: 16)], alignment: .leading, spacing: 16) {
                gauge(perf.map { "\(Int((1000 / max($0.frameP95, 1)).rounded()))" } ?? "—", "fps", perf.map { "Last session, \(Int($0.minutes)) min" } ?? "After a session of a few minutes", perf.map { min(1, (1000 / max($0.frameP95, 1)) / Double($0.fpsCap)) } ?? 0)
                gauge(perf?.renderScale.map { "\(Int($0 * 100))%" } ?? "100%", "", perf?.metalFX == true ? "Render scale · MetalFX" : "Render scale", perf?.renderScale ?? 1)
                tile("sun.max.fill", hdr.names?.contains(game.name) == true ? "Native HDR" : "HDR", hdr.names?.contains(game.name) == true ? "The game draws its own" : "Lifted from SDR")
                tile("puzzlepiece.extension.fill", mods == 0 ? "No mods" : "\(mods) \(mods == 1 ? "mod" : "mods")", "On for this game")
                tile("wand.and.stars", cheats == 0 ? "No cheats" : "\(cheats) on", "For this build")
                tile("icloud.fill", UserDefaults(suiteName: game.bundleID)?.string(forKey: "cloudSaves.folder") == nil ? "Local saves" : "Cloud saves", "Back up any time")
            }
            Button(action: pages) { Label("Settings, mods, cheats, controls and saves", systemImage: "slider.horizontal.3").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 11).background(Capsule().fill(.white.opacity(0.14))) }.buttonStyle(.plain)
        }
        .task(id: game.id) {
            let g = game
            perf = await Task.detached(priority: .utility) { SessionPerf.read(g) }.value
            mods = ModsModel(game: g).mods.filter(\.on).count
            cheats = CheatsModel(game: g).cheats.filter(\.on).count
            if hdr.names == nil { hdr.refresh() }
        }
    }
    private func gauge(_ big: String, _ unit: String, _ note: String, _ v: Double) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 11)
                Circle().trim(from: 0, to: v).stroke(LinearGradient(colors: [Brand.cyan, Brand.red], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 11, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 0) { Text(big).font(.system(size: big.count > 3 ? 22 : 30, weight: .heavy)); if !unit.isEmpty { Text(unit).font(.system(size: 12, weight: .bold)).opacity(0.6) } }
            }.frame(width: 110, height: 110)
            Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
        }
        .padding(16).frame(width: 190, height: 200).background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.05)))
    }
    private func tile(_ sym: String, _ big: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: sym).font(.system(size: 24)).foregroundStyle(LinearGradient(colors: [Brand.cyan, Brand.red], startPoint: .topLeading, endPoint: .bottomTrailing))
            Spacer()
            Text(big).font(.system(size: 22, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(18).frame(width: 190, height: 200, alignment: .leading).background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.05)))
    }
}

struct AsyncThumb: View {
    let url: URL
    @State private var img: NSImage?
    var body: some View {
        Group { if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) } else { Color.white.opacity(0.05) } }
            .task(id: url) { img = await Thumbs.shared.image(url, size: 640) }
    }
}

struct ViewerIndex: Identifiable { let i: Int; var id: Int { i } }

/// The screenshots full size: left and right (or the arrow keys) go through them, Escape closes
struct ShotViewer: View {
    let images: [NSImage]
    let files: [URL]
    let start: Int
    let close: () -> Void
    @State private var i = 0
    @State private var file: NSImage?
    private var count: Int { images.count + files.count }
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            Group {
                if i < images.count { Image(nsImage: images[i]).resizable().aspectRatio(contentMode: .fit) }
                else if let file { Image(nsImage: file).resizable().aspectRatio(contentMode: .fit) }
            }
            HStack {
                Text("\(i + 1) of \(count)").font(.headline).foregroundStyle(.white)
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
                Button { step(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(20).background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
        .onAppear { i = min(start, max(0, count - 1)) }
        .task(id: i) { file = i >= images.count && i - images.count < files.count ? NSImage(contentsOf: files[i - images.count]) : nil }
    }
    private func step(_ d: Int) { guard count > 0 else { return }; i = (i + d + count) % count; UISound.move.play() }
}
