// Runs the launcher readers (Sources.swift) on a fixture tree and prints each game found as one JSON line; test_sources.py builds the tree and checks the lines.
// Arguments: <home> <shared> <applications> <CrossOver.app>
import Foundation

@main struct Check {
    static func main() {
        let a = CommandLine.arguments
        let p = Places(home: URL(fileURLWithPath: a[1]), shared: URL(fileURLWithPath: a[2]), applications: [URL(fileURLWithPath: a[3])], crossoverApp: URL(fileURLWithPath: a[4]))
        for g in Sources.scan(p) {
            var launch: [String: Any]
            switch g.launch {
            case .url(let s): launch = ["url": s]
            case .app(let s): launch = ["app": s]
            case .process(let e, let args): launch = ["process": [e] + args]
            case .crossover(let b, let args): launch = ["crossover": b, "args": args]
            case .whisky(let e): launch = ["whisky": e]
            }
            var o: [String: Any] = ["id": g.id, "name": g.name, "store": g.store.rawValue, "launch": launch]
            if let r = g.runtime { o["runtime"] = r.rawValue }
            if let b = g.bottle { o["bottle"] = b }
            if let f = g.folder { o["folder"] = f }
            if let s = g.seconds { o["seconds"] = s }
            if let d = g.lastPlayed { o["last"] = d.timeIntervalSince1970 }
            print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)!)
        }
    }
}
