import SwiftUI

/// Live-Ansicht der Zentrale: Wer arbeitet gerade woran?
/// Oben die Zentrale, darunter die beauftragten Agenten, darunter deren Unteragenten.
/// Punkte fließen entlang der Verbindungen, solange ein Agent arbeitet.
struct AgentLiveView: View {
    @Environment(AppStore.self) private var store
    @State private var showDemo = false

    private var demoActive: Bool { showDemo && store.dispatcher.missions.isEmpty }

    var body: some View {
        let graph = demoActive ? LiveGraph.demo : LiveGraph.build(from: store)
        let events = demoActive ? LiveGraph.demoEvents : store.dispatcher.events
        GeometryReader { geo in
            let layout = LiveLayout(graph: graph, size: geo.size, reservedBottom: events.isEmpty ? 20 : 104)
            ZStack(alignment: .topLeading) {
                // Verbindungen und fließende Punkte
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !graph.isActive)) { context in
                    Canvas { canvas, _ in
                        LiveEdges.draw(in: &canvas, layout: layout, time: context.date.timeIntervalSinceReferenceDate)
                    }
                }
                .allowsHitTesting(false)

                // Knoten
                ForEach(graph.nodes) { node in
                    if let point = layout.positions[node.id] {
                        NodeView(
                            node: node,
                            onOpen: { open(node) },
                            onReply: { request, reply in
                                guard !request.id.hasPrefix("demo") else { return }
                                Task { await store.reply(to: request, reply) }
                            }
                        )
                        .position(point)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }

                if graph.nodes.count == 1, let center = layout.positions["zentrale"] {
                    emptyHint
                        .frame(width: geo.size.width)
                        .position(x: geo.size.width / 2, y: center.y + 150)
                }
            }
            .animation(Theme.Motion.spring, value: graph.nodes.map(\.id))
        }
        .overlay(alignment: .topLeading) { projectChip.padding(.leading, 18).padding(.top, 14) }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                if let summary = graph.summary { SummaryBar(summary: summary) }
                if demoActive {
                    Button("Beispiel schließen") { withAnimation(Theme.Motion.spring) { showDemo = false } }
                        .buttonStyle(PillButtonStyle())
                }
            }
            .padding(.trailing, 16).padding(.top, 12)
        }
        .overlay(alignment: .bottom) {
            if !events.isEmpty { EventTicker(events: events).padding(.horizontal, 18).padding(.bottom, 14) }
        }
        .background(Theme.black)
    }

    private func open(_ node: LiveNode) {
        guard let missionID = node.missionID,
              let mission = store.dispatcher.missions.first(where: { $0.id == missionID }),
              !mission.sessionID.isEmpty else { return }
        Task { await store.open(mission) }
    }

    @ViewBuilder private var projectChip: some View {
        if demoActive {
            Text("Beispiel")
                .font(Theme.Fonts.sans(11, .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().strokeBorder(Theme.line))
        } else if let path = store.selectedProject {
            let info = ProjectInfoCache.info(for: path)
            HStack(spacing: 8) {
                AppIconView(info: info, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.appName).font(Theme.Fonts.sans(12.5, .medium)).foregroundStyle(Theme.textPrimary)
                    Text("Agenten arbeiten an dieser App").font(Theme.Fonts.sans(10.5)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Text("Noch keine Agenten unterwegs.")
                .font(Theme.Fonts.sans(14))
                .foregroundStyle(Theme.textSecondary)
            Text("Beschreibe links einen Auftrag. Hier siehst du dann live,\nwelche Agenten woran arbeiten.")
                .font(Theme.Fonts.sans(12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Button("Beispiel ansehen") { withAnimation(Theme.Motion.spring) { showDemo = true } }
                .buttonStyle(PillButtonStyle())
        }
    }
}

// MARK: Datenmodell

struct LiveNode: Identifiable {
    enum Kind: Hashable { case dispatcher, agent, subagent }
    enum Status: Hashable { case idle, working, waiting, done, failed }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    /// Kurz gefasst: Was tut der Agent gerade?
    var thought: String
    var status: Status
    var symbol: String
    var parentID: String?
    var dependsOn: [String] = []
    var missionID: UUID?
    var detail: String = ""

    // Zusatzinfos für Agenten
    var insights: MissionInsights?
    var permissions: [PermissionRequest] = []
    /// Dateien, die auch ein anderer Agent verändert – mit dessen Namen.
    var conflicts: [(file: String, others: [String])] = []
    var preview: Part?
    var spent: Double = 0
    var estimate: Double?

    var overBudget: Bool { (estimate ?? 0) > 0 && spent > (estimate ?? 0) * 1.3 }

    /// Zeile unter dem Gedanken mit Dateien, Build, Tests – nur wenn es etwas zu zeigen gibt.
    var hasMeta: Bool {
        guard kind == .agent, let insights else { return overBudget }
        return !insights.files.isEmpty || insights.build != nil || insights.tests != nil || overBudget
    }

    /// Höhe von Titel, Gedanke und Zusatzzeilen unter der Form – damit Linien darunter ansetzen.
    var labelHeight: CGFloat {
        let base: CGFloat = switch kind {
        case .dispatcher: 58
        case .agent: 40
        case .subagent: 36
        }
        return base + (hasMeta ? 18 : 0) + (conflicts.isEmpty ? 0 : 16) + (permissions.isEmpty ? 0 : 34)
    }
}

/// Gesamtbilanz der angezeigten Aufträge.
struct LiveSummary {
    var build: MissionInsights.Build?
    var tests: MissionInsights.Tests?
    var testsLabel: String?
    var spent: Double
    var projected: Double
    var budget: Double?
    var waitingForYou: Int
}

struct LiveGraph {
    var nodes: [LiveNode]
    var summary: LiveSummary?

    var isActive: Bool { nodes.contains { $0.status == .working } }

    static func symbol(forAgent name: String) -> String {
        switch name {
        case "build": "hammer"
        case "plan": "list.bullet.clipboard"
        case "koordinator": "person.3"
        case "swift-entwickler", "swift-experte": "chevron.left.forwardslash.chevron.right"
        case "ui-designer": "paintbrush.pointed"
        case "tester": "checkmark.seal"
        case "lektor": "text.quote"
        case "davinci": "film"
        case "explore", "scout": "magnifyingglass"
        default: "person.crop.circle"
        }
    }

    /// Baut den Graphen aus den echten Aufträgen und – wo verfügbar – den live mitlaufenden Chat-Verläufen.
    @MainActor
    static func build(from store: AppStore) -> LiveGraph {
        let dispatcher = store.dispatcher
        let missions = dispatcher.missions
        let latestGroup = missions.first.map { $0.groupID ?? $0.id }
        let shown = Array(missions.filter { !$0.state.isFinished || ($0.groupID ?? $0.id) == latestGroup }.prefix(6))

        let running = shown.filter { !$0.state.isFinished }.count
        let lastUserText = dispatcher.messages.last(where: \.info.isUser).map { dispatcher.text(of: $0) } ?? ""
        let routerName = dispatcher.effectiveRouterModel.flatMap { sel in
            store.providers?.all.first { $0.id == sel.providerID }?.models[sel.modelID]?.name
        } ?? "Zentrale"

        var nodes = [LiveNode(
            id: "zentrale", kind: .dispatcher, title: "Zentrale", subtitle: routerName,
            thought: dispatcher.isThinking ? "plant: " + ActivityDigest.short(lastUserText, 38)
                : running > 0 ? "überwacht \(running) \(running == 1 ? "Agent" : "Agenten")"
                : shown.isEmpty ? "bereit" : "alle Aufträge erledigt",
            status: dispatcher.isThinking || running > 0 ? .working : (shown.isEmpty ? .idle : .done),
            symbol: "dot.radiowaves.left.and.right"
        )]

        // Live-Kennzahlen je Auftrag (aus den mitlaufenden Verläufen, sonst letzter Überwachungsstand)
        var liveInsights: [UUID: MissionInsights] = [:]
        var previews: [UUID: Part] = [:]
        for mission in shown {
            guard let transcript = store.messages[mission.sessionID] else { continue }
            let childIDs = transcript.flatMap(\.parts).compactMap(\.childSessionID)
            let limit = contextLimit(mission.model, store: store)
            let result = InsightExtractor.extract(main: transcript, children: childIDs.compactMap { store.messages[$0] }, contextLimit: limit)
            liveInsights[mission.id] = result.insights
            previews[mission.id] = result.preview
        }
        func insights(_ mission: Mission) -> MissionInsights? { liveInsights[mission.id] ?? mission.insights }

        // Dateien, die mehrere Aufträge derselben Gruppe anfassen
        var owners: [String: [String]] = [:]
        for mission in shown { for file in insights(mission)?.files ?? [] { owners[file, default: []].append(mission.title) } }

        for mission in shown.reversed() {
            let transcript = store.messages[mission.sessionID]
            let status: LiveNode.Status = switch mission.state {
            case .waiting: .waiting
            case .running, .wrappingUp: .working
            case .done: .done
            case .failed, .stoppedBudget, .stoppedTime, .cancelled: .failed
            }
            let thought: String = switch mission.state {
            case .running, .wrappingUp: transcript.flatMap(ActivityDigest.activity(of:)) ?? mission.activity ?? "arbeitet"
            case .waiting: mission.activity ?? "wartet"
            case .done: "fertig · " + String(format: "$%.3f", mission.spentUSD) + " · " + duration(mission.elapsed)
            default: mission.state.title
            }
            let agentName = store.agents.first { $0.name == mission.agent }?.displayName ?? mission.agent
            let modelName = mission.model.split(separator: "/").last.map(String.init) ?? mission.model
            let own = insights(mission)
            let conflicts = (own?.files ?? []).compactMap { file -> (file: String, others: [String])? in
                let others = (owners[file] ?? []).filter { $0 != mission.title }
                return others.isEmpty ? nil : (file, others)
            }
            var detail = "\(mission.model)\nKosten \(String(format: "$%.3f", mission.spentUSD))"
            if let budget = mission.budgetUSD { detail += String(format: " von $%.2f", budget) }
            detail += "\nZeit \(duration(mission.elapsed))"
            if let fraction = own?.contextFraction { detail += "\nKontext \(Int(fraction * 100)) %" }
            if let files = own?.files, !files.isEmpty { detail += "\n\n" + files.prefix(8).joined(separator: "\n") }

            nodes.append(LiveNode(
                id: mission.id.uuidString, kind: .agent, title: mission.title, subtitle: "\(agentName) · \(modelName)",
                thought: thought, status: status, symbol: symbol(forAgent: mission.agent), parentID: "zentrale",
                dependsOn: (mission.dependsOn ?? []).map(\.uuidString), missionID: mission.id, detail: detail,
                insights: own, permissions: store.permissions(forRoot: mission.sessionID), conflicts: conflicts,
                preview: previews[mission.id], spent: mission.spentUSD, estimate: mission.estimatedCostUSD
            ))

            let subs = transcript.map { ActivityDigest.subagents(in: $0) { store.messages[$0] } } ?? mission.subagents ?? []
            for sub in subs.prefix(3) {
                let subStatus: LiveNode.Status = switch sub.status {
                case "running": .working
                case "completed": .done
                case "error": .failed
                default: .waiting
                }
                nodes.append(LiveNode(
                    id: "\(mission.id.uuidString)-\(sub.id)", kind: .subagent, title: "@\(sub.name)", subtitle: sub.task,
                    thought: subStatus == .done ? "fertig" : (sub.activity ?? sub.task), status: subStatus,
                    symbol: symbol(forAgent: sub.name), parentID: mission.id.uuidString, missionID: mission.id
                ))
            }
        }

        // Gesamtbilanz mit Hochrechnung
        var summary: LiveSummary?
        if !shown.isEmpty {
            let all = shown.compactMap(insights)
            let latestBuild = all.compactMap(\.build).max { $0.time < $1.time }
            let latestTests = all.filter { $0.tests != nil }.max { ($0.tests?.time ?? 0) < ($1.tests?.time ?? 0) }
            let projected = shown.reduce(0.0) { sum, mission in
                switch mission.state {
                case .waiting: return sum + (mission.estimatedCostUSD ?? 0)
                case .running, .wrappingUp:
                    if let progress = insights(mission)?.progress, progress > 0.15 { return sum + mission.spentUSD / progress }
                    return sum + max(mission.spentUSD, mission.estimatedCostUSD ?? 0)
                default: return sum + mission.spentUSD
                }
            }
            let budgets = shown.compactMap(\.budgetUSD)
            summary = LiveSummary(
                build: latestBuild, tests: latestTests?.tests, testsLabel: latestTests?.testsLabel,
                spent: shown.map(\.spentUSD).reduce(0, +), projected: projected,
                budget: budgets.isEmpty ? nil : budgets.reduce(0, +),
                waitingForYou: nodes.reduce(0) { $0 + $1.permissions.count }
            )
        }
        return LiveGraph(nodes: nodes, summary: summary)
    }

    @MainActor
    private static func contextLimit(_ model: String, store: AppStore) -> Double {
        let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return 0 }
        return store.providers?.all.first { $0.id == parts[0] }?.models[parts[1]]?.limit?.context ?? 0
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s < 60 ? "\(s) s" : "\(s / 60):\(String(format: "%02d", s % 60)) min"
    }

    // MARK: Beispiel

    /// Beispiel, damit man die Ansicht ohne laufende Aufträge kennenlernen kann.
    static var demo: LiveGraph {
        let now = Date().timeIntervalSince1970 * 1000
        var designInsights = MissionInsights(files: ["Ansicht/SettingsView.swift", "Design/Theme.swift"], additions: 64, deletions: 12,
                                             todoDone: 3, todoTotal: 5, contextUsed: 41_000, contextLimit: 128_000)
        designInsights.build = .init(ok: true, time: now - 120_000, errors: 0)
        var codeInsights = MissionInsights(files: ["Ansicht/SettingsView.swift", "Kern/Einstellungen.swift"], additions: 88, deletions: 20,
                                           todoDone: 2, todoTotal: 6, contextUsed: 109_000, contextLimit: 128_000)
        codeInsights.build = .init(ok: false, time: now - 30_000, errors: 2)
        let textInsights = MissionInsights(files: ["Resources/Localizable.xcstrings"], additions: 14, deletions: 9,
                                           todoDone: 4, todoTotal: 4, contextUsed: 22_000, contextLimit: 128_000)
        let request = PermissionRequest(id: "demo-1", sessionID: "", permission: "bash",
                                        patterns: ["git commit -m \"Einstellungen\""], metadata: nil, always: nil)
        return LiveGraph(nodes: [
            LiveNode(id: "zentrale", kind: .dispatcher, title: "Zentrale", subtitle: "Qwen3.8 Flash",
                     thought: "überwacht 3 Agenten", status: .working, symbol: "dot.radiowaves.left.and.right"),
            LiveNode(id: "design", kind: .agent, title: "Design", subtitle: "UI-Designer · qwen3.8-max",
                     thought: "bearbeitet SettingsView.swift", status: .working, symbol: "paintbrush.pointed", parentID: "zentrale",
                     detail: "alibaba/qwen3.8-max\nKosten $0.041 von $0.10", insights: designInsights, permissions: [request],
                     conflicts: [("Ansicht/SettingsView.swift", ["Code"])], spent: 0.041, estimate: 0.08),
            LiveNode(id: "code", kind: .agent, title: "Code", subtitle: "Koordinator · deepseek-v4.1",
                     thought: "beauftragt @swift-entwickler", status: .working, symbol: "person.3", parentID: "zentrale",
                     detail: "deepseek/deepseek-v4.1\nKosten $0.037 von $0.12", insights: codeInsights,
                     conflicts: [("Ansicht/SettingsView.swift", ["Design"])], spent: 0.037, estimate: 0.1),
            LiveNode(id: "texte", kind: .agent, title: "Texte", subtitle: "Build · deepseek-flash",
                     thought: "fertig · $0.006 · 0:48 min", status: .done, symbol: "text.quote", parentID: "zentrale",
                     insights: textInsights, spent: 0.006, estimate: 0.01),
            LiveNode(id: "tests", kind: .agent, title: "Tests & Build", subtitle: "Tester · deepseek-flash",
                     thought: "wartet auf Design, Code", status: .waiting, symbol: "checkmark.seal", parentID: "zentrale",
                     dependsOn: ["design", "code"], estimate: 0.04),
            LiveNode(id: "code-a", kind: .subagent, title: "@swift-entwickler", subtitle: "Einstellungen speichern",
                     thought: "baut das Projekt", status: .working, symbol: "chevron.left.forwardslash.chevron.right", parentID: "code"),
            LiveNode(id: "code-b", kind: .subagent, title: "@lektor", subtitle: "Beschriftungen prüfen",
                     thought: "fertig", status: .done, symbol: "text.quote", parentID: "code"),
        ], summary: LiveSummary(build: codeInsights.build, tests: nil, testsLabel: nil, spent: 0.084, projected: 0.23, budget: 0.30, waitingForYou: 1))
    }

    static var demoEvents: [MissionEvent] {
        [
            MissionEvent(source: "Design", text: "braucht deine Freigabe · bash", tone: .attention),
            MissionEvent(source: "Design & Code", text: "ändern beide Ansicht/SettingsView.swift", tone: .attention),
            MissionEvent(source: "Code", text: "Build fehlgeschlagen · 2 Fehler", tone: .attention),
            MissionEvent(source: "Texte", text: "fertig · $0.006", tone: .good),
        ]
    }
}

// MARK: Anordnung

struct LiveLayout {
    let graph: LiveGraph
    let size: CGSize
    let positions: [String: CGPoint]

    static let agentSize = CGSize(width: 180, height: 58)
    static let dispatcherDiameter: CGFloat = 60
    static let subagentDiameter: CGFloat = 44

    init(graph: LiveGraph, size: CGSize, reservedBottom: CGFloat) {
        self.graph = graph
        self.size = size
        var positions: [String: CGPoint] = [:]
        let agents = graph.nodes.filter { $0.kind == .agent }
        let hasSubagents = graph.nodes.contains { $0.kind == .subagent }

        let top: CGFloat = 100
        let usableBottom = size.height - reservedBottom
        let agentY = hasSubagents ? max(top + 170, usableBottom * 0.42) : max(top + 190, usableBottom * 0.5)
        let subY = min(agentY + 220, usableBottom - 70)
        positions["zentrale"] = CGPoint(x: size.width / 2, y: agents.isEmpty ? size.height * 0.3 : top)

        let margin: CGFloat = 24 + Self.agentSize.width / 2
        let usable = max(1, size.width - 2 * margin)
        for (index, agent) in agents.enumerated() {
            let x = agents.count == 1 ? size.width / 2 : margin + usable * CGFloat(index) / CGFloat(agents.count - 1)
            // Leicht versetzt, damit Gedanken benachbarter Karten sich nicht berühren
            let stagger: CGFloat = agents.count > 3 && index % 2 == 1 ? 34 : 0
            positions[agent.id] = CGPoint(x: x, y: agentY + stagger)

            let children = graph.nodes.filter { $0.kind == .subagent && $0.parentID == agent.id }
            for (childIndex, child) in children.enumerated() {
                let offset = (CGFloat(childIndex) - CGFloat(children.count - 1) / 2) * 96
                let childX = min(max(x + offset, 40), size.width - 40)
                positions[child.id] = CGPoint(x: childX, y: subY + stagger)
            }
        }
        self.positions = positions
    }

    /// Anschlusspunkt oben an der Form bzw. unten – dort erst unterhalb aller Beschriftungen,
    /// damit keine Linie durch Text läuft.
    func anchor(_ node: LiveNode, top: Bool) -> CGPoint? {
        guard let point = positions[node.id] else { return nil }
        let half: CGFloat = switch node.kind {
        case .dispatcher: Self.dispatcherDiameter / 2
        case .agent: Self.agentSize.height / 2
        case .subagent: Self.subagentDiameter / 2
        }
        return CGPoint(x: point.x, y: top ? point.y - half : point.y + half + node.labelHeight)
    }
}

// MARK: Verbindungen

enum LiveEdges {
    static func draw(in canvas: inout GraphicsContext, layout: LiveLayout, time: TimeInterval) {
        let nodes = layout.graph.nodes
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        // Eltern → Kind
        for child in nodes {
            guard let parentID = child.parentID, let parent = byID[parentID],
                  let from = layout.anchor(parent, top: false), let to = layout.anchor(child, top: true) else { continue }
            let path = curve(from: from, to: to)
            canvas.stroke(path, with: .color(color(child.status).opacity(opacity(child.status))), style: style(child.status))

            if child.status == .working {
                // Aufträge fließen als Punkte nach unten
                for k in 0..<3 {
                    let t = (time * 0.42 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let p = point(on: from, to, t: t)
                    canvas.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Theme.orange.opacity(0.14)))
                    canvas.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(Theme.orange))
                }
            } else if child.status == .done {
                canvas.fill(Path(ellipseIn: CGRect(x: to.x - 3, y: to.y - 3, width: 6, height: 6)), with: .color(Theme.green.opacity(0.8)))
            }
        }

        // Abhängigkeiten: gestrichelter Bogen unter den Karten, vom Vorgänger zum wartenden Auftrag
        for node in nodes where node.kind == .agent {
            for depID in node.dependsOn {
                guard let dep = byID[depID], let a = layout.anchor(dep, top: false), let b = layout.anchor(node, top: false) else { continue }
                var path = Path()
                let depth: CGFloat = 22 + abs(b.x - a.x) * 0.04
                path.move(to: a)
                path.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + depth), control2: CGPoint(x: b.x, y: b.y + depth))
                let finished = dep.status == .done
                canvas.stroke(path, with: .color((finished ? Theme.green : Theme.textTertiary).opacity(0.45)),
                              style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 5]))
                var arrow = Path()
                arrow.move(to: CGPoint(x: b.x - 4, y: b.y + 7))
                arrow.addLine(to: b)
                arrow.addLine(to: CGPoint(x: b.x + 4, y: b.y + 7))
                canvas.stroke(arrow, with: .color(Theme.textTertiary.opacity(0.6)), lineWidth: 1)
            }
        }
    }

    private static func curve(from a: CGPoint, to b: CGPoint) -> Path {
        var path = Path()
        let mid = (b.y - a.y) * 0.5
        path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + mid), control2: CGPoint(x: b.x, y: b.y - mid))
        return path
    }

    /// Punkt auf derselben Bézier-Kurve wie `curve(from:to:)`.
    private static func point(on a: CGPoint, _ b: CGPoint, t: Double) -> CGPoint {
        let mid = (b.y - a.y) * 0.5
        let c1 = CGPoint(x: a.x, y: a.y + mid), c2 = CGPoint(x: b.x, y: b.y - mid)
        let u = 1 - t
        let x = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x
        let y = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y
        return CGPoint(x: x, y: y)
    }

    private static func color(_ status: LiveNode.Status) -> Color {
        switch status {
        case .working: Theme.orange
        case .done: Theme.green
        default: Theme.textTertiary
        }
    }

    private static func opacity(_ status: LiveNode.Status) -> Double {
        switch status {
        case .working: 0.5
        case .done: 0.4
        default: 0.35
        }
    }

    private static func style(_ status: LiveNode.Status) -> StrokeStyle {
        switch status {
        case .waiting: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 5])
        case .working: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        default: StrokeStyle(lineWidth: 1, lineCap: .round)
        }
    }
}

