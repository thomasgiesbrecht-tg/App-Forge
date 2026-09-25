import Foundation

// Datentypen der OpenCode-Server-API (nur die Felder, die AppForge braucht).
// Referenz: @opencode-ai/sdk, dist/v2/gen/types.gen.d.ts

struct Session: Codable, Identifiable, Hashable, Sendable {
    struct Time: Codable, Hashable, Sendable {
        var created: Double
        var updated: Double
    }

    struct Revert: Codable, Hashable, Sendable {
        var messageID: String
        var partID: String?
    }

    var id: String
    var title: String
    var directory: String
    var parentID: String?
    var time: Time
    /// Gesetzt, wenn der Chat auf einen früheren Stand zurückgesetzt wurde (noch wiederherstellbar).
    var revert: Revert?
}

struct MessageInfo: Codable, Identifiable, Sendable {
    struct Time: Codable, Sendable {
        var created: Double
        var completed: Double?
    }
    struct Tokens: Codable, Sendable {
        struct Cache: Codable, Sendable { var read: Double; var write: Double }
        var input: Double
        var output: Double
        var reasoning: Double?
        var cache: Cache?

        /// Wie viel Kontext diese Antwort belegt hat (inkl. zwischengespeicherter Tokens).
        var contextUsed: Double { input + (cache?.read ?? 0) + (cache?.write ?? 0) }
    }
    struct ModelRef: Codable, Sendable {
        var providerID: String
        var modelID: String
    }

    var id: String
    var sessionID: String
    var role: String
    var time: Time
    /// Bei Antworten: die Nutzer-Nachricht, auf die geantwortet wird.
    var parentID: String?
    var modelID: String?
    var providerID: String?
    var model: ModelRef?
    var agent: String?
    var error: JSONValue?
    var cost: Double?
    var tokens: Tokens?
    /// Bei Nutzer-Nachrichten ein Objekt mit `diffs`, bei Antworten ein Bool – daher roh.
    var summary: JSONValue?

    var isUser: Bool { role == "user" }

    /// Dateiänderungen, die durch diese Nutzer-Nachricht entstanden sind.
    var fileChanges: [FileChange] {
        guard let diffs = summary?["diffs"], let data = try? JSONEncoder().encode(diffs) else { return [] }
        return (try? JSONDecoder().decode([FileChange].self, from: data)) ?? []
    }

    var wasAborted: Bool { error?["name"]?.stringValue == "MessageAbortedError" }

    var errorMessage: String? {
        guard let error, !wasAborted else { return nil }
        return error["data"]?["message"]?.stringValue ?? error["name"]?.stringValue ?? error.prettyPrinted
    }

    var modelLabel: String? {
        if let providerID, let modelID { return "\(providerID)/\(modelID)" }
        if let model { return "\(model.providerID)/\(model.modelID)" }
        return nil
    }
}

struct ToolState: Codable, Sendable {
    struct Time: Codable, Sendable { var start: Double?; var end: Double? }
    var status: String
    var input: JSONValue?
    var output: String?
    var title: String?
    var error: String?
    var metadata: JSONValue?
    var time: Time?
    /// Bilder, die ein Werkzeug geliefert hat (z. B. Simulator-Screenshots).
    var attachments: [Part]?
}

struct Part: Codable, Identifiable, Sendable {
    var id: String
    var sessionID: String
    var messageID: String
    var type: String
    var text: String?
    var synthetic: Bool?
    var tool: String?
    var callID: String?
    var state: ToolState?
    var filename: String?
    var mime: String?
    var url: String?
}

extension Part {
    /// Bei Unteragenten-Aufrufen (`task`) die ID des Unter-Chats.
    var childSessionID: String? { state?.metadata?["sessionId"]?.stringValue }

    var isImage: Bool { type == "file" && (mime ?? "").hasPrefix("image/") }
}

struct FileChange: Codable, Hashable, Identifiable, Sendable {
    var file: String?
    var patch: String?
    var additions: Double
    var deletions: Double
    var status: String?

