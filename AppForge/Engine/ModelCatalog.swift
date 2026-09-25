import Foundation

/// Das Wissen der Zentrale über alle verbundenen Modelle: Preise, Fähigkeiten, Stärken und eigene Erfahrungen.
enum ModelCatalog {
    struct Entry: Sendable {
        let selection: ModelSelection
        let model: ModelInfo
        let providerName: String

        var inputPrice: Double { model.cost?.input ?? 0 }
        var outputPrice: Double { model.cost?.output ?? 0 }
        /// Grobe Kennzahl für „günstig“: typischer Agenten-Mix aus viel Eingabe, wenig Ausgabe.
        var blendedPrice: Double { inputPrice * 0.9 + outputPrice * 0.1 }
    }

    /// Anbieter mit sehr vielen Modellen (z. B. OpenRouter) werden auf die neuesten begrenzt.
    private static let perProviderLimit = 14

    static func entries(from providers: ProviderList?) -> [Entry] {
        guard let providers else { return [] }
        return providers.all
            .filter { providers.connected.contains($0.id) }
            .flatMap { provider in
                provider.models.values
                    // OpenCodes Gratis-Modelle funktionieren nur mit OpenCodes eigenen Agenten – für Aufträge ungeeignet.
                    .filter { $0.status != "deprecated" && !(provider.id == "opencode" && ($0.cost?.input ?? 0) == 0) }
                    .sorted { ($0.release_date ?? "") > ($1.release_date ?? "") }
                    .prefix(perProviderLimit)
                    .map { Entry(selection: ModelSelection(providerID: provider.id, modelID: $0.id), model: $0, providerName: provider.name) }
            }
    }

    /// Günstigstes bezahltes Modell – Vorschlag für die Zentrale selbst.
    static func cheapest(from providers: ProviderList?) -> ModelSelection? {
        let all = entries(from: providers)
        let paid = all.filter { $0.blendedPrice > 0 }.sorted { $0.blendedPrice < $1.blendedPrice }
        return (paid.first ?? all.first)?.selection
    }

    // MARK: Text für den Dispatcher

    static func describe(_ entries: [Entry], experience: [String: Experience]) -> String {
        entries
            .sorted { $0.blendedPrice < $1.blendedPrice }
            .map { entry in
                let m = entry.model
                var items = [
                    "\(entry.selection.label) (\(m.name))",
                    "Eingabe \(price(entry.inputPrice)) / Ausgabe \(price(entry.outputPrice)) je 1 Mio. Tokens",
                ]
                if let context = m.limit?.context, context > 0 { items.append("Kontext \(Int(context / 1000))k") }
                var abilities: [String] = []
                abilities.append(m.supportsTools ? "Werkzeuge" : "KEINE Werkzeuge")
                if m.supportsImages { abilities.append("Bilder") }
                if m.capabilities?.reasoning == true { abilities.append("Reasoning") }
                items.append(abilities.joined(separator: ", "))
                if let strengths = strengths(of: m) { items.append("Stärken: \(strengths)") }
                if let date = m.release_date { items.append("seit \(date)") }
                if let exp = experience[entry.selection.label] { items.append("Erfahrung: \(exp.summary)") }
                return "- " + items.joined(separator: " | ")
            }
            .joined(separator: "\n")
    }

    private static func price(_ value: Double) -> String {
        value == 0 ? "kostenlos/unbekannt" : String(format: "$%.2f", value)
    }

    /// Kurze, redaktionelle Stärken-Hinweise nach Modellfamilie. Die Zentrale ergänzt sie mit eigenem Wissen.
    static func strengths(of model: ModelInfo) -> String? {
        let key = (model.id + " " + model.name + " " + (model.family ?? "")).lowercased()
        let table: [(String, String)] = [
            ("opus", "stärkstes Modell für komplexes Coding, Architektur und lange Agenten-Aufgaben; teuer"),
            ("sonnet", "sehr starkes Coding und Agentenarbeit, gutes Preis-Leistungs-Verhältnis"),
            ("haiku", "schnell und günstig, gut für einfache Code- und Textaufgaben"),
            ("fable", "Anthropic-Modell, stark in Coding und Agentenarbeit"),
            ("codex", "auf Coding und Agenten-Workflows spezialisiert"),
            ("gpt-5", "stark in Reasoning, Planung und Code"),
            ("mini", "günstige Variante für einfache, klar umrissene Aufgaben"),
            ("nano", "sehr günstig, nur für einfache Aufgaben"),
            ("o3", "tiefes Reasoning, gut für knifflige Fehler und Planung"),
            ("o4", "tiefes Reasoning, gut für knifflige Fehler und Planung"),
            ("gemini", "sehr langer Kontext, starkes Bild- und Dokumentverständnis"),
            ("flash", "sehr schnell und günstig"),
            ("deepseek", "sehr günstig, solides Coding"),
            ("grok", "stark in Reasoning und Code"),
            ("codestral", "auf Code spezialisiert, günstig"),
            ("devstral", "auf Agenten-Coding spezialisiert, günstig"),
            ("mistral", "europäisch, günstig, gut für Text und einfachen Code"),
            ("qwen", "günstig, gutes Coding"),
            ("kimi", "starke Agentenarbeit, langer Kontext, günstig"),
            ("glm", "günstig, gutes Agenten-Coding"),
            ("llama", "offenes Modell, für einfache Aufgaben"),
        ]
        let hits = table.filter { key.contains($0.0) }.map(\.1)
        return hits.isEmpty ? nil : hits.prefix(2).joined(separator: "; ")
    }

    // MARK: Erfahrung aus bisherigen Aufträgen

    struct Experience: Sendable {
        var runs = 0
        /// Allein geschafft – ohne Übergabe an ein stärkeres Modell.
        var succeeded = 0
        /// Musste an ein stärkeres Modell übergeben.
        var escalated = 0
        var totalCost = 0.0
        var inputTokens = 0.0
        var cachedTokens = 0.0

        var averageCost: Double { runs > 0 ? totalCost / Double(runs) : 0 }
        var cacheRate: Double? { inputTokens + cachedTokens > 0 ? cachedTokens / (inputTokens + cachedTokens) : nil }

        var summary: String {
            var text = "\(runs) Aufträge, \(succeeded) allein geschafft"
            if escalated > 0 { text += ", \(escalated)× übergeben" }
            text += ", Ø \(Money.format(averageCost))"
            if let cacheRate { text += ", Zwischenspeicher \(Int(cacheRate * 100)) %" }
            return text
        }
    }

    static func experience(from missions: [Mission]) -> [String: Experience] {
        var result: [String: Experience] = [:]
        for mission in missions where mission.state.isFinished && mission.state != .cancelled {
            var exp = result[mission.model, default: Experience()]
            exp.runs += 1
            if mission.state == .done && mission.escalatedModel == nil { exp.succeeded += 1 }
            if mission.escalatedModel != nil { exp.escalated += 1 }
            exp.totalCost += mission.spentUSD
            exp.inputTokens += mission.inputTokens ?? 0
            exp.cachedTokens += mission.cachedTokens ?? 0
            result[mission.model] = exp
        }
        return result
    }
}