// MARK: Knoten

private struct NodeView: View {
    let node: LiveNode
    let onOpen: () -> Void
    let onReply: (PermissionRequest, PermissionReply) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 7) {
            shape
            VStack(spacing: 4) {
                if node.kind != .agent {
                    Text(node.title)
                        .font(Theme.Fonts.sans(12, .medium))
                        .foregroundStyle(Theme.textPrimary)
                }
                Thought(text: node.thought, status: node.status)
                if node.hasMeta { MetaLine(node: node) }
                ForEach(node.conflicts.prefix(1), id: \.file) { conflict in
                    Label("\((conflict.file as NSString).lastPathComponent) auch bei \(conflict.others.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.sans(10.5))
                        .foregroundStyle(Theme.orange)
                        .lineLimit(1)
                        .help("Zwei Agenten ändern dieselbe Datei – das Ergebnis des einen kann das des anderen überschreiben.")
                }
                ForEach(node.permissions.prefix(1)) { request in
                    PermissionChip(request: request, onReply: onReply)
                }
            }
            .frame(width: node.kind == .agent ? 206 : 150)
        }
        // Die Form (nicht der ganze Block) soll auf der berechneten Position liegen.
        .offset(y: node.labelHeight / 2)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help(node.detail.isEmpty ? node.subtitle : node.detail)
        .animation(Theme.Motion.snappy, value: hovering)
        .animation(Theme.Motion.spring, value: node.status)
    }

    @ViewBuilder private var shape: some View {
        switch node.kind {
        case .dispatcher:
            ZStack {
                if node.status == .working { PulseRings(diameter: LiveLayout.dispatcherDiameter) }
                Circle().fill(Theme.raise)
                Circle().strokeBorder(border, lineWidth: 1.2)
                Image(systemName: node.symbol)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(node.status == .working ? Theme.orange : Theme.textSecondary)
            }
            .frame(width: LiveLayout.dispatcherDiameter, height: LiveLayout.dispatcherDiameter)

        case .agent:
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.lift)
                    // Kontextring: wie voll das Gedächtnis des Agenten ist
                    if let fraction = node.insights?.contextFraction {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(fraction > 0.8 ? Theme.orange : Theme.textTertiary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(1)
                    }
                    Image(systemName: node.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(node.status == .working ? Theme.orange : Theme.textSecondary)
                }
                .frame(width: 28, height: 28)
                .help(node.insights?.contextFraction.map { "Kontext \(Int($0 * 100)) % belegt" } ?? "")

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title)
                        .font(Theme.Fonts.sans(12.5, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(node.subtitle)
                        .font(Theme.Fonts.sans(10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                statusMark
            }
            .padding(.horizontal, 10)
            .frame(width: LiveLayout.agentSize.width, height: LiveLayout.agentSize.height)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? Theme.lift : Theme.raise))
            .overlay(alignment: .bottom) { progressBar }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(border, style: StrokeStyle(lineWidth: 1.2, dash: node.status == .waiting ? [4, 4] : []))
            )
            .overlay(alignment: .topTrailing) { thumbnail }
            .shadow(color: node.status == .working ? Theme.orange.opacity(0.25) : .clear, radius: 12)
            .scaleEffect(hovering ? 1.03 : 1)

        case .subagent:
            ZStack {
                Circle().fill(Theme.raise)
                Circle().strokeBorder(border, style: StrokeStyle(lineWidth: 1.2, dash: node.status == .waiting ? [3, 4] : []))
                Image(systemName: node.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(node.status == .working ? Theme.orange : Theme.textSecondary)
            }
            .frame(width: LiveLayout.subagentDiameter, height: LiveLayout.subagentDiameter)
            .shadow(color: node.status == .working ? Theme.orange.opacity(0.22) : .clear, radius: 10)
            .scaleEffect(hovering ? 1.06 : 1)
        }
    }

    /// Fortschritt laut Aufgabenliste des Agenten – als feine Linie am unteren Kartenrand.
    @ViewBuilder private var progressBar: some View {
        if let progress = node.insights?.progress {
            GeometryReader { geo in
                Capsule()
                    .fill(node.status == .done ? Theme.green : Theme.orange)
                    .frame(width: max(4, (geo.size.width - 28) * progress), height: 2)
                    .offset(x: 14, y: geo.size.height - 5)
                    .animation(Theme.Motion.spring, value: progress)
            }
            .allowsHitTesting(false)
            .help("Schritt \(node.insights?.todoDone ?? 0) von \(node.insights?.todoTotal ?? 0)")
        }
    }

    /// Mini-Vorschau des letzten Screenshots oder Bildes.
    @ViewBuilder private var thumbnail: some View {
        if let preview = node.preview, let image = ImageCache.image(for: preview) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.15)))
                .offset(x: 18, y: -26)
                .shadow(color: .black.opacity(0.5), radius: 6)
                .help("Letzter Screenshot")
        }
    }

    @ViewBuilder private var statusMark: some View {
        switch node.status {
        case .working: ForgeSpinner(size: 12)
        case .done: DrawnCheckmark(size: 12)
        case .waiting: Image(systemName: "hourglass").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        case .failed: Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.orange)
        case .idle: EmptyView()
        }
    }

    private var border: Color {
        if !node.permissions.isEmpty { return Theme.orange }
        switch node.status {
        case .working: return Theme.orange.opacity(0.7)
        case .done: return Theme.green.opacity(0.55)
        case .failed: return Theme.orange.opacity(0.35)
        case .waiting, .idle: return Theme.line
        }
    }
}

