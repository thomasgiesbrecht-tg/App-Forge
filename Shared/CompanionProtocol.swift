import Foundation

// Gemeinsame Datentypen von AppForge (Mac) und AppForge Companion (iPhone).
// Diese Datei wird in beide Projekte eingebunden – Änderungen müssen für beide Seiten passen.

enum CompanionProtocol {
    /// Bonjour-Dienst, unter dem AppForge im WLAN erreichbar ist.
    static let bonjourType = "_appforge._tcp"
    /// Fester Port, damit das iPhone den Mac auch unterwegs (z. B. über Tailscale) findet.
    static let defaultPort: UInt16 = 52_819
    static let version = 1
    /// URL-Schema der iPhone-App (Kopplung, Widgets, Kurzbefehle).
    static let urlScheme = "appforge-companion"
}

// MARK: Ideen

/// Eine Idee zu einer App. Wird nicht umgesetzt, sondern nur gesammelt und vom Ideen-Agenten eingeordnet.
struct Idea: Codable, Identifiable, Hashable, Sendable {
    enum Status: String, Codable, Sendable, CaseIterable {
        case open, done, dismissed

        var title: String {
            switch self {
            case .open: "offen"
            case .done: "erledigt"
            case .dismissed: "verworfen"
            }
        }
    }

    enum Source: String, Codable, Sendable {
        case mac, iphone, widget, siri
    }

    enum Analysis: String, Codable, Sendable {
        case pending, running, done, failed, off
    }

    var id: UUID
    /// Pfad des Projekts auf dem Mac – dient als Projekt-ID.
    var projectID: String
    /// Die Idee so, wie sie eingegeben wurde.
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var source: Source
    var status: Status = .open
    var analysis: Analysis = .pending

    // Vom Ideen-Agenten ergänzt
    var title: String?
    var summary: String?
    var category: String?
    /// klein, mittel oder groß
    var effort: String?
    var relatedFiles: [String]?
    /// Ähnliche, schon vorhandene Idee.
    var duplicateOf: UUID?
    /// Hinweise des Agenten, z. B. offene Fragen.
    var note: String?

    init(id: UUID = UUID(), projectID: String, text: String, source: Source, createdAt: Date = .now) {
        self.id = id
        self.projectID = projectID
        self.text = text
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return firstLine.count > 70 ? String(firstLine.prefix(70)) + " …" : firstLine
    }
}

// MARK: Zustand für das iPhone

struct CompanionProject: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var folderName: String
    /// Kleines PNG (ca. 120 px) des App-Icons.
    var iconPNG: Data?
    var openIdeas: Int
    /// Der Bereich „Mac“: Aufgaben ohne bestimmte App (Mac steuern, Konnektoren, MCP …).
    var isMac: Bool
}

struct CompanionMission: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var projectID: String
    var projectName: String
    var state: String
    var stateTitle: String
    var isFinished: Bool
    var agent: String
    var model: String
    var activity: String?
    var spentUSD: Double
    var budgetUSD: Double?
    var estimatedCostUSD: Double?
    var startedAt: Date
    var endedAt: Date?
    var timeLimitMinutes: Double?
    var files: [String]
    var additions: Int
    var deletions: Int
    var buildOK: Bool?
    var buildErrors: Int?
    var testsLabel: String?
    var testsOK: Bool?
    var progress: Double?
}

struct CompanionPermission: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var sessionID: String
    var directory: String
    /// z. B. „bash“, „edit“, „external_directory“
    var permission: String
    /// Auftrag bzw. Projekt, zu dem die Anfrage gehört.
    var title: String
    var patterns: [String]
    /// Befehl oder Diff, falls vorhanden (gekürzt).
    var detail: String?
}

struct CompanionTask: Codable, Hashable, Sendable {
    var title: String
    var agent: String
    var model: String
    var estimatedCostUSD: Double?
}

struct CompanionProposal: Codable, Hashable, Sendable {
    var title: String?
    var analysis: String?
    var reason: String?
    var estimatedCostUSD: Double?
    var estimatedMinutes: Double?
    var tasks: [CompanionTask]
}

struct CompanionZentraleMessage: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var isUser: Bool
    var text: String
    var completed: Bool
    var proposal: CompanionProposal?
    var launched: Bool
}

struct CompanionEvent: Codable, Identifiable, Hashable, Sendable {
    enum Tone: String, Codable, Sendable { case neutral, good, attention }
    var id: UUID
    var date: Date
    var source: String
    var text: String
    var tone: Tone
}

struct CompanionSession: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var projectID: String
    var title: String
    var updatedAt: Date
    var busy: Bool
    /// Benachrichtigung bei Nachfragen und wenn fertig (per „sag Bescheid …“ im Chat angefordert).
    var notify: Bool
}

struct CompanionChatMessage: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var isUser: Bool
    var text: String
    /// Kurzbeschreibungen der Werkzeug-Schritte, z. B. „bearbeitet Timeline.swift“.
    var steps: [String]
    var completed: Bool
    var error: String?
    var costUSD: Double?
    var agent: String?
    var model: String?
    var createdAt: Date
    /// Bilder aus der Antwort (z. B. Simulator-Screenshots), nur die neuesten.
    var images: [Data]
}

struct CompanionChat: Codable, Hashable, Sendable {
    var projectID: String
    var sessionID: String
    var title: String
    var busy: Bool
    var notify: Bool
    var activity: String?
    var messages: [CompanionChatMessage]
}

/// Xcode-Projekt auf dem Mac, das noch nicht in AppForge ist.
struct DiscoveredProject: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var detail: String
}

