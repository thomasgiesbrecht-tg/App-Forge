import Foundation

/// Was die Uhr von AppForge wissen muss – bewusst klein, damit die Übertragung vom iPhone schnell ist.
/// Das iPhone baut den Stand aus seiner Verbindung zum Mac und schickt ihn per WatchConnectivity.
struct WatchState: Codable, Sendable, Equatable {
    struct Mission: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var title: String
        var projectName: String
        var stateTitle: String
        var isFinished: Bool
        var activity: String?
        var progress: Double?
        var spentUSD: Double
        var buildOK: Bool?
    }

    struct Permission: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var directory: String
        var title: String
        /// z. B. „bash“, „edit“
        var kind: String
        /// Befehl oder Datei, gekürzt
        var detail: String?
    }

    struct Project: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
    }

    var macName: String
    var connected: Bool
    var updatedAt: Date
    var eurPerUsd: Double
    var spentTodayUSD: Double
    var missions: [Mission]
    var permissions: [Permission]
    var projects: [Project]

    var running: Int { missions.filter { !$0.isFinished }.count }

    static let empty = WatchState(macName: "Mac", connected: false, updatedAt: .distantPast, eurPerUsd: 0.86,
                                  spentTodayUSD: 0, missions: [], permissions: [], projects: [])
}

/// Aktion von der Uhr an das iPhone (das sie an den Mac weitergibt).
enum WatchAction: Codable, Sendable {
    case refresh
    case reply(permissionID: String, directory: String, answer: String)
    case idea(projectID: String, text: String)
}

enum WatchCoding {
    static let stateKey = "zustand"
    static let actionKey = "aktion"

    static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

extension WatchState {
    /// Betrag in Euro und Cent wie auf Mac und iPhone: „0,0008 € · 0,08 ct“.
    func euro(_ usd: Double) -> String {
        let value = usd * eurPerUsd
        let digits = value > 0 && value < 0.01 ? 4 : (value > 0 && value < 0.1 ? 3 : 2)
        let cents = value * 100
        let centDigits = cents == 0 ? 0 : (cents < 1 ? 2 : (cents < 10 ? 1 : 0))
        func comma(_ number: Double, _ digits: Int) -> String {
            String(format: "%.\(digits)f", number).replacingOccurrences(of: ".", with: ",")
        }
        return "\(comma(value, digits)) € · \(comma(cents, centDigits)) ct"
    }

    /// Nur Euro – für die knappen Komplikationen.
    func euroShort(_ usd: Double) -> String {
        let value = usd * eurPerUsd
        return String(format: value < 0.1 ? "%.3f" : "%.2f", value).replacingOccurrences(of: ".", with: ",") + " €"
    }
}

/// Gemeinsamer Speicher von Watch-App und Komplikationen (App-Gruppe auf der Uhr).
enum WatchStore {
    static let group = "group.com.captureworks.AppForge.Companion"
    private static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    static func load() -> WatchState {
        WatchCoding.decode(WatchState.self, from: defaults.data(forKey: "watch.state")) ?? .empty
    }

    static func save(_ state: WatchState) {
        defaults.set(WatchCoding.encode(state), forKey: "watch.state")
    }
}
