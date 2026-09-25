import Foundation

/// Die Sparregeln von AppForge. Sie werden nicht nur der KI gesagt, sondern von App und Engine durchgesetzt:
/// Engine-Grenzen stehen in der OpenCode-Konfiguration, Stufen, Prüfschritt und Zeitfenster steuert der Dispatcher,
/// Vorschläge der Zentrale werden vor dem Start geprüft und korrigiert.
enum Savings {
    private static var defaults: UserDefaults { .standard }

    /// Erst ein günstiges Modell, ein stärkeres nur, wenn Build oder Tests scheitern.
    static var cascade: Bool {
        get { defaults.object(forKey: "savings.cascade") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "savings.cascade") }
    }

    /// Hat ein Agent Dateien geändert, aber nie gebaut, wird er einmal zum Bauen aufgefordert.
    static var verifyBuild: Bool {
        get { defaults.object(forKey: "savings.verify") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "savings.verify") }
    }

    /// Modell für Titel und Zusammenfassungen (`anbieter/modell`). `nil` = noch nicht festgelegt.
    static var smallModel: String? {
        get { defaults.string(forKey: "savings.smallModel") }
        set { defaults.set(newValue, forKey: "savings.smallModel") }
    }

    /// Höchstzahl an Arbeitsschritten je Agent, danach muss er zusammenfassen.
    static var steps: Int {
        get { defaults.object(forKey: "savings.steps") as? Int ?? 80 }
        set { defaults.set(newValue, forKey: "savings.steps") }
    }

    /// Werkzeugausgaben über dieser Länge werden gekürzt (der volle Text liegt auf der Platte).
    static var toolOutputLines: Int {
        get { defaults.object(forKey: "savings.toolLines") as? Int ?? 400 }
        set { defaults.set(newValue, forKey: "savings.toolLines") }
    }

    static var toolOutputBytes: Int { toolOutputLines * 60 }

    // MARK: Günstiges Zeitfenster

    /// Beginn und Ende des günstigen Tarifs in Minuten nach Mitternacht (Ortszeit).
    /// Vorgabe: DeepSeeks Nebenzeit 16:30–00:30 UTC, in Mitteleuropa (Sommerzeit) 18:30–02:30.
    static var offPeakStart: Int {
        get { defaults.object(forKey: "savings.offPeakStart") as? Int ?? 18 * 60 + 30 }
        set { defaults.set(newValue, forKey: "savings.offPeakStart") }
    }

    static var offPeakEnd: Int {
        get { defaults.object(forKey: "savings.offPeakEnd") as? Int ?? 2 * 60 + 30 }
        set { defaults.set(newValue, forKey: "savings.offPeakEnd") }
    }

    static func isOffPeak(_ date: Date = .now) -> Bool {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return offPeakStart <= offPeakEnd
            ? (offPeakStart..<offPeakEnd).contains(minute)
            : minute >= offPeakStart || minute < offPeakEnd
    }

    /// Nächster Beginn des günstigen Tarifs – `nil`, wenn er gerade gilt.
    static func nextOffPeakStart(after date: Date = .now) -> Date? {
        guard !isOffPeak(date) else { return nil }
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: offPeakStart / 60, minute: offPeakStart % 60, second: 0, of: date) ?? date
        return start > date ? start : calendar.date(byAdding: .day, value: 1, to: start)
    }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// Anbieter, die einen günstigen Nachttarif haben.
    static func hasOffPeakPricing(_ model: String) -> Bool { model.hasPrefix("deepseek/") }
}

/// Wie gründlich ein Modell nachdenken soll. Wird auf die Stufen abgebildet, die das Modell anbietet.
enum Effort: String, CaseIterable, Codable, Sendable {
    case low, medium, high

    var title: String {
        switch self {
        case .low: "wenig"
        case .medium: "mittel"
        case .high: "viel"
        }
    }

    /// Passende Variante des Modells oder `nil` (dann gilt die Standardeinstellung des Modells).
    func variant(for model: ModelInfo?) -> String? {
        let names = Set(model?.variantNames ?? [])
        guard !names.isEmpty else { return nil }
        let preferred: [String] = switch self {
        case .low: ["low", "minimal", "none"]
        // Ohne eigene Mittelstufe bleibt es bei der Standardeinstellung des Modells.
        case .medium: ["medium"]
        case .high: ["high"]
        }
        return preferred.first(where: names.contains)
    }
}

