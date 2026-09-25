import Foundation

/// Ein MCP-Konnektor (z. B. DaVinci Resolve, Blender), den AppForge an die Engine übergibt.
struct Connector: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case local, remote }
    enum Scope: String, Codable, CaseIterable, Identifiable, Sendable {
        case allAgents, selectedAgents
        var id: String { rawValue }
        var title: String { self == .allAgents ? "Alle Agenten" : "Nur ausgewählte Agenten" }
    }

    /// Kurzname ohne Sonderzeichen – OpenCode setzt ihn vor jedes Werkzeug (`<id>_<werkzeug>`).
    var id: String
    var title: String
    var kind: Kind = .local
    var command: [String] = []
    var cwd: String?
    var url: String?
    var environment: [String: String] = [:]
    var headers: [String: String] = [:]
    var enabled = true
    var scope: Scope = .allAgents
    /// Herkunft, z. B. „Claude Code“ oder „Claude-Erweiterung“ – nur zur Anzeige.
    var source: String?

    var summary: String {
        kind == .remote ? (url ?? "") : command.joined(separator: " ")
    }

    static func makeID(_ title: String, taken: Set<String>) -> String {
        let base = String(title.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(20))
        var id = base.isEmpty ? "konnektor" : base
        var counter = 2
        while taken.contains(id) || ["xcode", "xcodebuildmcp"].contains(id) {
            id = base + String(counter)
            counter += 1
        }
        return id
    }
}

enum ConnectorLibrary {
    private static let key = "connectors.v1"

    static func load() -> [Connector] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Connector].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [Connector]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: Import aus Claude

    /// Findet Konnektoren aus Claude Code (~/.claude.json), Claude Desktop und installierten Claude-Erweiterungen.
    static func discoverFromClaude() -> [Connector] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var found: [Connector] = []
        var taken = Set(load().map(\.id))

        func add(_ title: String, _ config: JSONValue, source: String, dirname: String? = nil, userConfig: [String: JSONValue] = [:]) {
            func expand(_ text: String) -> String {
                var result = text
                if let dirname { result = result.replacingOccurrences(of: "${__dirname}", with: dirname) }
                result = result.replacingOccurrences(of: "${HOME}", with: home.path)
                for (key, value) in userConfig {
                    let replacement: String = switch value {
                    case .array(let items): items.compactMap(\.stringValue).joined(separator: " ")
                    default: value.stringValue ?? ""
                    }
                    result = result.replacingOccurrences(of: "${user_config.\(key)}", with: replacement)
                }
                return result
            }
            var connector = Connector(id: Connector.makeID(title, taken: taken), title: title, source: source)
            if let url = config["url"]?.stringValue {
                connector.kind = .remote
                connector.url = url
                if case .object(let headers) = config["headers"] {
                    connector.headers = headers.compactMapValues(\.stringValue)
                }
            } else if let command = config["command"]?.stringValue {
                var args: [String] = []
                if case .array(let items) = config["args"] { args = items.compactMap(\.stringValue).map(expand) }
                // Nicht aufgelöste Platzhalter weglassen – die Erweiterung braucht dann eigene Einstellungen.
                args = args.filter { !$0.contains("${") }
                connector.command = [expand(command)] + args
                connector.cwd = dirname
            } else {
                return
            }
            if case .object(let env) = config["env"] {
                connector.environment = env.compactMapValues { $0.stringValue.map(expand) }.filter { !$0.value.contains("${") }
            }
            taken.insert(connector.id)
            found.append(connector)
        }

        // Claude Code
        if let data = try? Data(contentsOf: home.appending(path: ".claude.json")),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object(let servers) = json["mcpServers"] {
            for (name, config) in servers.sorted(by: { $0.key < $1.key }) { add(name, config, source: "Claude Code") }
        }

        // Claude Desktop
        let desktop = home.appending(path: "Library/Application Support/Claude")
        if let data = try? Data(contentsOf: desktop.appending(path: "claude_desktop_config.json")),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object(let servers) = json["mcpServers"] {
            for (name, config) in servers.sorted(by: { $0.key < $1.key }) { add(name, config, source: "Claude Desktop") }
        }

        // Claude-Erweiterungen (manifest.json je Ordner)
        let extensions = desktop.appending(path: "Claude Extensions")
        let settingsDir = desktop.appending(path: "Claude Extensions Settings")
        for folder in (try? fm.contentsOfDirectory(at: extensions, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
                  let manifest = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let config = manifest["server"]?["mcp_config"] else { continue }
            var userConfig: [String: JSONValue] = [:]
            if let settings = try? Data(contentsOf: settingsDir.appending(path: folder.lastPathComponent + ".json")),
               let json = try? JSONDecoder().decode(JSONValue.self, from: settings),
               case .object(let values) = json["userConfig"] {
                userConfig = values
            }
            let title = manifest["display_name"]?.stringValue ?? manifest["name"]?.stringValue ?? folder.lastPathComponent
            add(title, config, source: "Claude-Erweiterung", dirname: folder.path, userConfig: userConfig)
        }

        // Doppelte (gleicher Befehl bzw. gleiche URL) nur einmal
        var seen = Set<String>()
        return found.filter { seen.insert($0.summary).inserted }
    }
}