    var id: String { file ?? UUID().uuidString }
    var name: String { (file as NSString?)?.lastPathComponent ?? "Datei" }
}

struct AgentInfo: Codable, Identifiable, Hashable, Sendable {
    struct ModelRef: Codable, Hashable, Sendable {
        var modelID: String
        var providerID: String
    }

    var name: String
    var description: String?
    var mode: String
    var native: Bool?
    var hidden: Bool?
    var model: ModelRef?

    var id: String { name }
    var isPrimary: Bool { mode == "primary" || mode == "all" }
    var isSubagent: Bool { mode == "subagent" || mode == "all" }
    var isVisible: Bool { hidden != true && !["compaction", "title", "summary", "dispatcher"].contains(name) }

    var displayName: String {
        switch name {
        case "build": "Bauen"
        case "plan": "Planen"
        case "general": "Allgemein"
        case "explore": "Erkunden"
        case "scout": "Späher"
        default: name.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

/// Anhang im Eingabefeld, bevor er verschickt wird.
struct Attachment: Identifiable, Hashable, Sendable {
    let id = UUID()
    var filename: String
    var mime: String
    /// `data:`-URL für Bilder/PDFs, `file://`-URL für alles andere.
    var url: String
    var thumbnail: Data?

    var isImage: Bool { mime.hasPrefix("image/") }
}

struct MessageEnvelope: Codable, Sendable {
    var info: MessageInfo
    var parts: [Part]
}

struct ChatMessage: Identifiable, Sendable {
    var info: MessageInfo
    var parts: [Part]
    var id: String { info.id }
}

// MARK: Anbieter & Modelle

struct ModelInfo: Codable, Identifiable, Hashable, Sendable {
    struct Capabilities: Codable, Hashable, Sendable {
        struct Modalities: Codable, Hashable, Sendable {
            var image: Bool
        }
        var toolcall: Bool
        var attachment: Bool
        var reasoning: Bool
        var input: Modalities?
    }
    struct Limit: Codable, Hashable, Sendable {
        var context: Double
        var output: Double
    }
    /// Preise in US-Dollar pro 1 Mio. Tokens.
    struct Cost: Codable, Hashable, Sendable {
        struct Cache: Codable, Hashable, Sendable { var read: Double; var write: Double }
        var input: Double
        var output: Double
        var cache: Cache?
    }

    var id: String
    var providerID: String
    var name: String
    var family: String?
    var capabilities: Capabilities?
    var limit: Limit?
    var cost: Cost?
    var status: String?
    var release_date: String?

    var supportsTools: Bool { capabilities?.toolcall ?? false }
    var supportsImages: Bool { capabilities?.input?.image ?? false }
}

struct Provider: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var env: [String]
    var models: [String: ModelInfo]

    var sortedModels: [ModelInfo] {
        models.values
            .filter { $0.status != "deprecated" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct ProviderList: Codable, Sendable {
    var all: [Provider]
    var `default`: [String: String]
    var connected: [String]
}

/// Eindeutige Modell-Auswahl, anbieterunabhängig.
struct ModelSelection: Codable, Hashable, Sendable {
    var providerID: String
    var modelID: String

    var label: String { "\(providerID)/\(modelID)" }
}

// MARK: Berechtigungen, Skills, MCP

struct PermissionRequest: Codable, Identifiable, Sendable {
    var id: String
    var sessionID: String
    var permission: String
    var patterns: [String]
    var metadata: JSONValue?
    var always: [String]?
}

enum PermissionReply: String, Codable, Sendable {
    case once, always, reject
}

struct SkillInfo: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var description: String?
    var location: String
    var id: String { location }
}

struct MCPStatus: Codable, Hashable, Sendable {
    var status: String
    var error: String?

    var isConnected: Bool { status == "connected" }
}

enum SessionActivity: Sendable, Equatable {
    case idle
    case busy
    case retry(String)
}