/// Dateien · Build · Tests · Kostenwarnung – eine ruhige Zeile unter dem Gedanken.
private struct MetaLine: View {
    let node: LiveNode

    var body: some View {
        HStack(spacing: 8) {
            if let insights = node.insights, !insights.files.isEmpty {
                HStack(spacing: 3) {
                    Text("\(insights.files.count) \(insights.files.count == 1 ? "Datei" : "Dateien")")
                    if insights.additions + insights.deletions > 0 {
                        Text("+\(insights.additions)").foregroundStyle(Theme.green.opacity(0.8))
                        Text("−\(insights.deletions)")
                    }
                }
            }
            if let build = node.insights?.build {
                Label(build.ok ? "Build" : "Build \(build.errors.map { "· \($0)" } ?? "")", systemImage: build.ok ? "checkmark" : "xmark")
                    .foregroundStyle(build.ok ? Theme.green.opacity(0.85) : Theme.orange)
            }
            if let tests = node.insights?.tests, let label = node.insights?.testsLabel {
                Text(label).foregroundStyle(tests.ok ? Theme.green.opacity(0.85) : Theme.orange)
            }
            if node.overBudget {
                Text("teurer als geschätzt").foregroundStyle(Theme.orange)
            }
        }
        .font(Theme.Fonts.sans(10.5))
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
    }
}

