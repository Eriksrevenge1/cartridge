// A game's packages in its NSP folder (base game, update, DLC), and adding an update or DLC to it: the packing script reads one folder, so the files the player picks are
// copied into the game's folder (on the same APFS volume a copy is a clone: no space, no time), then the game is built again. A .nup or a dump folder takes no packages.
import AppKit
import SwiftUI

struct Package: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// Base game, Update or DLC, from the title ID in the name ([0100…000] the base game, …800 its update, any other an add-on) or its [UPD] / [DLC] / [Base] tag
    var kind: String {
        let n = name.uppercased()
        if n.contains("[UPD]") { return "Update" }
        if n.contains("[DLC]") { return "DLC" }
        if n.contains("[BASE]") { return "Base game" }
        if let r = n.range(of: #"\[[0-9A-F]{16}\]"#, options: .regularExpression) {
            let tid = n[r].dropFirst().dropLast()
            return tid.hasSuffix("000") ? "Base game" : tid.hasSuffix("800") ? "Update" : "DLC"
        }
        return "Package"
    }
    /// The display version in the name ([v720896] or [2.2.1]), when it carries one
    var version: String? {
        let n = name
        for pat in [#"\[\d+\.\d+(\.\d+)?\]"#, #"\[v\d+\]"#] { if let r = n.range(of: pat, options: .regularExpression) { return String(n[r].dropFirst().dropLast()) } }
        return nil
    }
    var size: Int64 { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0 }
}

enum Packages {
    static let extensions = ["nsp", "nsz", "xci", "xcz"]
    /// The packages in an NSP folder, base game first, then updates, then DLC
    static func list(_ dir: URL) -> [Package] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let order = ["Base game": 0, "Update": 1, "DLC": 2, "Package": 3]
        return names.filter { !$0.hasPrefix("._") && extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { Package(url: dir.appendingPathComponent($0)) }
            .sorted { (order[$0.kind]!, $0.name) < (order[$1.kind]!, $1.name) }
    }
    /// A folder of NSPs can take more (a .nup file or a dump folder cannot)
    static func takes(_ source: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: source.path, isDirectory: &dir) && dir.boolValue && !FileManager.default.fileExists(atPath: source.appendingPathComponent("base").path)
    }
    /// Asks for update and DLC files
    static func pick(for title: String) -> [URL] {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = extensions.compactMap { .init(filenameExtension: $0) }
        p.message = "Choose \(title)'s update or DLC files (NSP, NSZ, XCI or XCZ)"
        return p.runModal() == .OK ? p.urls : []
    }
    /// Copies the files into the folder off the main thread (a file of that name already there is replaced); done gets nil or what failed
    static func add(_ files: [URL], to dir: URL, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default; var err: String?
            for f in files where f.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL {
                let dst = dir.appendingPathComponent(f.lastPathComponent)
                do { if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }; try fm.copyItem(at: f, to: dst) }
                catch { err = "Could not copy \(f.lastPathComponent): \(error.localizedDescription)"; break }
            }
            DispatchQueue.main.async { done(err) }
        }
    }
}

/// The Build Games window's list of the folder's packages, with Add Update or DLC
struct PackagesSection: View {
    let folder: URL
    @State private var items: [Package] = []
    @State private var copying = false
    @State private var error: String?
    var body: some View {
        Section("Base game, updates and DLC") {
            if items.isEmpty { Text("No NSP, NSZ, XCI or XCZ files in this folder.").foregroundStyle(.secondary) }
            ForEach(items) { p in
                HStack {
                    Text(p.kind).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(p.kind == "Base game" ? Color.blue.opacity(0.25) : p.kind == "Update" ? Color.green.opacity(0.25) : Color.orange.opacity(0.25), in: Capsule())
                    Text(p.name).lineLimit(1).truncationMode(.middle).help(p.name)
                    Spacer()
                    if let v = p.version { Text(v).foregroundStyle(.secondary).monospacedDigit() }
                    Text(ByteCountFormatter.string(fromByteCount: p.size, countStyle: .file)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack {
                Button(copying ? "Copying…" : "Add Update or DLC…") {
                    let files = Packages.pick(for: folder.lastPathComponent); guard !files.isEmpty else { return }
                    copying = true; error = nil
                    Packages.add(files, to: folder) { e in copying = false; error = e; reload() }
                }.disabled(copying)
                if copying { ProgressView().controlSize(.small) }
            }
            Text("The files are copied into this folder; the build packs the newest update and every DLC.").font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .onAppear(perform: reload).onChange(of: folder) { reload() }
    }
    private func reload() { items = Packages.list(folder) }
}

/// Add Update or DLC on a game's page: copy the files into its NSP folder, then rebuild it
func updateGame(_ game: Game, builder: Builder, show: @escaping () -> Void) {
    guard let r = builder.rebuildRequest(for: game) else {
        let a = NSAlert(); a.messageText = "\(game.title)'s files were not found"
        a.informativeText = "Use Rebuild once and choose its NSP folder; then updates and DLC can be added here."; a.runModal(); return
    }
    guard Packages.takes(r.source) else {
        let a = NSAlert(); a.messageText = "\(game.title) is built from \(r.source.pathExtension.lowercased() == "nup" ? "a .nup file" : "a dump folder")"
        a.informativeText = r.source.pathExtension.lowercased() == "nup" ? "A newer .nup holds its update: put it beside the app and use Rebuild." : "Put the update in the dump's updates/<version>/ folder and use Rebuild."
        a.runModal(); return
    }
    let files = Packages.pick(for: game.title); guard !files.isEmpty else { return }
    Packages.add(files, to: r.source) { err in
        if let err { let a = NSAlert(); a.messageText = "The update was not added"; a.informativeText = err; a.runModal(); return }
        rebuildGame(game, builder: builder, show: show)
    }
}
