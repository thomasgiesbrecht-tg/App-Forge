import Foundation

/// Kosteneinschätzung vor dem Start – gerechnet, nicht geraten und ohne KI (kostet also nichts).
/// Grundlage: Preise des gewählten Modells, bisherige Aufträge desselben Agenten (Tokenmenge),
/// die gemessene Zwischenspeicher-Quote des Modells und die Wahrscheinlichkeit einer Übergabe.
struct CostEstimate: Hashable, Sendable {
    /// Erwartete Kosten in US-Dollar.
    var expected: Double
    var low: Double
    var high: Double
    /// Woher die Tokenmenge stammt – für die Anzeige.
    var basis: String
    /// Anteil, der auf eine mögliche Übergabe an das stärkere Modell entfällt.
    var escalation: Double

    static func + (a: CostEstimate, b: CostEstimate) -> CostEstimate {
        CostEstimate(expected: a.expected + b.expected, low: a.low + b.low, high: a.high + b.high,
                     basis: a.basis, escalation: a.escalation + b.escalation)
    }

    /// „≈ 0,05 € (0,02–0,11 €)“
    var label: String { "≈ \(Money.format(expected)) (\(Money.format(low))–\(Money.format(high)))" }
}

enum CostEstimator {
    /// Eingabe-Tokens (inkl. Zwischenspeicher) je Auftrag, wenn es noch keine eigenen Erfahrungswerte gibt.
    /// Entspricht den Richtwerten, mit denen auch die Zentrale rechnet.
    static func typicalTokens(_ effort: Effort) -> Double {
        switch effort {
        case .low: 150_000
        case .medium: 600_000
        case .high: 2_000_000
        }
    }

    /// Ausgabe als Anteil der Eingabe (Agenten lesen viel und schreiben wenig).
    private static let outputShare = 0.07

    static func estimate(_ task: Proposal.TaskPlan, entries: [ModelCatalog.Entry], missions: [Mission]) -> CostEstimate? {
        guard let entry = entries.first(where: { $0.selection.label == task.model }), let cost = entry.model.cost else { return nil }

        // Tokenmenge: Median bisheriger erfolgreicher Aufträge dieses Agenten, sonst Richtwert nach Denkaufwand
        let history = missions
            .filter { $0.agent == task.agent && $0.state == .done }
            .compactMap { m -> Double? in
                guard let input = m.inputTokens else { return nil }
                return input + (m.cachedTokens ?? 0)
            }
            .sorted()
        let tokens: Double
        let basis: String
        if history.count >= 2 {
            tokens = history[history.count / 2]
            basis = "aus \(history.count) bisherigen Aufträgen von \(task.agent)"
        } else {
            let effort = task.effort ?? .medium
            tokens = typicalTokens(effort)
            basis = "Richtwert für Denkaufwand „\(effort.title)“"
        }

        let experience = ModelCatalog.experience(from: missions)
        let own = experience[task.model]
        let base = price(tokens: tokens, cost: cost, cacheRate: cacheRate(own, cost: cost))

        // Mögliche Übergabe: Wahrscheinlichkeit × Kosten des stärkeren Modells für den Rest der Arbeit
        var escalation = 0.0
        if Savings.cascade, let stronger = task.escalateTo,
           let strongEntry = entries.first(where: { $0.selection.label == stronger }), let strongCost = strongEntry.model.cost {
            let probability = own.flatMap { $0.runs >= 3 ? Double($0.escalated) / Double($0.runs) : nil } ?? 0.25
            let rest = price(tokens: tokens * 0.4, cost: strongCost, cacheRate: cacheRate(experience[stronger], cost: strongCost))
            escalation = probability * rest
            let expected = base + escalation
            return CostEstimate(expected: expected, low: base * 0.5, high: base * 2 + rest, basis: basis, escalation: escalation)
        }
        return CostEstimate(expected: base, low: base * 0.5, high: base * 2, basis: basis, escalation: 0)
    }

    static func total(_ proposal: Proposal, entries: [ModelCatalog.Entry], missions: [Mission]) -> CostEstimate? {
        let parts = proposal.tasks.compactMap { estimate($0, entries: entries, missions: missions) }
        guard parts.count == proposal.tasks.count, let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first, +)
    }

    /// Gemessene Quote des Modells – sonst 50 %, wenn der Anbieter Zwischenspeicher-Preise hat.
    private static func cacheRate(_ experience: ModelCatalog.Experience?, cost: ModelInfo.Cost) -> Double {
        if let measured = experience?.cacheRate { return measured }
        return cost.cache != nil ? 0.5 : 0
    }

    private static func price(tokens: Double, cost: ModelInfo.Cost, cacheRate: Double) -> Double {
        let cachedPrice = cost.cache?.read ?? cost.input
        let input = tokens * ((1 - cacheRate) * cost.input + cacheRate * cachedPrice)
        let output = tokens * outputShare * cost.output
        return (input + output) / 1_000_000
    }
}
