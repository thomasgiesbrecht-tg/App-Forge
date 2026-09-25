import Foundation
import Observation

/// Ein von der Zentrale gestarteter Auftrag mit Budget- und Zeitgrenze.
struct Mission: Codable, Identifiable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case waiting, running, wrappingUp, done, stoppedBudget, stoppedTime, failed, cancelled

        var isFinished: Bool { self != .running && self != .wrappingUp && self != .waiting }

        var title: String {
            switch self {
            case .waiting: "wartet"
            case .running: "läuft"
            case .wrappingUp: "schließt ab"
            case .done: "fertig"
            case .stoppedBudget: "Budget erreicht"
            case .stoppedTime: "Zeit abgelaufen"
            case .failed: "fehlgeschlagen"
            case .cancelled: "gestoppt"
            }
        }
    }

    var id = UUID()
    var title: String
    var task: String
    var prompt: String
    var model: String
    var agent: String
    var directory: String
    var sessionID: String
    var budgetUSD: Double?
    var timeLimitMinutes: Double?
    var estimatedCostUSD: Double?
    var startedAt = Date()
    var endedAt: Date?
    var spentUSD = 0.0
    var state = State.running
    var wrapUpSent = false
    /// Teilaufträge eines Vorschlags teilen sich eine Gruppe.
    var groupID: UUID?
    /// Aufträge, die vorher fertig sein müssen.
    var dependsOn: [UUID]?
    /// Was der Agent gerade tut – kurz, für die Live-Ansicht.
    var activity: String?
    var subagents: [SubagentSnapshot]?
    /// Dateien, Build/Tests, Fortschritt, Kontext – aus dem letzten Überwachungsdurchlauf.
    var insights: MissionInsights?

    // Sparregeln (optional, damit ältere gespeicherte Aufträge lesbar bleiben)
    var effort: Effort?
    /// Stärkeres Modell für den Fall, dass Build oder Tests scheitern.
    var escalateTo: String?
    /// Gesetzt, sobald das stärkere Modell übernommen hat.
    var escalatedModel: String?
    /// Prüfschritt („bitte bauen“) wurde schon verlangt.
    var verifySent: Bool?
    /// Frühester Start (günstiger Tarif).
    var notBefore: Date?
    /// Zeitpunkt der letzten Nachricht von AppForge an den Agenten (Prüfschritt, Stufe, Abschluss).
    var followUpAt: Date?
    /// Immer derselbe Systemhinweis für diese Sitzung – sonst verfällt der Zwischenspeicher des Anbieters.
    var systemHint: String?
    /// Eingabe-Tokens insgesamt und davon aus dem Zwischenspeicher gelesen.
    var inputTokens: Double?
    var cachedTokens: Double?

    var activeModel: String { escalatedModel ?? model }
    var cacheRate: Double? {
        guard let inputTokens, let cachedTokens, inputTokens + cachedTokens > 0 else { return nil }
        return cachedTokens / (inputTokens + cachedTokens)
    }

    var projectName: String { URL(filePath: directory).lastPathComponent }
    var elapsed: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    var budgetFraction: Double? { budgetUSD.map { $0 > 0 ? spentUSD / $0 : 0 } }
    var timeFraction: Double? { timeLimitMinutes.map { $0 > 0 ? elapsed / ($0 * 60) : 0 } }
}

/// Eintrag im Ereignisticker der Live-Ansicht.
struct MissionEvent: Identifiable, Hashable, Sendable {
    /// attention = du musst etwas tun (orange) · problem = Fehler oder Abbruch (rot)
    enum Tone: Sendable { case neutral, good, attention, problem }
    let id = UUID()
    let date = Date()
    var source: String
    var text: String
    var tone: Tone
}

/// Stand eines Unteragenten, den ein Auftrag beauftragt hat.
struct SubagentSnapshot: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var task: String
    var status: String
    var activity: String?
    var childSessionID: String?

    var id: String { childSessionID ?? name + task }
}

