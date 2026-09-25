import SwiftUI

/// Startseite: Die Zentrale – ein günstiges Modell, das Aufträge plant, verteilt und überwacht.
struct ZentraleView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("zentrale.live") private var liveMode = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var dispatcher: Dispatcher { store.dispatcher }

    var body: some View {
        VStack(spacing: 0) {
            header
            if liveMode {
                // Links das Gespräch mit der Zentrale, rechts die Live-Ansicht aller Agenten
                // Ist ein Agent angeklickt, stehen links seine Gedanken statt des Gesprächs.
                HStack(spacing: 0) {
                    Group {
                        if let focus = dispatcher.focus {
                            AgentThoughtsView(focus: focus)
                                .id(focus.nodeID)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        } else {
                            conversation(showsBoard: false)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: 440)
                    .animation(Theme.Motion.spring, value: dispatcher.focus?.nodeID)
                    Rectangle().fill(Theme.line).frame(width: 1)
                    AgentLiveView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
            } else {
                conversation(showsBoard: true)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.spring, value: liveMode)
        .onAppear { focused = true }
    }

    private func conversation(showsBoard: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if showsBoard && !dispatcher.missions.isEmpty {
                            MissionBoard()
                                .transition(.riseIn)
                        }

                        if dispatcher.messages.isEmpty {
                            Intro { draft = $0; focused = true }
                                .transition(.riseIn)
                        } else {
                            HStack {
                                Eyebrow("Gespräch mit der Zentrale")
                                Spacer()
                                Button { withAnimation(Theme.Motion.spring) { dispatcher.newConversation() } } label: {
                                    Label("Neu beginnen", systemImage: "arrow.counterclockwise")
                                }
                                .buttonStyle(PillButtonStyle())
                            }
                        }

                        ForEach(dispatcher.messages) { message in
                            DispatchMessageView(message: message)
                                .id(message.id)
                                .transition(.riseIn)
                        }

                        if dispatcher.isThinking {
                            HStack(spacing: 10) {
                                BreathingDots()
                                ShimmerText(text: "Die Zentrale wägt Modelle und Kosten ab")
                            }
                            .transition(.riseIn)
                        }

                        if let error = dispatcher.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(Theme.Fonts.small)
                                .foregroundStyle(Theme.clay)
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, showsBoard ? 28 : 22)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                    .animation(Theme.Motion.spring, value: dispatcher.messages.count)
                    .animation(Theme.Motion.spring, value: dispatcher.missions.map(\.id))
                    .animation(Theme.Motion.spring, value: dispatcher.isThinking)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom)
                .overlay { EdgeFade() }
                .onChange(of: dispatcher.messages.last?.parts.last?.text) {
                    withAnimation(Theme.Motion.gentle) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            DispatchComposer(draft: $draft, focused: $focused)
                .frame(maxWidth: 860)
                .padding(.horizontal, showsBoard ? 24 : 16)
                .padding(.bottom, 18)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(Theme.Motion.spring) { store.sidebarVisible.toggle() }
            } label: { Image(systemName: "sidebar.left") }
            .buttonStyle(IconButtonStyle(size: 30))
            .padding(.leading, store.sidebarVisible ? 0 : 70)
            .accessibilityLabel("Seitenleiste ein- oder ausblenden")

            VStack(alignment: .leading, spacing: 2) {
                Text("Zentrale").font(Theme.Fonts.title)
                if let path = store.selectedProject {
                    let info = ProjectInfoCache.info(for: path)
                    HStack(spacing: 5) {
                        AppIconView(info: info, size: 14)
                        Text("arbeitet an \(info.appName)")
                    }
                    .font(Theme.Fonts.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                } else {
                    Text("kein Projekt geöffnet")
                        .font(Theme.Fonts.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            ViewSwitch(liveMode: $liveMode)
            Stat(label: "heute", value: Money.format(dispatcher.spentToday))
            Stat(label: "laufend", value: "\(dispatcher.runningMissions.count)")
            RouterModelPill()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
    }
}

/// Umschalter „Liste | Live“ mit gleitender Markierung.
private struct ViewSwitch: View {
    @Binding var liveMode: Bool
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            option("Liste", "list.bullet", live: false)
            option("Live", "point.3.connected.trianglepath.dotted", live: true)
        }
        .padding(3)
        .background(Capsule().fill(Theme.raise))
        .overlay(Capsule().strokeBorder(Theme.line))
    }

    private func option(_ title: String, _ symbol: String, live: Bool) -> some View {
        let selected = liveMode == live
        return Button {
            withAnimation(Theme.Motion.bouncy) { liveMode = live }
        } label: {
            Label(title, systemImage: symbol)
                .font(Theme.Fonts.sans(12, selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        Capsule().fill(Theme.lift).matchedGeometryEffect(id: "ansicht", in: indicator)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(live ? "Live-Ansicht: wer arbeitet gerade woran" : "Liste der Aufträge")
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(Theme.Fonts.mono(13, .medium))
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            Eyebrow(label)
        }
        .padding(.horizontal, 6)
    }
}

/// Welches (günstige) Modell die Zentrale selbst nutzt.
private struct RouterModelPill: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let dispatcher = store.dispatcher
        Menu {
            Button("Automatisch (günstigstes)") { dispatcher.routerModel = nil }
            Divider()
            ForEach(ModelCatalog.entries(from: store.providers).sorted { $0.blendedPrice < $1.blendedPrice }.prefix(30), id: \.selection) { entry in
                Button {
                    dispatcher.routerModel = entry.selection
                } label: {
                    Text("\(entry.model.name) · \(entry.providerName) · \(Money.format(entry.inputPrice))/Mio.")
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(modelName)
                        .font(Theme.Fonts.sans(11.5, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(dispatcher.routerModel == nil ? "Zentrale · automatisch" : "Zentrale")
                        .font(Theme.Fonts.sans(9.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glass(cornerRadius: 16, tintOpacity: 0.35, shadow: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Modell der Zentrale – am besten ein sehr günstiges")
    }

    private var modelName: String {
        guard let selection = store.dispatcher.effectiveRouterModel else { return "kein Modell" }
        return store.providers?.all.first { $0.id == selection.providerID }?.models[selection.modelID]?.name ?? selection.modelID
    }
}

// MARK: Einstieg

private struct Intro: View {
    let onSuggestion: (String) -> Void
    @State private var appeared = false

    private let examples = [
        ("Welches meiner Modelle ist am besten für SwiftUI-Animationen – und was kostet es?", "questionmark.bubble"),
        ("Baue einen Einstellungsbildschirm mit Dark-Mode-Schalter. Maximal 30 Cent.", "dollarsign.circle"),
        ("Suche 15 Minuten lang nach Concurrency-Warnungen und behebe so viele wie möglich.", "timer"),
        ("Plane die Architektur für eine Offline-Synchronisation, ohne Code zu ändern.", "list.bullet.clipboard"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            EmberMark(size: 60, intensity: 0.8)
            VStack(alignment: .leading, spacing: 8) {
                Text("Was soll erledigt werden?")
                    .font(Theme.Fonts.display)
                Text("Die Zentrale kennt alle deine Modelle, ihre Stärken und Preise. Sie schärft deinen Auftrag, wählt das passende Modell und hält Budget und Zeit ein.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(examples.enumerated()), id: \.offset) { index, item in
                    Button { onSuggestion(item.0) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.1)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 18)
                            Text(item.0)
                                .font(Theme.Fonts.sans(13))
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(RowButtonStyle())
                    .glass(cornerRadius: 12, tintOpacity: 0.25, shadow: false)
                    .modifier(RiseIn(active: !appeared))
                    .animation(Theme.Motion.spring.delay(0.08 * Double(index) + 0.15), value: appeared)
                }
            }
        }
        .padding(.top, 30)
        .onAppear { appeared = true }
    }
}

// MARK: Aufträge

private struct MissionBoard: View {
    @Environment(AppStore.self) private var store
    @State private var showAll = false

    var body: some View {
        let missions = store.dispatcher.missions
        let visible = showAll ? missions : Array(missions.prefix(4))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow("Aufträge")
                Spacer()
                if missions.count > 4 {
                    Button(showAll ? "Weniger" : "Alle \(missions.count)") { withAnimation(Theme.Motion.spring) { showAll.toggle() } }
                        .buttonStyle(PillButtonStyle())
                }
            }
            ForEach(visible) { mission in
                MissionCard(mission: mission)
                    .transition(.riseIn)
            }
        }
    }
}

private struct MissionCard: View {
    @Environment(AppStore.self) private var store
    let mission: Mission

    private var color: Color {
        switch mission.state {
        case .waiting: Theme.textTertiary
        case .running, .wrappingUp: Theme.ochre
        case .done: Theme.sage
        case .stoppedBudget, .stoppedTime: Theme.sand
        case .failed: Theme.clay
        case .cancelled: Theme.smoke
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(alignment: .top, spacing: 14) {
                statusIcon.frame(width: 20, height: 20).padding(.top, 2)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(mission.title)
                            .font(Theme.Fonts.sans(13, .medium))
                            .lineLimit(1)
                        Text(mission.state.title)
                            .font(Theme.Fonts.sans(9.5, .medium))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(color)
                            .contentTransition(.opacity)
                    }
                    Text((mission.escalatedModel.map { "\(mission.model) → \($0)" } ?? mission.model) + " · \(mission.agent) · \(mission.projectName)")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    if let activity = mission.activity {
                        Text(activity)
                            .font(Theme.Fonts.sans(11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }

                    HStack(spacing: 18) {
                        Meter(
                            label: "Kosten",
                            value: Money.format(mission.spentUSD) + (mission.budgetUSD.map { " / " + Money.format($0) } ?? ""),
                            fraction: mission.budgetFraction
                        )
                        Meter(
                            label: "Zeit",
                            value: duration(mission.elapsed) + (mission.timeLimitMinutes.map { " / \(Int($0)) min" } ?? ""),
                            fraction: mission.timeFraction
                        )
                        if let estimate = mission.estimatedCostUSD {
                            Meter(label: "Schätzung", value: Money.format(estimate), fraction: nil)
                        }
                        if let rate = mission.cacheRate {
                            Meter(label: "Zwischenspeicher", value: "\(Int(rate * 100)) %", fraction: nil)
                                .help("Anteil der Eingabe, die der Anbieter aus dem Zwischenspeicher gelesen hat – je höher, desto günstiger.")
                        }
                    }
                }

                Spacer(minLength: 0)

                VStack(spacing: 6) {
                    Button("Öffnen") { Task { await store.open(mission) } }
                        .buttonStyle(PillButtonStyle())
                        .disabled(mission.sessionID.isEmpty)
                    if !mission.state.isFinished {
                        Button("Stoppen") { Task { await store.dispatcher.stop(mission) } }
                            .buttonStyle(PillButtonStyle(tint: Theme.clay))
                    } else {
                        Button { withAnimation(Theme.Motion.spring) { store.dispatcher.remove(mission) } } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .help("Aus der Liste entfernen")
                    }
                }
            }
            .padding(14)
        }
        .glass(cornerRadius: 16, tint: mission.state.isFinished ? Theme.forest : Theme.ember,
               tintOpacity: mission.state.isFinished ? 0.25 : 0.25, shadow: false)
        .animation(Theme.Motion.spring, value: mission.state)
    }

    @ViewBuilder private var statusIcon: some View {
        switch mission.state {
        case .waiting: Image(systemName: "hourglass").foregroundStyle(Theme.textTertiary)
        case .running, .wrappingUp: ForgeSpinner(size: 16)
        case .done: DrawnCheckmark(size: 16)
        case .failed: Image(systemName: "xmark").foregroundStyle(Theme.clay)
        case .stoppedBudget: Image(systemName: "dollarsign.circle").foregroundStyle(Theme.sand)
        case .stoppedTime: Image(systemName: "timer").foregroundStyle(Theme.sand)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(Theme.smoke)
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s < 60 ? "\(s) s" : "\(s / 60):\(String(format: "%02d", s % 60)) min"
    }
}

/// Wert mit schmalem Fortschrittsbalken (Kosten oder Zeit gegen das Limit).
private struct Meter: View {
    let label: String
    let value: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Eyebrow(label)
                Text(value)
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.06))
                        Capsule()
                            .fill(fraction > 0.85 ? Theme.red : Theme.textSecondary)
                            .frame(width: geo.size.width * min(1, max(0.02, fraction)))
                            .animation(Theme.Motion.spring, value: fraction)
                    }
                }
                .frame(width: 120, height: 3)
            }
        }
    }
}

// MARK: Gespräch

private struct DispatchMessageView: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage

    var body: some View {
        let dispatcher = store.dispatcher
        if message.info.isUser {
            HStack {
                Spacer(minLength: 90)
                Text(dispatcher.text(of: message))
                    .font(Theme.Fonts.sans(13.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .glass(cornerRadius: 18, tint: Theme.ember, tintOpacity: 0.35, shadow: false)
            }
        } else if let proposal = dispatcher.proposal(for: message) {
            VStack(alignment: .leading, spacing: 12) {
                if !proposal.reply.isEmpty {
                    MarkdownText(text: proposal.reply)
                }
                if proposal.dispatch {
                    ProposalCard(message: message, proposal: proposal)
                }
                footer
            }
        } else {
            let text = dispatcher.text(of: message)
            VStack(alignment: .leading, spacing: 8) {
                if message.info.time.completed == nil {
                    // Rohes JSON während des Streamens nicht zeigen
                    ShimmerText(text: "schreibt Vorschlag …")
                } else {
                    MarkdownText(text: text)
                }
                if let error = message.info.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(Theme.Fonts.small).foregroundStyle(Theme.clay)
                }
                footer
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let cost = message.info.cost, message.info.time.completed != nil {
            Text("\(message.info.modelLabel ?? "") · \(Money.format(cost, precise: true))")
                .font(Theme.Fonts.sans(10))
                .foregroundStyle(Theme.textTertiary.opacity(0.8))
        }
    }
}

/// Vorschlag der Zentrale: Analyse und ein oder mehrere Teilaufträge – bearbeitbar und startbar.
private struct ProposalCard: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage
    let proposal: Proposal
    @State private var expanded: Int?
    @State private var promptDraft = ""
    @State private var launching = false
    @State private var waitForNight: Bool?

    private var dispatcher: Dispatcher { store.dispatcher }
    private var launched: Bool { dispatcher.isLaunched(message.id) }

    private var rules: [RuleCheck.Result] {
        RuleCheck.check(proposal, entries: ModelCatalog.entries(from: store.providers), budget: dispatcher.budgetUSD ?? proposal.budgetUSD)
    }

    /// Nachttarif nur anbieten, wenn ein Modell davon profitiert und er gerade nicht ohnehin gilt.
    private var offersNight: Bool {
        !Savings.isOffPeak() && proposal.tasks.contains { Savings.hasOffPeakPricing($0.model) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: proposal.tasks.count > 1 ? "square.stack.3d.up" : "paperplane")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                Text(proposal.title ?? "Auftrag")
                    .font(Theme.Fonts.sans(14, .medium))
                if proposal.tasks.count > 1 {
                    Text("\(proposal.tasks.count) Agenten")
                        .font(Theme.Fonts.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if let cost = proposal.estimatedCostUSD {
                    Text("≈ " + Money.format(cost))
                        .font(Theme.Fonts.mono(12, .medium))
                        .foregroundStyle(overBudget ? Theme.red : Theme.textSecondary)
                }
                if let minutes = proposal.estimatedMinutes {
                    Text("≈ \(Int(minutes)) min")
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if let analysis = proposal.analysis {
                Text(analysis)
                    .font(Theme.Fonts.sans(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                ForEach(proposal.tasks) { task in
                    TaskRow(
                        task: task, allTasks: proposal.tasks, isExpanded: expanded == task.id, locked: launched,
                        promptDraft: $promptDraft,
                        onToggle: {
                            withAnimation(Theme.Motion.spring) {
                                if expanded == task.id { commitPrompt(task.id); expanded = nil }
                                else { commitPrompt(expanded); promptDraft = task.prompt; expanded = task.id }
                            }
                        },
                        onModel: { model in change(task.id) { $0.model = model } },
                        onAgent: { agent in change(task.id) { $0.agent = agent } }
                    )
                }
            }

            if let reason = proposal.reason {
                Text(reason)
                    .font(Theme.Fonts.sans(11.5, .light))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            RuleSummary(results: rules)

            if offersNight, !launched {
                Toggle(isOn: Binding(get: { waitForNight ?? !proposal.urgent }, set: { waitForNight = $0 })) {
                    Text("Auf den Nachttarif warten · Start \(Savings.clock(Savings.offPeakStart)) Uhr")
                        .font(Theme.Fonts.sans(11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.green)
                .help("DeepSeek berechnet nachts deutlich weniger. Nicht eilige Aufträge starten dann automatisch.")
            }

            if proposal.tasks.count == 1, !proposal.alternatives.isEmpty, !launched {
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow("Alternativen")
                    ForEach(proposal.alternatives, id: \.self) { alt in
                        Button {
                            change(0) { $0.model = alt.model; $0.estimatedCostUSD = alt.estimatedCostUSD ?? $0.estimatedCostUSD }
                        } label: {
                            HStack(spacing: 8) {
                                Text(alt.model).font(Theme.Fonts.mono(11))
                                if let cost = alt.estimatedCostUSD { Text("≈ " + Money.format(cost)).font(Theme.Fonts.mono(11)).foregroundStyle(Theme.textSecondary) }
                                if let note = alt.note { Text(note).font(Theme.Fonts.sans(11)).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                                Spacer()
                                Image(systemName: "arrow.left.arrow.right").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
            }

            HStack(spacing: 10) {
                Label(limitText, systemImage: "gauge.with.dots.needle.33percent")
                    .font(Theme.Fonts.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if launched {
                    Label("Gestartet", systemImage: "checkmark")
                        .font(Theme.Fonts.sans(12, .medium))
                        .foregroundStyle(Theme.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button {
                        commitPrompt(expanded)
                        expanded = nil
                        launching = true
                        Task {
                            await dispatcher.launch(dispatcher.proposal(for: message) ?? proposal, from: message.id,
                                                    waitForOffPeak: offersNight && (waitForNight ?? !proposal.urgent))
                            launching = false
                        }
                    } label: {
                        Label(launching ? "Startet …" : (proposal.tasks.count > 1 ? "Alle starten" : "Auftrag starten"), systemImage: "play.fill")
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(launching)
                }
            }
        }
        .padding(16)
        .glass(cornerRadius: 18, tintOpacity: 0)
        .animation(Theme.Motion.spring, value: launched)
    }

    /// Ändert einen Teilauftrag und merkt sich die bearbeitete Fassung des Vorschlags.
    private func change(_ taskID: Int, _ edit: (inout Proposal.TaskPlan) -> Void) {
        var edited = dispatcher.proposal(for: message) ?? proposal
        guard let index = edited.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        edit(&edited.tasks[index])
        let sum = edited.tasks.compactMap(\.estimatedCostUSD).reduce(0, +)
        if sum > 0 { edited.estimatedCostUSD = sum }
        withAnimation(Theme.Motion.snappy) { dispatcher.edits[message.id] = edited }
    }

    private func commitPrompt(_ taskID: Int?) {
        guard let taskID, let task = proposal.tasks.first(where: { $0.id == taskID }), promptDraft != task.prompt, !promptDraft.isEmpty else { return }
        let draft = promptDraft
        change(taskID) { $0.prompt = draft }
    }

    private var overBudget: Bool {
        guard let cost = proposal.estimatedCostUSD, let budget = dispatcher.budgetUSD ?? proposal.budgetUSD else { return false }
        return cost > budget
    }

    private var limitText: String {
        let budget = (dispatcher.budgetUSD ?? proposal.budgetUSD).map { "Budget " + Money.format($0) } ?? "ohne Budget"
        let time = (dispatcher.timeLimitMinutes ?? proposal.timeLimitMinutes).map { "\(Int($0)) min je Agent" } ?? "ohne Zeitlimit"
        return "\(budget) · \(time)"
    }
}

/// Ergebnis der Regelprüfung: ruhig, wenn alles passt – Verstöße einzeln in Rot.
private struct RuleSummary: View {
    let results: [RuleCheck.Result]

    var body: some View {
        let failed = results.filter { !$0.ok }
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if failed.isEmpty {
                    Label("Sparregeln eingehalten", systemImage: "checkmark")
                        .foregroundStyle(Theme.green.opacity(0.85))
                        .help(results.map { "✓ \($0.title): \($0.detail)" }.joined(separator: "\n"))
                } else {
                    ForEach(failed) { result in
                        Label("\(result.title): \(result.detail)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Unbekannte Modelle und fehlender Denkaufwand werden beim Start automatisch korrigiert.")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(Theme.Fonts.sans(11))
        }
    }
}

/// Eine Zeile pro Teilauftrag: Agent, Modell, Kosten, Abhängigkeiten – aufklappbar zum Prompt.
private struct TaskRow: View {
    @Environment(AppStore.self) private var store
    let task: Proposal.TaskPlan
    let allTasks: [Proposal.TaskPlan]
    let isExpanded: Bool
    let locked: Bool
    @Binding var promptDraft: String
    let onToggle: () -> Void
    let onModel: (String) -> Void
    let onAgent: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgentAvatar(name: task.agent)
                    .scaleEffect(0.85)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(Theme.Fonts.sans(13, .medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        agentMenu
                        Text("·").foregroundStyle(Theme.textTertiary)
                        modelMenu
                        if !task.dependsOn.isEmpty {
                            Text("· nach " + task.dependsOn.compactMap { dep in allTasks.first { $0.id == dep }?.title }.joined(separator: ", "))
                                .font(Theme.Fonts.sans(11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: 10) {
                        Label("Denken: \((task.effort ?? .medium).title)", systemImage: "brain")
                        if let stronger = task.escalateTo, Savings.cascade {
                            Label("bei Fehlschlag → \(stronger.split(separator: "/").last ?? "")", systemImage: "arrow.up.forward")
                                .help("Scheitern Build oder Tests, übernimmt \(stronger).")
                        }
                    }
                    .font(Theme.Fonts.sans(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                }
                Spacer()
                if let cost = task.estimatedCostUSD {
                    Text(Money.format(cost))
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Button(action: onToggle) {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Prompt ansehen und bearbeiten")
            }
            if isExpanded {
                TextEditor(text: $promptDraft)
                    .font(Theme.Fonts.mono(11.5))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 120)
                    .background(Theme.black, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                    .disabled(locked)
                    .transition(.opacity)
            }
        }
        .padding(10)
        .background(Theme.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
    }

    private var agentMenu: some View {
        Menu {
            ForEach(store.primaryAgents) { agent in
                Button(agent.displayName) { onAgent(agent.name) }
            }
        } label: {
            Text(store.agents.first { $0.name == task.agent }?.displayName ?? task.agent)
                .font(Theme.Fonts.sans(11))
                .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(locked)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(ModelCatalog.entries(from: store.providers).filter(\.model.supportsTools).sorted { $0.blendedPrice < $1.blendedPrice }, id: \.selection) { entry in
                Button("\(entry.model.name) · \(entry.providerName) · \(Money.format(entry.inputPrice))/Mio.") {
                    onModel(entry.selection.label)
                }
            }
        } label: {
            Text(task.model)
                .font(Theme.Fonts.mono(10.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(locked)
    }
}

// MARK: Eingabe

private struct DispatchComposer: View {
    @Environment(AppStore.self) private var store
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding

    private var dispatcher: Dispatcher { store.dispatcher }
    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Auftrag oder Frage an die Zentrale …", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.sans(14))
                .lineLimit(1...8)
                .focused(focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        draft.append("\n")
                    } else {
                        submit()
                    }
                    return .handled
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)

            HStack(spacing: 6) {
                budgetMenu
                timeMenu
                Toggle(isOn: Binding(get: { dispatcher.autoStart }, set: { dispatcher.autoStart = $0 })) {
                    Text("Direkt starten").font(Theme.Fonts.sans(11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.green)
                .foregroundStyle(Theme.textTertiary)
                .help("Vorschläge ohne Rückfrage sofort starten")
                Spacer()
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(IconButtonStyle(size: 32, filled: hasText ? Theme.ochre : Color.white.opacity(0.06)))
                .disabled(!hasText || dispatcher.isThinking)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background { ComposerAura(isWorking: dispatcher.isThinking || !dispatcher.runningMissions.isEmpty) }
        .glass(cornerRadius: 22, tintOpacity: 0)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color(hex: 0x3A3A3A), lineWidth: 1)
                .opacity(focused.wrappedValue ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(Theme.Motion.gentle, value: focused.wrappedValue)
        .animation(Theme.Motion.snappy, value: hasText)
    }

    private func submit() {
        guard hasText, !dispatcher.isThinking else { return }
        let text = draft
        draft = ""
        Task { await dispatcher.send(text) }
    }

    private var budgetMenu: some View {
        Menu {
            Button("Kein festes Budget") { dispatcher.budgetUSD = nil }
            Divider()
            ForEach([0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10], id: \.self) { value in
                Button("max. " + Money.formatEUR(value)) { dispatcher.budgetUSD = Money.usd(fromEUR: value) }
            }
        } label: {
            chip(symbol: "eurosign.circle", text: dispatcher.budgetUSD.map { "max. " + Money.format($0) } ?? "Budget", active: dispatcher.budgetUSD != nil)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Höchstbetrag pro Auftrag – bei 85 % wird geordnet abgeschlossen, bei 100 % gestoppt")
    }

    private var timeMenu: some View {
        Menu {
            Button("Kein Zeitlimit") { dispatcher.timeLimitMinutes = nil }
            Divider()
            ForEach([2.0, 5, 10, 15, 30, 60, 120], id: \.self) { value in
                Button("max. \(Int(value)) Minuten") { dispatcher.timeLimitMinutes = value }
            }
        } label: {
            chip(symbol: "timer", text: dispatcher.timeLimitMinutes.map { "max. \(Int($0)) min" } ?? "Zeit", active: dispatcher.timeLimitMinutes != nil)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Höchstdauer pro Auftrag – kurz vor Ablauf wird geordnet abgeschlossen, danach gestoppt")
    }

    private func chip(symbol: String, text: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(Theme.Fonts.sans(11))
        .foregroundStyle(active ? Theme.ochre : Theme.textTertiary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(active ? Theme.ochre.opacity(0.12) : .white.opacity(0.04)))
    }
}
