import Foundation
import Observation

/// Beträge werden intern in US-Dollar geführt – so rechnen die Anbieter ab – und in Euro angezeigt.
/// Kurs: Referenzkurs der Europäischen Zentralbank, höchstens einmal am Tag geladen.
enum Money {
    private static let rateKey = "fx.eurPerUsd"
    private static let dateKey = "fx.date"

    /// Euro je US-Dollar. Bis zum ersten Laden ein vorsichtiger Näherungswert.
    static var eurPerUsd: Double { UserDefaults.standard.object(forKey: rateKey) as? Double ?? 0.86 }
    static var rateDate: String? { UserDefaults.standard.string(forKey: dateKey) }

    static func eur(fromUSD usd: Double) -> Double { usd * eurPerUsd }
    static func usd(fromEUR eur: Double) -> Double { eurPerUsd > 0 ? eur / eurPerUsd : eur }

    /// Anzeige in Euro und Cent: „0,0008 € · 0,08 ct“.
    static func format(_ usd: Double, precise: Bool = false) -> String {
        plain(usd, precise: precise) + " · " + cents(usd)
    }

    /// Nur Euro, z. B. für Texte an die Zentrale: „0,08 €“. Kleine Beträge mit mehr Stellen.
    static func plain(_ usd: Double, precise: Bool = false) -> String {
        let value = eur(fromUSD: usd)
        let digits = value > 0 && value < 0.01 ? 4 : (precise || (value > 0 && value < 0.1) ? 3 : 2)
        return formatEUR(value, digits: digits)
    }

    /// Nur Cent: „0,08 ct“, „2,4 ct“, „124 ct“.
    static func cents(_ usd: Double) -> String {
        let value = eur(fromUSD: usd) * 100
        let digits = value == 0 ? 0 : (value < 1 ? 2 : (value < 10 ? 1 : 0))
        return String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",") + " ct"
    }

    static func formatEUR(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",") + " €"
    }

    /// Lädt den aktuellen Kurs (ohne persönliche Daten, nur eine öffentliche XML-Datei der EZB).
    static func refreshIfNeeded() async {
        let today = Date().formatted(.iso8601.year().month().day())
        guard rateDate != today,
              let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8),
              let match = xml.firstMatch(of: /currency=['"]USD['"]\s+rate=['"]([0-9.]+)['"]/),
              let usdPerEur = Double(match.1), usdPerEur > 0
        else { return }
        UserDefaults.standard.set(1 / usdPerEur, forKey: rateKey)
        UserDefaults.standard.set(today, forKey: dateKey)
    }
}

/// Kostenbuch: was jede App bisher gekostet hat – Chats, Aufträge der Zentrale, Unteragenten und Medien.
/// Jede Antwort wird genau einmal gezählt (nach ihrer ID), auch wenn sie mehrfach gemeldet wird.
@MainActor
@Observable
final class CostLedger {
    /// Projektpfad → Summe in US-Dollar.
    private(set) var totals: [String: Double] = [:]
    /// Chat (Haupt-Sitzung) → Summe in US-Dollar, Unteragenten eingerechnet.
    private(set) var sessionTotals: [String: Double] = [:]
    @ObservationIgnored private var entries: [String: [String: Double]] = [:]
    @ObservationIgnored private var sessionEntries: [String: [String: Double]] = [:]
    @ObservationIgnored private var backfilled: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private struct Stored: Codable {
        var entries: [String: [String: Double]]
        var backfilled: [String]
        var sessions: [String: [String: Double]]?
    }

    private static var file: URL { EngineConfig.supportDirectory.appending(path: "kosten.json") }

    init() {
        if let data = try? Data(contentsOf: Self.file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            entries = stored.entries
            backfilled = Set(stored.backfilled)
            sessionEntries = stored.sessions ?? [:]
            totals = entries.mapValues { $0.values.reduce(0, +) }
            sessionTotals = sessionEntries.mapValues { $0.values.reduce(0, +) }
        }
    }

    func total(for project: String) -> Double { totals[project] ?? 0 }

    func total(forSession sessionID: String) -> Double { sessionTotals[sessionID] ?? 0 }

    /// `session`: der Chat, zu dem die Antwort gehört (bei Unteragenten der Haupt-Chat).
    func record(project: String, id: String, costUSD: Double, session: String? = nil) {
        guard costUSD > 0 else { return }
        var changed = false
        if entries[project]?[id] != costUSD {
            entries[project, default: [:]][id] = costUSD
            totals[project] = entries[project]?.values.reduce(0, +) ?? 0
            changed = true
        }
        if let session, sessionEntries[session]?[id] != costUSD {
            sessionEntries[session, default: [:]][id] = costUSD
            sessionTotals[session] = sessionEntries[session]?.values.reduce(0, +) ?? 0
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// „v2“: seit es Kosten je Chat gibt, wird einmal neu nachgetragen.
    func needsBackfill(_ project: String) -> Bool { !backfilled.contains("v2:" + project) }

    func markBackfilled(_ project: String) {
        backfilled.insert("v2:" + project)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let stored = Stored(entries: self.entries, backfilled: Array(self.backfilled), sessions: self.sessionEntries)
            if let data = try? JSONEncoder().encode(stored) { try? data.write(to: Self.file, options: .atomic) }
        }
    }
}