/// Die Zentrale: ein günstiges Modell, das Aufgaben analysiert, Prompts optimiert, Modelle wählt,
/// Aufträge startet und Kosten und Zeit überwacht.
@MainActor
@Observable
final class Dispatcher {
    @ObservationIgnored weak var store: AppStore?

    // Einstellungen
    var routerModel: ModelSelection? { didSet { save(routerModel, "dispatcher.model") } }
    var budgetUSD: Double? { didSet { save(budgetUSD, "dispatcher.budget") } }
    var timeLimitMinutes: Double? { didSet { save(timeLimitMinutes, "dispatcher.time") } }
    var autoStart: Bool = UserDefaults.standard.bool(forKey: "dispatcher.autoStart") {
        didSet { UserDefaults.standard.set(autoStart, forKey: "dispatcher.autoStart") }
    }

    // Gespräch
    private(set) var sessionID: String? = UserDefaults.standard.string(forKey: "dispatcher.session") {
        didSet { UserDefaults.standard.set(sessionID, forKey: "dispatcher.session") }
    }
    private(set) var messages: [ChatMessage] = []
    private(set) var isThinking = false
    var error: String?
    /// Vom Nutzer bearbeitete Vorschläge (Prompt/Modell), je Antwort-ID.
    var edits: [String: Proposal] = [:]
    /// Antworten, deren Vorschlag schon gestartet wurde.
    private(set) var launched: Set<String> = []

    // Aufträge
    private(set) var missions: [Mission] = []
    /// In der Live-Ansicht angeklickter Agent – links erscheinen dann seine Gedanken.
    var focus: ThoughtFocus?
    /// Die letzten Ereignisse, neueste zuerst.
    private(set) var events: [MissionEvent] = []
    @ObservationIgnored private var reportedConflicts: Set<String> = []

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    static var directory: URL { EngineConfig.supportDirectory.appending(path: "zentrale", directoryHint: .isDirectory) }

    init() {
        routerModel = load("dispatcher.model")
        budgetUSD = load("dispatcher.budget")
        timeLimitMinutes = load("dispatcher.time")
        missions = load("dispatcher.missions") ?? []
        launched = Set(UserDefaults.standard.stringArray(forKey: "dispatcher.launched") ?? [])
    }

    // MARK: Ereignisse

    func log(_ source: String, _ text: String, _ tone: MissionEvent.Tone = .neutral) {
        events.insert(MissionEvent(source: source, text: text, tone: tone), at: 0)
        if events.count > 40 { events.removeLast(events.count - 40) }
    }

    /// Zu welchem Auftrag gehört eine Sitzung (auch Unteragenten-Sitzungen über ihre Wurzel)?
    func mission(forRootSession sessionID: String) -> Mission? {
        missions.first { $0.sessionID == sessionID }
    }

    // MARK: Abgeleitet

    var runningMissions: [Mission] { missions.filter { !$0.state.isFinished } }

    /// Kosten der Zentrale selbst (ihre eigenen Antworten).
    var ownCost: Double { messages.compactMap(\.info.cost).reduce(0, +) }

    var spentToday: Double {
        let today = Calendar.current.startOfDay(for: .now)
        return missions.filter { $0.startedAt >= today }.map(\.spentUSD).reduce(0, +) + ownCost
    }

    var effectiveRouterModel: ModelSelection? { routerModel ?? ModelCatalog.cheapest(from: store?.providers) }

    func proposal(for message: ChatMessage) -> Proposal? {
        if let edited = edits[message.id] { return edited }
        return Proposal.parse(text(of: message))
    }

    func text(of message: ChatMessage) -> String {
        let text = message.parts.filter { $0.type == "text" && $0.synthetic != true }.compactMap(\.text).joined(separator: "\n")
        return message.info.isUser ? Self.stripSituation(text) : text
    }