/// „Braucht dich“ – Freigabe direkt am Agenten erteilen.
private struct PermissionChip: View {
    let request: PermissionRequest
    let onReply: (PermissionRequest, PermissionReply) -> Void

    private var title: String {
        switch request.permission {
        case "edit", "write": "Datei ändern"
        case "bash": "Befehl"
        case "external_directory": "Zugriff außerhalb"
        default: request.permission
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill").font(.system(size: 9))
            Text("braucht dich").lineLimit(1).fixedSize()
            Spacer(minLength: 2)
            Button("Nein") { onReply(request, .reject) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            Button("Erlauben") { onReply(request, .once) }
                .buttonStyle(.plain)
                .fontWeight(.medium)
                .foregroundStyle(Theme.black)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Theme.orange))
        }
        .font(Theme.Fonts.sans(10.5))
        .foregroundStyle(Theme.orange)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Theme.orange.opacity(0.1)))
        .overlay(Capsule().strokeBorder(Theme.orange.opacity(0.45)))
        .help(([title] + request.patterns).joined(separator: "\n"))
    }
}

/// Der Gedanke unter einem Knoten: kurz, was gerade passiert.
private struct Thought: View {
    let text: String
    let status: LiveNode.Status

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle()
                .fill(status == .working ? Theme.orange : (status == .done ? Theme.green : Theme.textTertiary))
                .frame(width: 4, height: 4)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            Text(text)
                .font(Theme.Fonts.sans(11).italic())
                .foregroundStyle(status == .working ? Theme.textSecondary : Theme.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
        }
        .animation(Theme.Motion.gentle, value: text)
    }
}

