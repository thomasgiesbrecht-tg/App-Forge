import Foundation

/// Ein von AppForge verwalteter Agent. Wird als Markdown-Datei mit Frontmatter in
/// `<Konfigurationsordner>/agents/<name>.md` gespeichert – dem Format, das OpenCode einliest.
struct AgentDefinition: Identifiable, Hashable, Sendable {
    enum Role: String, CaseIterable, Identifiable, Sendable {
        case primary, subagent, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .primary: "Hauptagent"
            case .subagent: "Unteragent"
            case .all: "Beides"
            }
        }

        var detail: String {
            switch self {
            case .primary: "Du sprichst direkt mit ihm im Chat."
            case .subagent: "Wird von anderen Agenten beauftragt oder per @Name gerufen."
            case .all: "Direkt nutzbar und von anderen beauftragbar."
            }
        }
    }

    var name: String
    var description: String
    var role: Role
    /// `anbieter/modell` – leer bedeutet: das im Chat gewählte Modell.
    var model: String?
    var instructions: String
    var canEdit = true
    var canRunCommands = true
    var canDelegate = false
    /// IDs der Konnektoren, die dieser Agent zusätzlich benutzen darf.
    var connectors: [String] = []

    var id: String { name }

    var displayName: String { name.replacingOccurrences(of: "-", with: " ").capitalized }

    /// Gültiger Dateiname: Kleinbuchstaben, Ziffern, Bindestriche.
    static func slug(_ text: String) -> String {
        let replaced = text.lowercased()
            .replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue").replacingOccurrences(of: "ß", with: "ss")
        let allowed = replaced.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }
}

enum AgentLibrary {
    static var directory: URL { EngineConfig.configDirectory.appending(path: "agents", directoryHint: .isDirectory) }