    static let situationStart = "⟦Lage⟧"
    static let situationEnd = "⟦/Lage⟧"

    /// Der Lage-Block steht für die Zentrale vor jeder Nutzernachricht – angezeigt wird nur, was du geschrieben hast.
    static func stripSituation(_ text: String) -> String {
        guard text.hasPrefix(situationStart), let end = text.range(of: situationEnd) else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func modelInfo(_ label: String) -> ModelInfo? {
        let parts = label.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return store?.providers?.all.first { $0.id == parts[0] }?.models[parts[1]]
    }

    private func selection(_ label: String) -> ModelSelection? {
        let parts = label.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? ModelSelection(providerID: parts[0], modelID: parts[1]) : nil
    }

    // MARK: Start

    func start() async {
        guard let client = store?.client else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let directory = Self.directory.path
        subscribe(client: client, directory: directory)
        if let sessionID, let envelopes = try? await client.messages(sessionID: sessionID, directory: directory) {
            messages = envelopes.map { ChatMessage(info: $0.info, parts: $0.parts) }
        } else {
            sessionID = nil
            messages = []
        }
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.monitorMissions()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func newConversation() {
        sessionID = nil
        messages = []
        edits = [:]
        error = nil
    }

    // MARK: Gespräch

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = store?.client else { return }
        let directory = Self.directory.path
        error = nil
        do {
            if sessionID == nil {
                sessionID = try await client.createSession(directory: directory, title: "Zentrale").id
            }
            guard let sessionID else { return }
            isThinking = true
            let router = effectiveRouterModel
            try await client.prompt(
                sessionID: sessionID, directory: directory,
                text: "\(Self.situationStart)\n\(situation())\n\(Self.situationEnd)\n\n\(trimmed)",
                model: router, agent: "dispatcher", system: stableContext(),
                variant: Effort.low.variant(for: router.flatMap { modelInfo($0.label) })
            )
        } catch {
            isThinking = false
            self.error = error.localizedDescription
        }
    }

    /// Was sich selten ändert – Agenten und Modelle mit Preisen. Steht im Systemteil und bleibt dadurch
    /// von Nachricht zu Nachricht gleich, sodass der Anbieter den ganzen Verlauf zwischenspeichern kann.
    private func stableContext() -> String {
        guard let store else { return "" }
        let agents = store.agents.filter { $0.isPrimary && $0.isVisible }
            .map { "- \($0.name): \($0.description ?? $0.displayName)" }.joined(separator: "\n")
        let subagents = store.subagents.map { "- \($0.name): \($0.description ?? "")" }.joined(separator: "\n")
        let catalog = ModelCatalog.describe(ModelCatalog.entries(from: store.providers), experience: [:])
        return """
        # Ausstattung (von AppForge)

        ## Agenten (Feld "agent")
        \(agents)

        ## Unteragenten (werden vom Koordinator beauftragt)
        \(subagents.isEmpty ? "- keine" : subagents)

        ## Verfügbare Modelle (Feld "model" und "escalateTo", günstigste zuerst)
        \(catalog.isEmpty ? "- keine verbunden" : catalog)
        """
    }

    /// Was sich ständig ändert – Projekt, Grenzen, Ausgaben, Erfahrungen. Steht als Lage-Block vor der Nutzernachricht.
    private func situation() -> String {
        guard let store else { return "" }
        let project = store.selectedProject.map { URL(filePath: $0).lastPathComponent } ?? "keins geöffnet"
        let budget = budgetUSD.map { String(format: "max. $%.2f pro Auftrag (%@)", $0, Money.format($0)) } ?? "kein festes Budget – trotzdem sparsam"
        let time = timeLimitMinutes.map { "max. \(Int($0)) Minuten pro Auftrag" } ?? "kein Zeitlimit"
        let experience = ModelCatalog.experience(from: missions)
            .sorted { $0.value.runs > $1.value.runs }.prefix(8)
            .map { "- \($0.key): \($0.value.summary)" }.joined(separator: "\n")
        let offPeak = Savings.isOffPeak() ? "gilt gerade" : "ab \(Savings.clock(Savings.offPeakStart)) Uhr"
        return """
        Projekt: \(project) · Zielplattform: \(store.platform.title)
        Budget: \(budget) · Zeit: \(time)
        Heute ausgegeben: \(Money.format(spentToday)) · Nachttarif DeepSeek: \(offPeak)
        Kurs: 1 $ = \(String(format: "%.3f", Money.eurPerUsd)) € – dem Nutzer Beträge immer in Euro nennen, JSON-Felder in US-Dollar
        Stufen (günstig zuerst): \(Savings.cascade ? "an" : "aus")
        Erfahrungen:
        \(experience.isEmpty ? "- noch keine" : experience)
        """
    }

    // MARK: Aufträge

    /// Startet alle Teilaufträge eines Vorschlags. Unabhängige laufen sofort parallel,
    /// abhängige warten, bis ihre Vorgänger fertig sind.
    func launch(_ original: Proposal, from messageID: String, waitForOffPeak: Bool = false) async {
        guard let store, store.client != nil, let directory = store.selectedProject else {
            error = "Kein Projekt geöffnet – öffne links ein Projekt, damit die Aufträge dort arbeiten können."
            return
        }
        guard !original.tasks.isEmpty else { return }
        // Regeln durchsetzen: unbekannte/werkzeuglose Modelle ersetzen, Denkaufwand ergänzen
        let proposal = RuleCheck.fix(original, entries: ModelCatalog.entries(from: store.providers))
        let notBefore = waitForOffPeak ? Savings.nextOffPeakStart() : nil
        let groupID = UUID()
        let ids = proposal.tasks.map { _ in UUID() }

        // Budget nach geschätzten Kosten aufteilen (sonst gleichmäßig)
        let totalBudget = budgetUSD ?? proposal.budgetUSD
        let estimates = proposal.tasks.map { $0.estimatedCostUSD ?? 0 }
        let estimateSum = estimates.reduce(0, +)
        func share(_ index: Int) -> Double? {
            guard let totalBudget else { return nil }
            return estimateSum > 0 ? totalBudget * estimates[index] / estimateSum : totalBudget / Double(proposal.tasks.count)
        }

        var created: [Mission] = []
        for (index, task) in proposal.tasks.enumerated() {
            let agent = store.agents.contains { $0.name == task.agent && $0.isPrimary } ? task.agent : "build"
            created.append(Mission(
                id: ids[index], title: task.title, task: proposal.analysis ?? task.title, prompt: task.prompt,
                model: task.model, agent: agent, directory: directory, sessionID: "",
                budgetUSD: share(index), timeLimitMinutes: timeLimitMinutes ?? proposal.timeLimitMinutes,
                estimatedCostUSD: task.estimatedCostUSD, state: .waiting,
                groupID: groupID, dependsOn: task.dependsOn.map { ids[$0] },
                effort: task.effort, escalateTo: Savings.cascade ? task.escalateTo : nil, notBefore: notBefore
            ))
        }
        missions.insert(contentsOf: created, at: 0)
        launched.insert(messageID)
        UserDefaults.standard.set(Array(launched), forKey: "dispatcher.launched")
        persistMissions()

        if let notBefore {
            log(proposal.title ?? "Auftrag", "wartet auf den Nachttarif · Start \(notBefore.formatted(date: .omitted, time: .shortened))")
            return
        }
        for mission in created where (mission.dependsOn ?? []).isEmpty {
            await start(mission.id)
        }
    }

    /// Legt die Sitzung eines wartenden Auftrags an und schickt den Prompt ab.
    private func start(_ id: UUID) async {
        guard let store, let client = store.client, let mission = missions.first(where: { $0.id == id }) else { return }
        let parts = mission.model.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            update(id) { $0.state = .failed; $0.activity = "unbekanntes Modell"; $0.endedAt = .now }
            return
        }

        // Ergebnisse der Vorgänger mitgeben, damit der Agent darauf aufbauen kann
        var prompt = mission.prompt
        let predecessors = missions.filter { (mission.dependsOn ?? []).contains($0.id) }
        if !predecessors.isEmpty {
            var context: [String] = []
            for predecessor in predecessors {
                let envelopes = (try? await client.messages(sessionID: predecessor.sessionID, directory: predecessor.directory)) ?? []
                let summary = envelopes.last(where: { !$0.info.isUser })
                    .map { $0.parts.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n") } ?? ""
                context.append("### \(predecessor.title) (\(predecessor.agent))\n\(String(summary.suffix(1500)))")
            }
            prompt += "\n\n---\nVorher erledigt von anderen Agenten:\n\n" + context.joined(separator: "\n\n")
        }

        do {
            let session = try await client.createSession(directory: mission.directory, title: mission.title)
            let hint = store.platform.systemHint
            try await client.prompt(sessionID: session.id, directory: mission.directory, text: prompt,
                                    model: ModelSelection(providerID: parts[0], modelID: parts[1]),
                                    agent: mission.agent, system: hint,
                                    variant: (mission.effort ?? .medium).variant(for: modelInfo(mission.model)))
            update(id) {
                $0.systemHint = hint
                $0.sessionID = session.id
                $0.state = .running
                $0.startedAt = .now
                $0.activity = "liest sich ein"
            }
            log(mission.title, "gestartet · \(mission.agent)")
        } catch {
            update(id) { $0.state = .failed; $0.activity = error.localizedDescription; $0.endedAt = .now }
        }
    }

    func stop(_ mission: Mission) async {
        guard let client = store?.client else { return }
        if !mission.sessionID.isEmpty {
            try? await client.abort(sessionID: mission.sessionID, directory: mission.directory)
        }
        update(mission.id) { $0.state = .cancelled; $0.endedAt = .now }
    }

    func remove(_ mission: Mission) {
        missions.removeAll { $0.id == mission.id }
        persistMissions()
    }

    /// Prüft laufende Aufträge: Kosten (inkl. Unteragenten), Zeit, Fertigstellung.
    private func monitorMissions() async {
        guard let client = store?.client else { return }

        // Wartende: starten, sobald alle Vorgänger fertig sind – oder überspringen, wenn einer gescheitert ist
        for mission in missions where mission.state == .waiting && mission.sessionID.isEmpty {
            if let notBefore = mission.notBefore, notBefore > .now {
                update(mission.id) { $0.activity = "startet \(notBefore.formatted(date: .omitted, time: .shortened)) · Nachttarif" }
                continue
            }
            let deps = missions.filter { (mission.dependsOn ?? []).contains($0.id) }
            if deps.contains(where: { $0.state.isFinished && $0.state != .done }) {
                update(mission.id) { $0.state = .cancelled; $0.activity = "übersprungen – ein Vorgänger ist nicht fertig geworden"; $0.endedAt = .now }
                log(mission.title, "übersprungen – Vorgänger nicht fertig", .problem)
            } else if deps.allSatisfy({ $0.state == .done }) {
                await start(mission.id)
            } else {
                let open = deps.filter { !$0.state.isFinished }.map(\.title)
                update(mission.id) { $0.activity = "wartet auf " + open.joined(separator: ", ") }
            }
        }

        for mission in runningMissions where mission.state != .waiting {
            let directory = mission.directory
            let busy = ((try? await client.sessionStatus(directory: directory)) ?? [:])
            var sessionIDs = [mission.sessionID]
            if let children = try? await client.children(sessionID: mission.sessionID, directory: directory) {
                sessionIDs += children.map(\.id)
            }
            var spent = 0.0
            var inputTokens = 0.0
            var cachedTokens = 0.0
            var lastError: String?
            var answered = false
            var transcripts: [String: [ChatMessage]] = [:]
            for id in sessionIDs {
                guard let envelopes = try? await client.messages(sessionID: id, directory: directory) else { continue }
                spent += envelopes.compactMap(\.info.cost).reduce(0, +)
                for envelope in envelopes {
                    if !envelope.info.isUser { store?.ledger.record(project: directory, id: envelope.info.id, costUSD: envelope.info.cost ?? 0) }
                    inputTokens += envelope.info.tokens?.input ?? 0
                    cachedTokens += envelope.info.tokens?.cache?.read ?? 0
                }
                transcripts[id] = envelopes.map { ChatMessage(info: $0.info, parts: $0.parts) }
                // Fertig ist nur, wer zuletzt geantwortet hat – nicht, wenn AppForge gerade nachgefragt hat.
                if id == mission.sessionID, let last = envelopes.last, !last.info.isUser {
                    answered = last.info.time.completed != nil
                    if !last.info.wasAborted { lastError = last.info.errorMessage }
                }
            }
            let isBusy = sessionIDs.contains { busy[$0] != nil }
            let own = transcripts[mission.sessionID] ?? []
            let children = transcripts.filter { $0.key != mission.sessionID }.map(\.value)
            let insights = InsightExtractor.extract(main: own, children: children, contextLimit: contextLimit(for: mission.activeModel)).insights
            reportChanges(of: mission, old: mission.insights, new: insights)
            update(mission.id) {
                $0.spentUSD = spent
                $0.inputTokens = inputTokens
                $0.cachedTokens = cachedTokens
                $0.activity = ActivityDigest.activity(of: own) ?? $0.activity
                $0.subagents = ActivityDigest.subagents(in: own) { transcripts[$0] }
                $0.insights = insights
            }
            guard let current = missions.first(where: { $0.id == mission.id }) else { continue }

            // Harte Grenzen
            if let fraction = current.budgetFraction, fraction >= 1 {
                try? await client.abort(sessionID: mission.sessionID, directory: directory)
                update(mission.id) { $0.state = .stoppedBudget; $0.endedAt = .now }
                log(mission.title, "gestoppt – Budget erreicht", .problem)
                continue
            }
            if let fraction = current.timeFraction, fraction >= 1 {
                try? await client.abort(sessionID: mission.sessionID, directory: directory)
                update(mission.id) { $0.state = .stoppedTime; $0.endedAt = .now }
                log(mission.title, "gestoppt – Zeit abgelaufen", .problem)
                continue
            }

            // Kurz vor der Grenze: geordnet abschließen lassen
            let nearLimit = (current.budgetFraction ?? 0) >= 0.85 || (current.timeFraction ?? 0) >= 0.85
            if nearLimit, !current.wrapUpSent, isBusy {
                let reason = (current.budgetFraction ?? 0) >= 0.85 ? "Das Budget" : "Die Zeit"
                await followUp(current, model: current.activeModel,
                               text: "\(reason) für diesen Auftrag ist fast aufgebraucht. Beende nur noch den aktuellen Schritt, stelle sicher, dass das Projekt baut, und fasse kurz zusammen: Was ist erledigt, was ist offen? Beginne nichts Neues.")
                update(mission.id) { $0.wrapUpSent = true; $0.state = .wrappingUp }
                log(mission.title, "\(reason) fast aufgebraucht – schließt ab")
                continue
            }

            // Fertig? (Nach einer Nachfrage von AppForge erst die neue Antwort abwarten.)
            let settled = current.followUpAt.map { Date().timeIntervalSince($0) > 8 } ?? true
            if !isBusy, answered, settled, current.elapsed > 6 {
                let buildFailed = insights.build.map { !$0.ok } ?? false
                let testsFailed = insights.tests.map { !$0.ok } ?? false

                // Prüfschritt: Dateien geändert, aber nie gebaut → einmal bauen lassen (mit demselben Modell)
                if Savings.verifyBuild, lastError == nil, !insights.files.isEmpty, insights.build == nil,
                   current.verifySent != true, (current.budgetFraction ?? 0) < 0.85 {
                    await followUp(current, model: current.activeModel,
                                   text: "Du hast Dateien geändert, das Projekt aber noch nicht gebaut. Baue es jetzt, behebe alle Fehler und fasse danach in zwei Sätzen zusammen, wie du es geprüft hast.")
                    update(mission.id) { $0.verifySent = true; $0.activity = "Prüfschritt: baut das Projekt" }
                    log(mission.title, "Prüfschritt – nie gebaut, baut jetzt")
                    continue
                }

                // Stufe: Build/Tests rot oder Fehler → einmal an das stärkere Modell übergeben
                if Savings.cascade, buildFailed || testsFailed || lastError != nil,
                   let stronger = current.escalateTo, current.escalatedModel == nil, (current.budgetFraction ?? 0) < 0.8 {
                    let reason = buildFailed ? "Der Build schlägt fehl" : testsFailed ? "Tests schlagen fehl" : "Der letzte Versuch ist mit einem Fehler abgebrochen"
                    await followUp(current, model: stronger,
                                   text: "\(reason). Du übernimmst jetzt als stärkeres Modell. Lies die Fehlermeldungen, behebe die Ursache, baue erneut, bis alles grün ist, und fasse kurz zusammen.")
                    update(mission.id) { $0.escalatedModel = stronger; $0.activity = "übergeben an \(stronger.split(separator: "/").last ?? "")" }
                    log(mission.title, "\(reason.lowercased()) – übergeben an \(stronger.split(separator: "/").last ?? "")")
                    continue
                }

                let problem = lastError ?? (buildFailed ? "Build schlägt fehl" : testsFailed ? "Tests schlagen fehl" : nil)
                update(mission.id) {
                    $0.state = problem == nil ? .done : .failed
                    $0.activity = problem ?? ActivityDigest.summary(of: own)
                    $0.endedAt = .now
                }
                if problem == nil { log(mission.title, "fertig · \(Money.format(spent))", .good) }
                else { log(mission.title, "fehlgeschlagen · \(problem ?? "")", .problem) }
            }
        }
        reportConflicts()
    }

    /// Nachricht von AppForge an einen laufenden Agenten – mit demselben Systemhinweis wie beim Start,
    /// damit der Zwischenspeicher des Anbieters erhalten bleibt.
    private func followUp(_ mission: Mission, model label: String, text: String) async {
        guard let store, let client = store.client, let model = selection(label) else { return }
        try? await client.prompt(
            sessionID: mission.sessionID, directory: mission.directory, text: text,
            model: model, agent: mission.agent, system: mission.systemHint ?? store.platform.systemHint,
            variant: (mission.effort ?? .medium).variant(for: modelInfo(label))
        )
        update(mission.id) { $0.followUpAt = .now }
    }

    /// Neue Build- und Testergebnisse in den Ticker schreiben.
    private func reportChanges(of mission: Mission, old: MissionInsights?, new: MissionInsights) {
        if let build = new.build, build.time > (old?.build?.time ?? 0) {
            log(mission.title, build.ok ? "Build erfolgreich" : "Build fehlgeschlagen\(build.errors.map { " · \($0) Fehler" } ?? "")",
                build.ok ? .good : .problem)
        }
        if let tests = new.tests, tests.time > (old?.tests?.time ?? 0) {
            log(mission.title, new.testsLabel ?? "Tests gelaufen", tests.ok ? .good : .problem)
        }
    }

    /// Dateien, die mehrere Aufträge derselben Gruppe verändern – Gefahr, dass sie sich überschreiben.
    func conflicts(in group: [Mission]) -> [String: [String]] {
        var owners: [String: [String]] = [:]
        for mission in group {
            for file in mission.insights?.files ?? [] { owners[file, default: []].append(mission.title) }
        }
        return owners.filter { $0.value.count > 1 }
    }

    private func reportConflicts() {
        let groups = Dictionary(grouping: missions.filter { $0.groupID != nil }, by: { $0.groupID! })
        for (_, group) in groups {
            for (file, owners) in conflicts(in: group) {
                let key = file + owners.sorted().joined()
                guard reportedConflicts.insert(key).inserted else { continue }
                log(owners.joined(separator: " & "), "ändern beide \(file)", .problem)
            }
        }
    }

    private func contextLimit(for modelLabel: String) -> Double {
        let parts = modelLabel.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return 0 }
        return store?.providers?.all.first { $0.id == parts[0] }?.models[parts[1]]?.limit?.context ?? 0
    }

