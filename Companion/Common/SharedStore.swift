import Foundation

/// Gemeinsamer Speicher von App, Widgets und Kurzbefehlen (App-Gruppe).
/// Hier liegt alles, was auch ohne Verbindung zum Mac funktionieren muss.
enum SharedStore {
    static let groupID = "group.com.captureworks.AppForge.Companion"

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var defaults: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }

    private static func url(_ name: String) -> URL { container.appending(path: name) }

    private static func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? CompanionCoding.decoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? CompanionCoding.encoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    // MARK: Projekte (für Widgets, Siri und die Anzeige ohne Verbindung)

    static func projects() -> [CompanionProject] { read("projects.json", as: [CompanionProject].self) ?? [] }
    static func saveProjects(_ projects: [CompanionProject]) { write(projects, "projects.json") }

    /// Zuletzt benutzte Apps zuerst – bestimmt, welche Apps das Widget ohne Auswahl zeigt.
    static func recentProjectIDs() -> [String] { defaults.stringArray(forKey: "recentProjects") ?? [] }

    static func markUsed(_ projectID: String) {
        var list = recentProjectIDs().filter { $0 != projectID }
        list.insert(projectID, at: 0)
        defaults.set(Array(list.prefix(20)), forKey: "recentProjects")
    }

    static func projectsByRecent() -> [CompanionProject] {
        let recent = recentProjectIDs()
        return projects().sorted {
            (recent.firstIndex(of: $0.id) ?? Int.max, $0.isMac ? 1 : 0) < (recent.firstIndex(of: $1.id) ?? Int.max, $1.isMac ? 1 : 0)
        }
    }

    // MARK: Ideen, die noch zum Mac müssen

    static func pendingIdeas() -> [Idea] { read("pending-ideas.json", as: [Idea].self) ?? [] }

    static func addPendingIdea(_ idea: Idea) {
        var list = pendingIdeas()
        list.append(idea)
        write(list, "pending-ideas.json")
        markUsed(idea.projectID)
    }

    static func removePendingIdeas(_ ids: Set<UUID>) {
        write(pendingIdeas().filter { !ids.contains($0.id) }, "pending-ideas.json")
    }

    // MARK: Letzter bekannter Stand

    static func ideas() -> [String: [Idea]] { read("ideas.json", as: [String: [Idea]].self) ?? [:] }
    static func saveIdeas(_ ideas: [String: [Idea]]) { write(ideas, "ideas.json") }

    static func snapshot() -> CompanionSnapshot? { read("snapshot.json", as: CompanionSnapshot.self) }
    static func saveSnapshot(_ snapshot: CompanionSnapshot) { write(snapshot, "snapshot.json") }

    static func sessions() -> [String: [CompanionSession]] { read("sessions.json", as: [String: [CompanionSession]].self) ?? [:] }
    static func saveSessions(_ sessions: [String: [CompanionSession]]) { write(sessions, "sessions.json") }

    static func outbox() -> [OutboxItem] { read("outbox.json", as: [OutboxItem].self) ?? [] }
    static func saveOutbox(_ items: [OutboxItem]) { write(items, "outbox.json") }

    // MARK: Öffnen der Ideen-Erfassung (Widgets, Kontrollzentrum, Siri)

    static func requestCapture(projectID: String, mode: CaptureMode) {
        defaults.set(projectID, forKey: "capture.project")
        defaults.set(mode.rawValue, forKey: "capture.mode")
        defaults.set(Date.now.timeIntervalSince1970, forKey: "capture.time")
    }

    /// Holt eine offene Anfrage ab (nur, wenn sie frisch ist).
    static func takeCaptureRequest() -> (projectID: String, mode: CaptureMode)? {
        let time = defaults.double(forKey: "capture.time")
        guard let projectID = defaults.string(forKey: "capture.project"), Date.now.timeIntervalSince1970 - time < 30 else { return nil }
        defaults.removeObject(forKey: "capture.project")
        let mode = CaptureMode(rawValue: defaults.string(forKey: "capture.mode") ?? "") ?? .write
        return (projectID, mode)
    }
}

/// Etwas, das zum Mac muss, sobald er erreichbar ist.
enum OutboxItem: Codable, Identifiable, Hashable, Sendable {
    case chat(id: UUID, projectID: String, sessionID: String?, text: String, createdAt: Date)
    case zentrale(id: UUID, text: String, projectID: String?, createdAt: Date)

    var id: UUID {
        switch self {
        case .chat(let id, _, _, _, _), .zentrale(let id, _, _, _): id
        }
    }
}

enum CaptureMode: String, Codable, Sendable {
    case speak, write
}

/// Links in die App: Kopplung, Ideen-Erfassung, Chats.
enum DeepLink {
    static func capture(_ projectID: String, mode: CaptureMode) -> URL {
        var components = URLComponents()
        components.scheme = CompanionProtocol.urlScheme
        components.host = "idee"
        components.queryItems = [URLQueryItem(name: "projekt", value: projectID), URLQueryItem(name: "modus", value: mode.rawValue)]
        return components.url!
    }

    static func chat(_ projectID: String, sessionID: String) -> URL {
        var components = URLComponents()
        components.scheme = CompanionProtocol.urlScheme
        components.host = "chat"
        components.queryItems = [URLQueryItem(name: "projekt", value: projectID), URLQueryItem(name: "chat", value: sessionID)]
        return components.url!
    }

    static let missions = URL(string: "\(CompanionProtocol.urlScheme)://auftraege")!
}
