import Foundation

/// Welcher Agent in der Live-Ansicht angeklickt ist – links erscheinen dann seine Gedanken.
struct ThoughtFocus: Hashable, Sendable {
    var nodeID: String
    var sessionID: String?
    var directory: String?
    var missionID: UUID?
    var title: String
    var subtitle: String
    var symbol: String
}

/// Ein Eintrag im Gedankenstrom eines Agenten.
struct ThoughtItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Der Auftrag bzw. eine Nachricht an den Agenten
        case instruction
        /// Gedanken des Modells (Reasoning)
        case thought
        /// Werkzeugschritt: liest, bearbeitet, baut …
        case step(status: String, childSessionID: String?)
        /// Antwort an den Nutzer
        case answer
    }

    var id: String
    var kind: Kind
    var text: String
    var time: Double
}

/// Baut aus dem Verlauf einer Sitzung den Gedankenstrom: Auftrag, Überlegungen, Schritte, Antworten.
enum ThoughtStream {
    static func items(from messages: [ChatMessage]) -> [ThoughtItem] {
        var items: [ThoughtItem] = []
        for message in messages {
            let time = message.info.time.created
            if message.info.isUser {
                let text = message.parts.filter { $0.type == "text" && $0.synthetic != true }.compactMap(\.text).joined(separator: "\n")
                if !text.isEmpty { items.append(ThoughtItem(id: message.id, kind: .instruction, text: text, time: time)) }
                continue
            }
            for part in message.parts {
                switch part.type {
                case "reasoning":
                    let text = (part.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { items.append(ThoughtItem(id: part.id, kind: .thought, text: text, time: time)) }
                case "text" where part.synthetic != true:
                    let text = (part.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { items.append(ThoughtItem(id: part.id, kind: .answer, text: text, time: time)) }
                case "tool" where part.tool != "todoread":
                    items.append(ThoughtItem(
                        id: part.id,
                        kind: .step(status: part.state?.status ?? "pending", childSessionID: part.childSessionID),
                        text: ActivityDigest.describe(part), time: time
                    ))
                default:
                    continue
                }
            }
        }
        return items
    }

    /// Beispiel für die Demo der Live-Ansicht.
    static func demo(for nodeID: String) -> [ThoughtItem] {
        let now = Date().timeIntervalSince1970 * 1000
        func item(_ n: Int, _ kind: ThoughtItem.Kind, _ text: String) -> ThoughtItem {
            ThoughtItem(id: "\(nodeID)-\(n)", kind: kind, text: text, time: now - Double(60 - n) * 8000)
        }
        return [
            item(0, .instruction, "Baue einen Einstellungsbildschirm mit Dark-Mode-Schalter. Nutze die vorhandene Architektur, baue danach und prüfe per Screenshot."),
            item(1, .thought, "Zuerst schaue ich, wie Einstellungen bisher gespeichert werden – gibt es schon ein @Observable-Modell oder wird @AppStorage direkt benutzt?"),
            item(2, .step(status: "completed", childSessionID: nil), "durchsucht den Code"),
            item(3, .step(status: "completed", childSessionID: nil), "liest Einstellungen.swift"),
            item(4, .thought, "Es gibt ein Einstellungen-Modell mit @AppStorage. Den Schalter hänge ich dort an, die Ansicht bekommt nur ein Toggle in einer Form-Sektion."),
            item(5, .step(status: "completed", childSessionID: nil), "bearbeitet SettingsView.swift"),
            item(6, .step(status: "running", childSessionID: nil), "baut das Projekt"),
        ]
    }
}