/// Inhalt einer Live-Aktivität. Zeiten als Sekunden seit 1970, weil ActivityKit
/// Push-Inhalte mit dem Standard-Decoder liest.
struct LiveTaskState: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case running, needsYou, done, failed }

    var kind: Kind
    var title: String
    var status: String
    var activity: String?
    var spentUSD: Double
    var startedAt: Double
    var endedAt: Double?
    var partsDone: Int
    var partsTotal: Int
}

/// Wofür eine Live-Aktivität bzw. Benachrichtigung gilt.
enum LiveTarget: Codable, Hashable, Sendable {
    case session(projectID: String, sessionID: String)
    case missionGroup(UUID)
}

/// Alles, was das iPhone live anzeigt. Der Mac schickt es bei jeder Änderung neu.
struct CompanionSnapshot: Codable, Hashable, Sendable {
    var macName: String
    var engineRunning: Bool
    var engineError: String?
    var selectedProjectID: String?
    var permissionMode: String
    var spentToday: Double
    var missions: [CompanionMission]
    var permissions: [CompanionPermission]
    var zentrale: [CompanionZentraleMessage]
    var zentraleThinking: Bool
    var zentraleError: String?
    var events: [CompanionEvent]
    var simulatorBooted: Bool
    var simulatorName: String?
}

// MARK: Nachrichten

enum PermissionAnswer: String, Codable, Sendable {
    case once, always, reject
}

/// iPhone → Mac
struct CompanionRequest: Codable, Sendable {
    enum Action: Codable, Sendable {
        case hello(deviceID: String, deviceName: String, protocolVersion: Int)
        case projects
        case ideas(projectID: String)
        /// Neue oder offline gesammelte Ideen übertragen. Bereits bekannte IDs werden ignoriert.
        case addIdeas([Idea])
        case setIdeaStatus(id: UUID, projectID: String, status: Idea.Status)
        case deleteIdea(id: UUID, projectID: String)
        case analyzeIdea(id: UUID, projectID: String)
        /// Frage an den Ideen-Agenten der App, z. B. „Was habe ich zum Export notiert?“
        case askIdeas(projectID: String, question: String)
        // Chats in einer App – wie am Mac
        case sessions(projectID: String)
        /// Chat öffnen: Der Mac schickt ihn danach bei jeder Änderung neu, bis `closeChat`.
        case openChat(projectID: String, sessionID: String)
        case closeChat
        /// Ohne `sessionID` wird ein neuer Chat angelegt.
        case sendChat(projectID: String, sessionID: String?, text: String, agent: String?)
        case abortChat(projectID: String, sessionID: String)
        case setNotify(target: LiveTarget, enabled: Bool)

        // Projekte auf dem Mac
        case discoverProjects
        case addProject(path: String)

        // Benachrichtigungen & Live-Aktivitäten
        case registerPush(token: String, environment: String, bundleID: String)
        case registerLiveActivity(target: LiveTarget, token: String, environment: String)

        case zentrale(text: String, projectID: String?)
        case newZentraleConversation
        case launchProposal(messageID: String)
        case stopMission(id: UUID)
        case replyPermission(id: String, directory: String, answer: PermissionAnswer)
        case simulatorScreenshot
    }

    var id: UUID = UUID()
    var action: Action
}

/// Mac → iPhone
struct CompanionReply: Codable, Sendable {
    enum Payload: Codable, Sendable {
        case welcome(macName: String, protocolVersion: Int)
        case snapshot(CompanionSnapshot)
        case projects([CompanionProject])
        case ideas(projectID: String, ideas: [Idea])
        case answer(String)
        case sessions(projectID: String, sessions: [CompanionSession])
        case chat(CompanionChat)
        case chatStarted(projectID: String, sessionID: String, notify: Bool)
        case discovered([DiscoveredProject])
        /// Vorschlag gestartet – Gruppe für die Live-Aktivität.
        case launched(groupID: UUID?, title: String, projectName: String, notify: Bool)
        /// JPEG des Simulators, `nil`, wenn keiner läuft.
        case screenshot(Data?)
        case ok
        case error(String)
    }

    /// Antwort auf eine Anfrage – `nil` bei Nachrichten, die der Mac von sich aus schickt.
    var requestID: UUID?
    var payload: Payload
}

enum CompanionCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

// MARK: Kopplung

/// Inhalt des QR-Codes bzw. Kopplungs-Links:
/// `appforge-companion://pair?key=…&name=…&port=…&host=…`
struct PairingInfo: Codable, Hashable, Sendable {
    /// 32 zufällige Bytes – daraus entsteht der Schlüssel für die verschlüsselte Verbindung.
    var secret: Data
    var macName: String
    var port: UInt16
    /// Adresse für unterwegs, z. B. `mein-mac.tailnet.ts.net`.
    var remoteHost: String?

    var url: URL {
        var components = URLComponents()
        components.scheme = CompanionProtocol.urlScheme
        components.host = "pair"
        var items = [
            URLQueryItem(name: "key", value: secret.base64URLEncoded),
            URLQueryItem(name: "name", value: macName),
            URLQueryItem(name: "port", value: String(port)),
        ]
        if let remoteHost, !remoteHost.isEmpty { items.append(URLQueryItem(name: "host", value: remoteHost)) }
        components.queryItems = items
        return components.url!
    }

    init(secret: Data, macName: String, port: UInt16, remoteHost: String?) {
        self.secret = secret
        self.macName = macName
        self.port = port
        self.remoteHost = remoteHost
    }

    init?(url: URL) {
        guard url.scheme == CompanionProtocol.urlScheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let key = value("key"), let secret = Data(base64URLEncoded: key), secret.count >= 32 else { return nil }
        self.secret = secret
        self.macName = value("name") ?? "Mac"
        self.port = value("port").flatMap(UInt16.init) ?? CompanionProtocol.defaultPort
        self.remoteHost = value("host")
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}
