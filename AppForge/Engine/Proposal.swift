import Foundation

/// Vorschlag der Zentrale, aus ihrer JSON-Antwort gelesen.
/// Ein Vorschlag besteht aus einem oder mehreren Teilaufträgen, die parallel oder nacheinander laufen.
struct Proposal: Hashable, Sendable {
    struct Alternative: Hashable, Sendable {
        var model: String
        var estimatedCostUSD: Double?
        var note: String?
    }

    /// Ein Teilauftrag für genau einen Agenten.
    struct TaskPlan: Hashable, Sendable, Identifiable {
        var id: Int
        var title: String
        var agent: String
        var model: String
        var prompt: String
        var estimatedCostUSD: Double?
        /// Indizes der Teilaufträge, die vorher fertig sein müssen.
        var dependsOn: [Int] = []
    }

    var reply: String
    var dispatch: Bool
    var title: String?
    var analysis: String?
    var reason: String?
    var estimatedCostUSD: Double?
    var estimatedMinutes: Double?
    var budgetUSD: Double?
    var timeLimitMinutes: Double?
    var alternatives: [Alternative] = []
    var tasks: [TaskPlan] = []

    /// Liest das JSON-Objekt aus dem Antworttext (auch in ```json-Blöcken). `nil`, wenn keins gefunden wurde.
    static func parse(_ text: String) -> Proposal? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text[start...end].utf8))
        else { return nil }

        func string(_ value: JSONValue?) -> String? {
            guard let text = value?.stringValue, !text.isEmpty, text != "null" else { return nil }
            return text
        }
        func number(_ value: JSONValue?) -> Double? {
            switch value {
            case .number(let n): n
            case .string(let s): Double(s.replacingOccurrences(of: ",", with: ".").filter { "0123456789.".contains($0) })
            default: nil
            }
        }

        var proposal = Proposal(
            reply: string(json["reply"]) ?? "",
            dispatch: json["dispatch"] == .bool(true) || string(json["dispatch"]) == "true",
            title: string(json["title"]), analysis: string(json["analysis"]), reason: string(json["reason"]),
            estimatedCostUSD: number(json["estimatedCostUSD"]), estimatedMinutes: number(json["estimatedMinutes"]),
            budgetUSD: number(json["budgetUSD"]), timeLimitMinutes: number(json["timeLimitMinutes"])
        )

        if case .array(let items) = json["alternatives"] {
            proposal.alternatives = items.compactMap { item in
                guard let model = string(item["model"]) else { return nil }
                return Alternative(model: model, estimatedCostUSD: number(item["estimatedCostUSD"]), note: string(item["note"]))
            }
        }

        // Mehrere Teilaufträge …
        if case .array(let items) = json["tasks"] {
            proposal.tasks = items.enumerated().compactMap { index, item in
                guard let prompt = string(item["prompt"]) ?? string(item["optimizedPrompt"]),
                      let model = string(item["model"]) else { return nil }
                var dependsOn: [Int] = []
                if case .array(let deps) = item["dependsOn"] {
                    dependsOn = deps.compactMap { number($0).map(Int.init) }.filter { $0 >= 0 && $0 != index }
                }
                return TaskPlan(
                    id: index, title: string(item["title"]) ?? "Teil \(index + 1)",
                    agent: string(item["agent"]) ?? "build", model: model, prompt: prompt,
                    estimatedCostUSD: number(item["estimatedCostUSD"]), dependsOn: dependsOn
                )
            }
            // Abhängigkeiten auf vorhandene Teilaufträge beschränken
            let valid = Set(proposal.tasks.map(\.id))
            for i in proposal.tasks.indices { proposal.tasks[i].dependsOn = proposal.tasks[i].dependsOn.filter(valid.contains) }
        }
        // … oder ein einzelner Auftrag im alten Format
        if proposal.tasks.isEmpty, let prompt = string(json["optimizedPrompt"]), let model = string(json["model"]) {
            proposal.tasks = [TaskPlan(
                id: 0, title: proposal.title ?? "Auftrag", agent: string(json["agent"]) ?? "build",
                model: model, prompt: prompt, estimatedCostUSD: proposal.estimatedCostUSD
            )]
        }

        if proposal.dispatch && proposal.tasks.isEmpty { proposal.dispatch = false }
        if proposal.estimatedCostUSD == nil {
            let sum = proposal.tasks.compactMap(\.estimatedCostUSD).reduce(0, +)
            if sum > 0 { proposal.estimatedCostUSD = sum }
        }
        return proposal
    }
}
