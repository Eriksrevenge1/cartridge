// Siri, Spotlight and Shortcuts (App Intents): "Play <game> in Cartridge", "Open Cartridge console mode", and the same as Shortcuts actions. The games are the library's
// (GameEntity, by title ID). scripts/build_launcher.py compiles the intents' metadata into the app (Contents/Resources/Metadata.appintents) with Xcode's
// appintentsmetadataprocessor, which is what makes the system see them; the spoken phrases take a game's name once the library has told the system its games
// (updateAppShortcutParameters, after every scan).
import AppIntents
import AppKit
import Foundation

struct GameEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static var defaultQuery = GameQuery()
    let id: String   // the title ID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    init(_ g: Game) { id = g.titleID; name = g.title }
}

struct GameQuery: EntityStringQuery {
    @MainActor private func all() -> [GameEntity] {
        var seen = Set<String>()
        return Library.shared.games.filter { seen.insert($0.titleID).inserted }.map(GameEntity.init)
    }
    func entities(for identifiers: [String]) async throws -> [GameEntity] { await all().filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [GameEntity] {
        let q = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return await all().filter { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q) }
    }
    func suggestedEntities() async throws -> [GameEntity] { await all() }
}

struct PlayGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Game"
    static var description = IntentDescription("Starts a game from the Cartridge library, or brings it forward when it is already running.")
    static var openAppWhenRun = true
    @Parameter(title: "Game") var game: GameEntity
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$game)") }
    @MainActor func perform() async throws -> some IntentResult {
        guard let g = Library.shared.games.first(where: { $0.titleID == game.id }) else { throw $game.needsValueError("Which game?") }
        Library.shared.play(g)
        return .result()
    }
}

struct ConsoleModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Console Mode"
    static var description = IntentDescription("Opens Cartridge's console mode: the library full screen, for a controller.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { Router.shared.showConsole(); return .result() }
}

struct CartridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayGameIntent(), phrases: ["Play \(\.$game) in \(.applicationName)", "Start \(\.$game) in \(.applicationName)", "Launch \(\.$game) with \(.applicationName)"],
                    shortTitle: "Play Game", systemImageName: "gamecontroller.fill")
        AppShortcut(intent: ConsoleModeIntent(), phrases: ["Open \(.applicationName) console mode", "\(.applicationName) console mode"],
                    shortTitle: "Console Mode", systemImageName: "tv")
    }
    static var shortcutTileColor: ShortcutTileColor = .red
}

/// Siri by voice on the Mac: macOS runs App Shortcuts' phrases only on iPhone and iPad, and a build signed without an Apple team (this one) may not appear in Shortcuts at
/// all. A shortcut of the player's own runs by its name, though ("Hey Siri, Cartridge Console Mode"). So Cartridge writes one: a single Open URLs action on a cartridge://
/// link (Router), signed by /usr/bin/shortcuts for import, and opens it, which asks the player to add it to Shortcuts. Its name is the file's
enum SiriShortcut {
    static func addConsole() { add(name: "Cartridge Console Mode", url: "cartridge://console", glyph: 61440) }
    static func add(game: Game) { add(name: "Play \(game.title)", url: "cartridge://play?game=\(game.titleID)", glyph: 61440) }

    private static func add(name: String, url: String, glyph: Int) {
        let wf: [String: Any] = [
            "WFWorkflowClientVersion": "2607.0.1", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": glyph],
            "WFWorkflowTypes": [String](), "WFWorkflowInputContentItemClasses": [String](), "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowActions": [["WFWorkflowActionIdentifier": "is.workflow.actions.openurl",
                                   "WFWorkflowActionParameters": ["WFInput": ["Value": ["string": url, "attachmentsByRange": [String: Any]()],
                                                                              "WFSerializationType": "WFTextTokenString"]]]],
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cartridge-shortcuts-\(UUID().uuidString)", isDirectory: true)
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let raw = dir.appendingPathComponent("raw.shortcut"), out = dir.appendingPathComponent("\(safe).shortcut")
        DispatchQueue.global(qos: .userInitiated).async {
            var err = "", ok = false
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: wf, format: .binary, options: 0).write(to: raw)
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                p.arguments = ["sign", "--mode", "anyone", "--input", raw.path, "--output", out.path]
                let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
                try p.run(); p.waitUntilExit()
                err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                ok = p.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path)
            } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                if ok { NSWorkspace.shared.open(out); return }
                let a = NSAlert(); a.messageText = "Couldn't make the Siri shortcut"
                a.informativeText = "Shortcuts could not sign it (signing needs an iCloud account on this Mac).\n\nYou can make it by hand: a new shortcut named “\(name)” with one Open URLs action: \(url)\n\n\(err)"
                a.runModal()
            }
        }
    }
}