    private func update(_ id: UUID, _ change: (inout Mission) -> Void) {
        guard let index = missions.firstIndex(where: { $0.id == id }) else { return }
        change(&missions[index])
        persistMissions()
    }

    private func persistMissions() {
        save(Array(missions.prefix(60)), "dispatcher.missions")
    }

    // MARK: Events der Zentrale

    private func subscribe(client: OpenCodeClient, directory: String) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    for try await data in client.events(directory: directory) {
                        guard let event = try? ServerEvent.decode(data) else { continue }
                        self?.apply(event)
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func apply(_ event: ServerEvent) {
        switch event {
        case .messageUpdated(let info) where info.sessionID == sessionID:
            if let index = messages.firstIndex(where: { $0.id == info.id }) {
                messages[index].info = info
            } else {
                messages.append(ChatMessage(info: info, parts: []))
                messages.sort { $0.info.time.created < $1.info.time.created }
            }
            if !info.isUser, info.time.completed != nil {
                isThinking = false
                autoLaunchIfWanted(info.id)
            }
        case .partUpdated(let part) where part.sessionID == sessionID:
            guard let index = messages.firstIndex(where: { $0.id == part.messageID }) else { return }
            if let partIndex = messages[index].parts.firstIndex(where: { $0.id == part.id }) {
                messages[index].parts[partIndex] = part
            } else {
                messages[index].parts.append(part)
            }
        case .partDelta(let sid, let messageID, let partID, let field, let delta) where sid == sessionID && field == "text":
            var list = messages
            guard let index = list.firstIndex(where: { $0.id == messageID }),
                  let partIndex = list[index].parts.firstIndex(where: { $0.id == partID }) else { return }
            list[index].parts[partIndex].text = (list[index].parts[partIndex].text ?? "") + delta
            messages = list
        case .sessionStatus(let sid, let activity) where sid == sessionID:
            if activity == .idle { isThinking = false }
        case .sessionError(let sid, let message) where sid == sessionID:
            isThinking = false
            error = message
        default:
            break
        }
    }

    private func autoLaunchIfWanted(_ messageID: String) {
        guard autoStart, !launched.contains(messageID),
              let message = messages.first(where: { $0.id == messageID }),
              let proposal = proposal(for: message), proposal.dispatch else { return }
        // Direkt starten nur, wenn die gerechnete Einschätzung ins Budget passt – sonst entscheidest du.
        if let budget = budgetUSD ?? proposal.budgetUSD,
           let estimate = CostEstimator.total(proposal, entries: ModelCatalog.entries(from: store?.providers), missions: missions),
           estimate.expected > budget {
            log(proposal.title ?? "Auftrag", "wartet auf dich – Schätzung \(Money.format(estimate.expected)) über Budget \(Money.format(budget))", .attention)
            return
        }
        Task { await launch(proposal, from: messageID) }
    }

    func isLaunched(_ messageID: String) -> Bool { launched.contains(messageID) }

    // MARK: Speichern

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