// MARK: Regelprüfung

/// Prüft Vorschläge der Zentrale gegen die Sparregeln – und korrigiert, was sich sicher korrigieren lässt.
enum RuleCheck {
    struct Result: Identifiable, Hashable {
        var title: String
        var ok: Bool
        var detail: String
        var id: String { title }
    }

    static func check(_ proposal: Proposal, entries: [ModelCatalog.Entry], budget: Double?, estimate: Double? = nil) -> [Result] {
        guard proposal.dispatch, !proposal.tasks.isEmpty else { return [] }
        let byLabel = Dictionary(entries.map { ($0.selection.label, $0) }, uniquingKeysWith: { a, _ in a })
        var results: [Result] = []

        let unknown = proposal.tasks.filter { byLabel[$0.model] == nil }.map(\.model)
        results.append(Result(title: "Verfügbare Modelle", ok: unknown.isEmpty,
                              detail: unknown.isEmpty ? "Alle Modelle sind verbunden." : "Nicht verbunden: " + unknown.joined(separator: ", ")))

        let noTools = proposal.tasks.filter { byLabel[$0.model].map { !$0.model.supportsTools } ?? false }.map(\.title)
        results.append(Result(title: "Werkzeuge", ok: noTools.isEmpty,
                              detail: noTools.isEmpty ? "Jedes Modell kann Dateien bearbeiten und bauen." : "Ohne Werkzeuge: " + noTools.joined(separator: ", ")))

        if Savings.cascade {
            // Teuer ohne Grund: ein Auftrag startet mit einem Modell, das deutlich über dem günstigsten fähigen liegt,
            // und hat keine Stufe darüber – dann wurde nicht „günstig zuerst“ gewählt.
            let cheapest = entries.filter(\.model.supportsTools).map(\.blendedPrice).filter { $0 > 0 }.min() ?? 0
            let expensive = proposal.tasks.filter { task in
                guard let entry = byLabel[task.model], cheapest > 0 else { return false }
                return entry.blendedPrice > cheapest * 8 && task.escalateTo == nil
            }
            results.append(Result(title: "Günstig zuerst", ok: expensive.isEmpty,
                                  detail: expensive.isEmpty
                                    ? "Günstiges Startmodell, stärkeres nur bei Fehlschlag."
                                    : "Teures Startmodell ohne Stufe: " + expensive.map(\.title).joined(separator: ", ")))
        }

        if let budget, let cost = estimate ?? proposal.estimatedCostUSD {
            let ok = cost <= budget * 0.7
            results.append(Result(title: "Budget", ok: ok,
                                  detail: "Schätzung \(Money.format(cost)) von \(Money.format(budget)) (Regel: höchstens 70 %)."))
        }

        let noEffort = proposal.tasks.filter { $0.effort == nil }.count
        results.append(Result(title: "Denkaufwand", ok: noEffort == 0,
                              detail: noEffort == 0 ? "Für jeden Auftrag festgelegt." : "Fehlt bei \(noEffort) Auftrag/Aufträgen – es wird „mittel“ genommen."))
        return results
    }

    /// Korrigiert sicher Korrigierbares: unbekannte oder werkzeuglose Modelle → günstigstes fähiges Modell,
    /// unbekannte Eskalationsstufe → stärkstes verbundene Modell, fehlender Denkaufwand → mittel.
    static func fix(_ proposal: Proposal, entries: [ModelCatalog.Entry]) -> Proposal {
        var fixed = proposal
        let capable = entries.filter(\.model.supportsTools).filter { $0.blendedPrice > 0 }.sorted { $0.blendedPrice < $1.blendedPrice }
        let byLabel = Dictionary(entries.map { ($0.selection.label, $0) }, uniquingKeysWith: { a, _ in a })
        for index in fixed.tasks.indices {
            if byLabel[fixed.tasks[index].model].map({ !$0.model.supportsTools }) ?? true, let cheapest = capable.first {
                fixed.tasks[index].model = cheapest.selection.label
            }
            if let escalate = fixed.tasks[index].escalateTo {
                let valid = byLabel[escalate].map(\.model.supportsTools) ?? false
                if !valid || escalate == fixed.tasks[index].model { fixed.tasks[index].escalateTo = nil }
            }
            if fixed.tasks[index].effort == nil { fixed.tasks[index].effort = .medium }
        }
        return fixed
    }
}
