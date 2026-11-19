// Siri, Spotlight and Shortcuts (App Intents): "Play <game> in Cartridge", "Open Cartridge console mode", and the same as Shortcuts actions. The games are the library's
// (GameEntity, by title ID). scripts/build_launcher.py compiles the intents' metadata into the app (Contents/Resources/Metadata.appintents) with Xcode's
// appintentsmetadataprocessor, which is what makes the system see them; the spoken phrases take a game's name once the library has told the system its games
// (updateAppShortcutParameters, after every scan).
import AppIntents
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