// MARK: Gesamtbilanz & Ereignisse

/// Oben rechts: offene Freigaben, letzter Build, Tests, Kosten mit Hochrechnung.
private struct SummaryBar: View {
    let summary: LiveSummary

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 12) {
                if summary.waitingForYou > 0 {
                    Label("\(summary.waitingForYou) \(summary.waitingForYou == 1 ? "Freigabe" : "Freigaben") offen", systemImage: "hand.raised.fill")
                        .foregroundStyle(Theme.orange)
                }
                if let build = summary.build {
                    Label("Build \(build.ok ? "ok" : "rot") · \(ago(build.time))", systemImage: build.ok ? "checkmark" : "xmark")
                        .foregroundStyle(build.ok ? Theme.green.opacity(0.85) : Theme.orange)
                }
                if let tests = summary.tests, let label = summary.testsLabel {
                    Text(label).foregroundStyle(tests.ok ? Theme.green.opacity(0.85) : Theme.orange)
                }
                HStack(spacing: 4) {
                    Text(String(format: "$%.3f", summary.spent)).foregroundStyle(Theme.textPrimary)
                    Text("→ ≈ " + String(format: "$%.2f", summary.projected))
                    if let budget = summary.budget {
                        Text(String(format: "von $%.2f", budget))
                            .foregroundStyle(summary.projected > budget ? Theme.orange : Theme.textTertiary)
                    }
                }
                .help("Bisher ausgegeben → voraussichtlich am Ende (aus Fortschritt und Schätzungen)")
            }
            .font(Theme.Fonts.sans(11.5))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.raise))
            .overlay(Capsule().strokeBorder(Theme.line))
        }
    }

    private func ago(_ milliseconds: Double) -> String {
        let seconds = Int(Date().timeIntervalSince1970 - milliseconds / 1000)
        if seconds < 60 { return "gerade" }
        if seconds < 3600 { return "vor \(seconds / 60) min" }
        return "vor \(seconds / 3600) h"
    }
}