    static func load() -> [AgentDefinition] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "md" && !["dispatcher", "ideen"].contains($0.deletingPathExtension().lastPathComponent) }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return parse(text, name: url.deletingPathExtension().lastPathComponent)
            }
            .sorted { order($0) < order($1) }
    }

    static func save(_ agent: AgentDefinition, replacing oldName: String? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let oldName, oldName != agent.name {
            try? FileManager.default.removeItem(at: file(for: oldName))
        }
        try serialize(agent).write(to: file(for: agent.name), atomically: true, encoding: .utf8)
    }

    static func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: file(for: name))
    }

    /// Legt beim ersten Start das Starter-Team an – und ergänzt später hinzugekommene Starter einmalig.
    static func installStartersIfNeeded() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "starterAgentsInstalled") {
            for agent in starters { try? save(agent) }
            defaults.set(true, forKey: "starterAgentsInstalled")
            defaults.set(true, forKey: "starterAgentsV2Installed")
            return
        }
        if !defaults.bool(forKey: "starterAgentsV2Installed") {
            let existing = Set(load().map(\.name))
            for agent in starters where ["ui-designer", "tester"].contains(agent.name) && !existing.contains(agent.name) {
                try? save(agent)
            }
            defaults.set(true, forKey: "starterAgentsV2Installed")
        }
    }

    private static func file(for name: String) -> URL { directory.appending(path: "\(name).md") }

    private static func order(_ agent: AgentDefinition) -> String {
        let rank = switch agent.role { case .primary: "0"; case .all: "1"; case .subagent: "2" }
        return rank + agent.name
    }

    // MARK: Format

    private static func serialize(_ agent: AgentDefinition) -> String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ") + "\""
        }
        var lines = ["---", "description: \(quoted(agent.description))", "mode: \(agent.role.rawValue)"]
        if let model = agent.model, !model.isEmpty { lines.append("model: \(model)") }
        var permissions: [String] = []
        if !agent.canEdit { permissions.append("  edit: deny") }
        if !agent.canRunCommands { permissions.append("  bash: deny") }
        if !agent.canDelegate { permissions.append("  task: deny") }
        if !permissions.isEmpty { lines += ["permission:"] + permissions }
        if !agent.connectors.isEmpty {
            lines.append("tools:")
            lines += agent.connectors.map { "  \"\($0)_*\": true" }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func parse(_ text: String, name: String) -> AgentDefinition? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        var agent = AgentDefinition(name: name, description: "", role: .all, model: nil, instructions: "",
                                    canEdit: true, canRunCommands: true, canDelegate: true)
        for line in lines[1..<end] {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            var value = parts[1]
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            switch parts[0] {
            case "description": agent.description = value
            case "mode": agent.role = AgentDefinition.Role(rawValue: value) ?? .all
            case "model": agent.model = value
            case "edit": agent.canEdit = value != "deny"
            case "bash": agent.canRunCommands = value != "deny"
            case "task": agent.canDelegate = value != "deny"
            default:
                // Freigeschaltete Konnektoren: "<id>_*": true
                if parts[0].hasPrefix("\""), parts[0].hasSuffix("_*\""), value == "true" {
                    agent.connectors.append(String(parts[0].dropFirst().dropLast(3)))
                }
            }
        }
        agent.instructions = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return agent
    }

    // MARK: Vorlagen für neue Agenten

    enum Template: String, CaseIterable, Identifiable {
        case empty, davinci, swiftExpert

        var id: String { rawValue }

        var title: String {
            switch self {
            case .empty: "Leerer Agent"
            case .davinci: "DaVinci-Spezialist"
            case .swiftExpert: "Swift-Experte (aktuell)"
            }
        }

        var symbol: String {
            switch self {
            case .empty: "person.crop.circle.badge.plus"
            case .davinci: "film.stack"
            case .swiftExpert: "swift"
            }
        }

        /// Erzeugt den Agenten; Konnektoren, deren Name passt, werden gleich freigeschaltet.
        func make(connectors: [Connector]) -> AgentDefinition {
            switch self {
            case .empty:
                return AgentDefinition(name: "", description: "", role: .subagent, model: nil, instructions: "",
                                       canEdit: true, canRunCommands: true, canDelegate: false)
            case .davinci:
                let ids = connectors.filter { $0.title.localizedCaseInsensitiveContains("davinci") || $0.title.localizedCaseInsensitiveContains("resolve") }.map(\.id)
                return AgentDefinition(
                    name: "davinci",
                    description: "Spezialist für DaVinci Resolve: Projekte, Timelines, Schnitt, Farbe, Fusion, Fairlight, LUTs/DCTL und Rendern – über den DaVinci-Konnektor.",
                    role: .all,
                    model: nil,
                    instructions: """
                    Du bist Spezialist für DaVinci Resolve (Studio) und arbeitest über die DaVinci-Werkzeuge direkt in der laufenden Anwendung.

                    Vorgehen:
                    1. Rufe zu Beginn die Werkzeuge auf, die den Stand und Neuerungen der installierten Version liefern (z. B. „get_whats_new“, „get_resolve_status“). Resolve bekommt häufig neue Funktionen, die du nicht kennst.
                    2. Suche Funktionen in der Scripting-API nach (Werkzeuge wie „search_scripting_api“, „get_scripting_docs“), statt sie zu raten.
                    3. Lies zuerst den Zustand (Projekt, Timeline, Clips), bevor du etwas veränderst.
                    4. Arbeite in kleinen, prüfbaren Schritten und berichte, was sich in Resolve geändert hat.

                    Fachgebiete: Media Pool und Timelines, Schnitt und Marker, Farbkorrektur (Nodes, LUTs, DCTL, Color Management), Fusion, Fairlight, Render-Queue und Exportformate.

                    Sicherheit: Frage ausdrücklich nach, bevor du Timelines oder Clips löschst oder überschreibst, Projekte schließt, Renderaufträge startest oder unsichere Skripte ausführst. Lege bei größeren Änderungen vorher eine Kopie der Timeline an.
                    """,
                    canEdit: false, canRunCommands: false, canDelegate: false, connectors: ids
                )
            case .swiftExpert:
                return AgentDefinition(
                    name: "swift-experte",
                    description: "Kennt die neuesten Swift- und Apple-SDK-Versionen, prüft neue APIs in Doku und Swift Evolution nach und nutzt sie passend zum Deployment Target.",
                    role: .all,
                    model: nil,
                    instructions: """
                    Du bist Experte für Swift und die Apple-SDKs auf dem neuesten Stand.

                    Dein Trainingswissen hat einen Stichtag. Prüfe deshalb neue oder unsichere APIs immer nach, bevor du sie verwendest:
                    - Installierte Versionen: `xcodebuild -version` und `swift --version`.
                    - Apple-Dokumentation über die Xcode-Werkzeuge (Dokumentationssuche), sonst per Websuche auf developer.apple.com.
                    - Neue Sprachfunktionen in Swift Evolution (github.com/swiftlang/swift-evolution) und in den Release Notes.
                    Nenne bei neuen Funktionen die Version, ab der sie verfügbar sind, und prüfe das Deployment Target des Projekts.

                    Stil:
                    - Swift 6 mit strikter Concurrency: @MainActor für UI, actors für geteilten Zustand, @concurrent für Hintergrundarbeit, Sendable sauber.
                    - Moderne Sprachmittel, wo sie passen: typed throws, ~Copyable, InlineArray, Span, Makros.
                    - SwiftUI mit Observation (@Observable), SwiftData, Swift Testing (@Test, #expect).
                    - Keine veralteten APIs, wenn es einen modernen Ersatz gibt – und erkläre knapp, warum.

                    Lade passende Skills (apple-swift-concurrency, apple-swiftui-patterns, apple-build-loop). Baue nach jeder Änderung und behebe alle Fehler und Warnungen.
                    """,
                    canEdit: true, canRunCommands: true, canDelegate: false
                )
            }
        }
    }

    // MARK: Starter-Team

    static let starters: [AgentDefinition] = [
        AgentDefinition(
            name: "koordinator",
            description: "Zerlegt Aufgaben und verteilt sie an Swift-Entwickler und Lektor. Schreibt selbst keinen Code.",
            role: .primary,
            model: nil,
            instructions: """
            Du bist der Koordinator eines kleinen Teams, das native Apps für iOS, iPadOS und macOS baut.
            Du schreibst selbst keinen Code und änderst keine Dateien.

            So arbeitest du:
            1. Verstehe das Ziel. Lies bei Bedarf Dateien, um den Stand des Projekts zu kennen.
            2. Zerlege die Aufgabe in klar abgegrenzte Teilaufgaben.
            3. Beauftrage die Unteragenten über das Task-Werkzeug:
               - `swift-entwickler` für Code, Architektur, Builds, Tests und alles rund um Xcode.
               - `lektor` für Texte: UI-Beschriftungen, Lokalisierung, Fehlermeldungen, App-Store-Texte, Dokumentation.
               Unabhängige Teilaufgaben darfst du parallel vergeben.
            4. Gib jedem Auftrag alles mit, was nötig ist: Ziel, betroffene Dateien, Plattform, Akzeptanzkriterien.
            5. Prüfe die Ergebnisse. Wenn etwas fehlt oder der Build rot ist, beauftrage nach.
            6. Fasse am Ende kurz zusammen: Was ist erledigt, was wurde geprüft, was ist offen.
            """,
            canEdit: false, canRunCommands: false, canDelegate: true
        ),
        AgentDefinition(
            name: "swift-entwickler",
            description: "Schreibt modernen Swift-6-Code (SwiftUI, Observation, Swift Testing), baut und testet in Xcode.",
            role: .all,
            model: nil,
            instructions: """
            Du bist ein erfahrener Apple-Entwickler und schreibst Swift der neuesten Generation.

            Standards:
            - Swift 6 mit strikter Concurrency; @MainActor für UI, actors für geteilten Zustand, @concurrent für Hintergrundarbeit.
            - SwiftUI zuerst: @Observable, @Environment, NavigationStack bzw. NavigationSplitView, .task statt onAppear+Task.
            - SwiftData für Persistenz, Swift Testing (@Test, #expect) für Tests.
            - Keine veralteten APIs (ObservableObject, @Published, NavigationView, DispatchQueue für UI-Updates).

            Arbeitsweise:
            - Lade die passenden Skills (apple-build-loop, apple-swift-concurrency, apple-swiftui-patterns, apple-platform-…).
            - Ändere gezielt, baue nach jeder Änderung und behebe alle Fehler und Warnungen, bevor du fertig meldest.
            - Prüfe UI-Änderungen im Simulator (Screenshot oder UI-Hierarchie).
            - Melde am Ende knapp: was geändert wurde, welche Dateien, wie es verifiziert wurde.
            """,
            canEdit: true, canRunCommands: true, canDelegate: false
        ),
        AgentDefinition(
            name: "ui-designer",
            description: "Gestaltet Oberflächen in SwiftUI: Layout, Typografie, Farben, Abstände, Animationen – nach Apples Human Interface Guidelines.",
            role: .all,
            model: nil,
            instructions: """
            Du bist UI-Designer für native Apple-Apps und setzt Gestaltung direkt in SwiftUI um.

            Arbeitsweise:
            - Lade die passenden Skills (apple-swiftui-patterns, apple-platform-ios/ipados/macos und – falls vorhanden – ui-ux-pro-max oder mobile-app-ui-design).
            - Halte dich an die Human Interface Guidelines: klare Hierarchie, Dynamic Type, Safe Areas, ausreichender Kontrast, Touch-Ziele ≥ 44 pt.
            - Lege Farben, Schriften und Abstände zentral an (z. B. eine Theme-Datei) statt verstreuter Einzelwerte.
            - Animationen sparsam und mit Bedeutung; „Bewegung reduzieren“ respektieren.
            - Bearbeite nur Ansichten und Design-Dateien. Logik und Datenmodelle gehören anderen Agenten.
            - Baue nach Änderungen und prüfe das Ergebnis per Simulator-Screenshot. Beschreibe kurz, was sich optisch geändert hat.
            """,
            canEdit: true, canRunCommands: true, canDelegate: false
        ),
        AgentDefinition(
            name: "tester",
            description: "Schreibt und führt Tests aus (Swift Testing, UI-Tests), baut das Projekt und meldet Fehler mit Ursache.",
            role: .all,
            model: nil,
            instructions: """
            Du bist Tester für Swift-Projekte.

            Arbeitsweise:
            - Baue das Projekt zuerst und behebe nur Build-Fehler, die eindeutig sind; größere Probleme meldest du.
            - Schreibe fehlende Tests mit Swift Testing (@Test, #expect), für Oberflächen UI-Tests.
            - Führe alle Tests aus (Skill apple-build-loop) und prüfe wichtige Abläufe im Simulator.
            - Ändere Produktionscode nur für klare, kleine Korrekturen und nenne sie ausdrücklich.
            - Melde am Ende: Build-Status, Anzahl Tests bestanden/fehlgeschlagen, gefundene Fehler mit Datei und Ursache.
            """,
            canEdit: true, canRunCommands: true, canDelegate: false
        ),
        AgentDefinition(
            name: "lektor",
            description: "Prüft Texte (UI, Lokalisierung, App-Store, Doku) auf Rechtschreibung, Stil und Konsistenz. Ändert nichts selbst.",
            role: .subagent,
            model: nil,
            instructions: """
            Du bist Lektor für App-Texte auf Deutsch und Englisch.

            Prüfe:
            - Rechtschreibung, Grammatik, Zeichensetzung, typografische Anführungszeichen und Gedankenstriche.
            - Stil: kurz, klar, freundlich, aktiv formuliert; einheitliche Anrede (du oder Sie) und Begriffe.
            - Apple-Konventionen: z. B. „Einstellungen“, „Abbrechen“, „Fertig“; Buttons als Verben.
            - Länge: UI-Texte müssen auch auf kleinen Displays und mit großer Schrift passen.

            Texte findest du in .xcstrings-, .strings- und Swift-Dateien (Text("…"), String(localized:)) sowie in Markdown.

            Du änderst keine Dateien. Liefere eine Liste:
            `Datei:Zeile` – alt → neu – kurze Begründung.
            Sortiere nach Wichtigkeit und nenne am Ende die Anzahl der Funde.
            """,
            canEdit: false, canRunCommands: false, canDelegate: false
        ),
    ]
}
