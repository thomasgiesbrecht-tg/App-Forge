import Foundation

/// Schreibt die OpenCode-Konfiguration, die AppForge mitbringt:
/// Apple-Grundanweisungen, Apple-Skills und die Xcode-MCP-Server.
/// Die Einstellungen gelten für jedes Modell gleich – das ist der Kern der Anbieterneutralität.
enum EngineConfig {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "AppForge", directoryHint: .isDirectory)
    }()

    /// Wird als OPENCODE_CONFIG_DIR gesetzt; OpenCode sucht hier u. a. nach `skills/<name>/SKILL.md`.
    static var configDirectory: URL { supportDirectory.appending(path: "opencode", directoryHint: .isDirectory) }
    static var configFile: URL { supportDirectory.appending(path: "opencode.json") }
    static var baseInstructionsFile: URL { supportDirectory.appending(path: "appforge-base.md") }

    struct MCPToggle: Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String
        let command: [String]
    }

    static let mcpServers: [MCPToggle] = [
        MCPToggle(
            id: "xcode",
            title: "Xcode (mcpbridge)",
            detail: "Xcodes eigener MCP-Server: Build, Diagnosen, Previews, Doku. Xcode muss mit geöffnetem Projekt laufen.",
            command: ["xcrun", "mcpbridge"]
        ),
        MCPToggle(
            id: "xcodebuildmcp",
            title: "XcodeBuildMCP",
            detail: "Build, Run und Tests für Simulator, Gerät und Mac, UI-Steuerung, Screenshots, Logs. Benötigt Node.js.",
            command: ["npx", "-y", "xcodebuildmcp@latest", "mcp"]
        ),
    ]

    static func isEnabled(_ server: MCPToggle) -> Bool {
        UserDefaults.standard.object(forKey: "mcp.\(server.id)") as? Bool ?? true
    }

    static func setEnabled(_ server: MCPToggle, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "mcp.\(server.id)")
    }

    /// Legt Konfiguration, Grundanweisungen und Skills an bzw. aktualisiert sie.
    static func write() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        if let base = Bundle.main.url(forResource: "appforge-base", withExtension: "md") {
            try replaceItem(at: baseInstructionsFile, with: base)
        }
        try installBundledSkills()
        AgentLibrary.installStartersIfNeeded()
        try installDispatcherAgent()

        var mcp: [String: Any] = [:]
        for server in mcpServers {
            // Großzügiges Timeout: Der erste Start per npx lädt das Paket erst herunter.
            mcp[server.id] = ["type": "local", "command": server.command, "enabled": isEnabled(server), "timeout": 120_000]
        }
        // Eigene Konnektoren (DaVinci, Blender, …). „Nur ausgewählte Agenten“ = global gesperrt,
        // die jeweiligen Agenten schalten die Werkzeuge in ihrer Datei wieder frei.
        var toolLocks: [String: Bool] = [:]
        for connector in ConnectorLibrary.load() {
            var entry: [String: Any] = ["enabled": connector.enabled, "timeout": 120_000]
            switch connector.kind {
            case .local:
                entry["type"] = "local"
                entry["command"] = connector.command
                if let cwd = connector.cwd { entry["cwd"] = cwd }
                if !connector.environment.isEmpty { entry["environment"] = connector.environment }
            case .remote:
                entry["type"] = "remote"
                entry["url"] = connector.url ?? ""
                if !connector.headers.isEmpty { entry["headers"] = connector.headers }
            }
            mcp[connector.id] = entry
            if connector.scope == .selectedAgents { toolLocks["\(connector.id)_*"] = false }
        }
        // Sparregeln, die die Engine selbst durchsetzt – unabhängig davon, was ein Modell „möchte“:
        // Schrittgrenze je Agent, gekürzte Werkzeugausgaben, Verdichten langer Verläufe, Kleinstmodell für Nebenaufgaben.
        var agents: [String: Any] = [:]
        for name in ["build", "plan", "general", "explore"] + AgentLibrary.load().map(\.name).filter({ $0 != "dispatcher" }) {
            agents[name] = ["steps": Savings.steps]
        }
        var config: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "instructions": [baseInstructionsFile.path],
            "mcp": mcp,
            "tools": toolLocks,
            // Die Engine fragt bei Änderungen und Befehlen immer nach –
            // welche Anfragen automatisch freigegeben werden, entscheidet AppForge (Berechtigungsmodus).
            "permission": ["edit": "ask", "bash": "ask"],
            "agent": agents,
            "tool_output": ["max_lines": Savings.toolOutputLines, "max_bytes": Savings.toolOutputBytes],
            // Alte Werkzeugausgaben aus dem Verlauf entfernen und bei vollem Kontext zusammenfassen
            "compaction": ["auto": true, "prune": true],
        ]
        if let small = Savings.smallModel { config["small_model"] = small }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: configFile, options: .atomic)
    }

    /// Mitgelieferte Skills liegen im Bundle flach als `skill-<name>.md` und werden
    /// in die von OpenCode erwartete Struktur `skills/<name>/SKILL.md` kopiert.
    private static func installBundledSkills() throws {
        let fm = FileManager.default
        let skillsDir = configDirectory.appending(path: "skills", directoryHint: .isDirectory)
        let bundled = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
        for url in bundled where url.lastPathComponent.hasPrefix("skill-") {
            let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "skill-", with: "")
            let dir = skillsDir.appending(path: name, directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try replaceItem(at: dir.appending(path: "SKILL.md"), with: url)
        }
    }

    /// Die Zentrale ist ein eigener, versteckter Agent ohne Werkzeuge.
    /// Der Ideen-Agent darf den Code lesen, aber nichts ändern.
    private static func installDispatcherAgent() throws {
        try FileManager.default.createDirectory(at: AgentLibrary.directory, withIntermediateDirectories: true)
        if let source = Bundle.main.url(forResource: "dispatcher-agent", withExtension: "md") {
            try replaceItem(at: AgentLibrary.directory.appending(path: "dispatcher.md"), with: source)
        }
        if let source = Bundle.main.url(forResource: "ideen-agent", withExtension: "md") {
            try replaceItem(at: AgentLibrary.directory.appending(path: "\(IdeaStore.agentName).md"), with: source)
        }
    }

    private static func replaceItem(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }
}