/// Unten: die letzten Ereignisse als ruhige Zeitleiste.
private struct EventTicker: View {
    let events: [MissionEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(events.prefix(4).enumerated()), id: \.element.id) { index, event in
                HStack(spacing: 8) {
                    Circle()
                        .fill(dot(event.tone))
                        .frame(width: 5, height: 5)
                    Text(event.date.formatted(date: .omitted, time: .shortened))
                        .font(Theme.Fonts.mono(10.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(event.source)
                        .font(Theme.Fonts.sans(11.5, .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(event.text)
                        .font(Theme.Fonts.sans(11.5))
                        .foregroundStyle(event.tone == .attention ? Theme.orange : Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .opacity(1 - Double(index) * 0.18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        .animation(Theme.Motion.spring, value: events.map(\.id))
    }

    private func dot(_ tone: MissionEvent.Tone) -> Color {
        switch tone {
        case .neutral: Theme.textTertiary
        case .good: Theme.green
        case .attention: Theme.orange
        }
    }
}

/// Sanfte Ringe um die Zentrale, solange sie plant oder überwacht.
private struct PulseRings: View {
    let diameter: CGFloat
    @State private var expand = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .strokeBorder(Theme.orange.opacity(0.35), lineWidth: 1)
                    .scaleEffect(expand ? 1.9 : 1)
                    .opacity(expand ? 0 : 0.8)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(index) * 1.2), value: expand)
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear { expand = true }
    }
}
