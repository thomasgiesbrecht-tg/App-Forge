import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var dropTargeted = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ChatHeader()
                transcript
                bottomBar
            }
            .overlay {
                if dropTargeted {
                    DropOverlay().transition(.opacity)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let new = urls.compactMap(AttachmentFactory.from(url:))
                withAnimation(Theme.Motion.bouncy) { store.addAttachments(new) }
                composerFocused = true
                return !new.isEmpty
            } isTargeted: { targeted in
                withAnimation(Theme.Motion.snappy) { dropTargeted = targeted }
            }

            if store.inspectorVisible {
                InspectorView()
                    .frame(width: 340)
                    .background(Theme.black)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.spring, value: store.inspectorVisible)
        .onAppear { composerFocused = true }
    }

    // MARK: Verlauf

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if store.currentMessages.isEmpty {
                        WelcomeView { suggestion in
                            draft = suggestion
                            composerFocused = true
                        }
                        .transition(.riseIn)
                    }

                    let messages = store.currentMessages
                    let queued = store.queuedMessageIDs
                    let streamingID = store.streamingMessageID
                    let revertIndex = store.revertedFromMessageID.flatMap { id in messages.firstIndex { $0.id == id } }
                    let turnEnds = turnEndings(messages)

                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let isReverted = revertIndex.map { index >= $0 } ?? false
                        VStack(alignment: .leading, spacing: 10) {
                            MessageRow(
                                message: message,
                                isQueued: queued.contains(message.id),
                                isStreaming: message.id == streamingID,
                                canRewind: store.currentActivity == .idle && revertIndex == nil,
                                onRevert: { Task { await store.revert(to: message.id) } },
                                onEdit: {
                                    Task {
                                        draft = await store.edit(message)
                                        composerFocused = true
                                    }
                                }
                            )
                            if let turn = turnEnds[message.id], !turn.info.fileChanges.isEmpty, !isReverted {
                                ChangesChip(changes: turn.info.fileChanges) {
                                    store.inspectorTab = .changes
                                    store.inspectorVisible = true
                                }
                            }
                        }
                        .dimmed(isReverted)
                        .allowsHitTesting(!isReverted)
                        .id(message.id)
                        .transition(.riseIn)
                    }

                    ForEach(store.media.jobs(for: store.selectedSessionID)) { job in
                        MediaJobView(job: job)
                            .transition(.riseIn)
                    }

                    if store.showsThinkingIndicator {
                        HStack(spacing: 10) {
                            BreathingDots()
                            ShimmerText(text: store.selectedAgent == "build" ? "denkt nach" : "\(store.selectedAgentInfo?.displayName ?? "Agent") denkt nach")
                        }
                        .transition(.riseIn)
                    }

                    if case .retry(let reason) = store.currentActivity {
                        Label(reason, systemImage: "arrow.clockwise")
                            .font(Theme.Fonts.small)
                            .foregroundStyle(Theme.ochre)
                            .transition(.riseIn)
                    }

                    if let error = store.sessionError(store.selectedSessionID) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Theme.Fonts.small)
                            .foregroundStyle(Theme.clay)
                            .textSelection(.enabled)
                            .padding(12)
                            .glass(cornerRadius: 12, tint: Theme.clay, tintOpacity: 0.1, shadow: false)
                            .transition(.riseIn)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .animation(Theme.Motion.spring, value: store.currentMessages.count)
                .animation(Theme.Motion.spring, value: store.showsThinkingIndicator)
                .animation(Theme.Motion.gentle, value: store.revertedFromMessageID)
                .animation(Theme.Motion.spring, value: store.media.jobs.map(\.id))
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .overlay { EdgeFade() }
            .onChange(of: store.currentMessages.last?.parts.last?.text) {
                withAnimation(Theme.Motion.gentle) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.currentMessages.count) {
                withAnimation(Theme.Motion.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Ordnet jeder Nutzer-Nachricht die letzte Antwort ihres Durchgangs zu – dort erscheint der Änderungs-Chip.
    private func turnEndings(_ messages: [ChatMessage]) -> [String: ChatMessage] {
        var lastAnswer: [String: String] = [:]
        for message in messages where !message.info.isUser {
            if let parent = message.info.parentID { lastAnswer[parent] = message.id }
        }
        var result: [String: ChatMessage] = [:]
        for message in messages where message.info.isUser {
            if let answer = lastAnswer[message.id] { result[answer] = message }
        }
        return result
    }

    // MARK: Unten

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if store.revertedFromMessageID != nil {
                RevertBanner()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if store.canImplementPlan {
                PlanBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ForEach(store.currentPermissions) { request in
                PermissionBanner(request: request)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Composer(draft: $draft, focused: $composerFocused)
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .animation(Theme.Motion.bouncy, value: store.currentPermissions.map(\.id))
        .animation(Theme.Motion.spring, value: store.revertedFromMessageID)
        .animation(Theme.Motion.spring, value: store.canImplementPlan)
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Theme.ochre.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.ember.opacity(0.15)))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 30, weight: .ultraLight))
                        .symbolEffect(.bounce, options: .repeating)
                    Text("Loslassen, um anzuhängen")
                        .font(Theme.Fonts.sans(14, .light))
                }
                .foregroundStyle(Theme.sand)
            }
            .padding(8)
            .allowsHitTesting(false)
    }
}

// MARK: Kopfzeile

private struct ChatHeader: View {
    @Environment(AppStore.self) private var store

    private var title: String {
        let title = store.currentSession?.title ?? ""
        return title.isEmpty ? "Neuer Chat" : title
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(Theme.Motion.spring) { store.sidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .padding(.leading, store.sidebarVisible ? 0 : 70) // Platz für die Ampel-Knöpfe
            .help("Seitenleiste (⌃⌘S)")
            .accessibilityLabel("Seitenleiste ein- oder ausblenden")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Fonts.title)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                if let path = store.selectedProject {
                    let info = ProjectInfoCache.info(for: path)
                    HStack(spacing: 5) {
                        AppIconView(info: info, size: 14)
                        Text(info.appName)
                    }
                    .font(Theme.Fonts.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            .animation(Theme.Motion.gentle, value: title)

            Spacer(minLength: 16)

            AgentPill()
            PlatformSwitcher()
            ModelPill()
            InspectorToggles()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
    }
}

private struct InspectorToggles: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            toggle(.simulator, symbol: "iphone.gen3", help: "Simulator")
            toggle(.changes, symbol: "plusminus", help: "Änderungen")
                .overlay(alignment: .topTrailing) {
                    let count = store.currentChanges.count
                    if count > 0 {
                        Text("\(count)")
                            .font(Theme.Fonts.sans(8.5, .semibold))
                            .foregroundStyle(Theme.void)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Capsule().fill(Theme.ochre))
                            .offset(x: 3, y: -2)
                            .transition(.scale.combined(with: .opacity))
                            .contentTransition(.numericText())
                    }
                }
        }
        .animation(Theme.Motion.bouncy, value: store.currentChanges.count)
    }

    private func toggle(_ tab: AppStore.InspectorTab, symbol: String, help: String) -> some View {
        let active = store.inspectorVisible && store.inspectorTab == tab
        return Button {
            withAnimation(Theme.Motion.spring) {
                if active { store.inspectorVisible = false } else { store.inspectorTab = tab; store.inspectorVisible = true }
            }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(IconButtonStyle(size: 30, tint: active ? Theme.ochre : Theme.textSecondary))
        .help(help)
    }
}

/// Agenten-Auswahl (Bauen, Planen, Koordinator …).
private struct AgentPill: View {
    @Environment(AppStore.self) private var store
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(store.primaryAgents) { agent in
                Button {
                    withAnimation(Theme.Motion.snappy) { store.selectedAgent = agent.name }
                } label: {
                    Label(agent.displayName, systemImage: agent.name == store.selectedAgent ? "checkmark" : symbol(for: agent))
                }
            }
            Divider()
            SettingsLink { Text("Agenten verwalten …") }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol(for: store.selectedAgentInfo))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(store.selectedAgentInfo?.displayName ?? "Bauen")
                    .font(Theme.Fonts.sans(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glass(cornerRadius: 16, tintOpacity: hovering ? 0.2 : 0.35, shadow: false)
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Theme.Motion.snappy, value: hovering)
        .help("Agent – bestimmt Rolle, Werkzeuge und ggf. Modell")
    }

    private func symbol(for agent: AgentInfo?) -> String {
        switch agent?.name {
        case "build", nil: "hammer"
        case "plan": "list.bullet.clipboard"
        case "koordinator": "person.3"
        default: "person.crop.circle"
        }
    }
}

/// Segment-Schalter mit gleitender Glas-Markierung.
private struct PlatformSwitcher: View {
    @Environment(AppStore.self) private var store
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TargetPlatform.allCases) { platform in
                let selected = store.platform == platform
                Button {
                    withAnimation(Theme.Motion.bouncy) { store.platform = platform }
                } label: {
                    Image(systemName: platform.symbol)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                        .frame(width: 32, height: 26)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Theme.pine)
                                    .overlay(Capsule().strokeBorder(Theme.line))
                                    .matchedGeometryEffect(id: "platform", in: indicator)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(platform.title)
            }
        }
        .padding(3)
        .glass(cornerRadius: 16, tintOpacity: 0.35, shadow: false)
    }
}

/// Modell-Auswahl als Glas-Kapsel.
private struct ModelPill: View {
    @Environment(AppStore.self) private var store
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(store.connectedProviders) { provider in
                Menu(provider.name) {
                    ForEach(provider.sortedModels) { model in
                        Button {
                            withAnimation(Theme.Motion.snappy) {
                                store.selectedModel = ModelSelection(providerID: provider.id, modelID: model.id)
                            }
                        } label: {
                            let selected = store.selectedModel == ModelSelection(providerID: provider.id, modelID: model.id)
                            Label(model.name + (model.supportsTools ? "" : "  – ohne Tools"),
                                  systemImage: selected ? "checkmark" : (model.supportsImages ? "eye" : "text.bubble"))
                        }
                    }
                }
            }
            Divider()
            SettingsLink { Text("Anbieter verwalten …") }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.selectedModel == nil ? Theme.orange : Theme.textTertiary)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.selectedModelInfo?.name ?? "Modell wählen")
                        .font(Theme.Fonts.sans(12, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.opacity)
                    if let provider = store.selectedModel?.providerID {
                        Text(provider)
                            .font(Theme.Fonts.sans(9.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glass(cornerRadius: 16, tintOpacity: hovering ? 0.2 : 0.35, shadow: false)
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Theme.Motion.snappy, value: hovering)
        .help(store.selectedModel?.label ?? "Kein Modell ausgewählt")
    }
}

// MARK: Begrüßung

private struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    let onSuggestion: (String) -> Void
    @State private var appeared = false

    private let suggestions = [
        ("sparkles", "Lege eine neue SwiftUI-App mit Onboarding an"),
        ("hammer", "Baue das Projekt und behebe alle Fehler"),
        ("ipad.landscape", "Passe die Oberfläche fürs iPad an"),
        ("text.magnifyingglass", "@lektor prüfe alle Texte der App"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            EmberMark(size: 56, intensity: 0.7)
            VStack(alignment: .leading, spacing: 8) {
                Text("Was bauen wir heute?")
                    .font(Theme.Fonts.display)
                Text("Jedes Modell hat dieselben Werkzeuge: Dateien, Terminal, Xcode, Simulator, Skills und Agenten.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                    Button { onSuggestion(item.1) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.0)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 18)
                            Text(item.1)
                                .font(Theme.Fonts.sans(13))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(RowButtonStyle())
                    .glass(cornerRadius: 12, tintOpacity: 0.25, shadow: false)
                    .modifier(RiseIn(active: !appeared))
                    .animation(Theme.Motion.spring.delay(0.08 * Double(index) + 0.2), value: appeared)
                }
            }

            if store.connectedProviders.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "key").foregroundStyle(Theme.ochre)
                    Text("Noch kein Anbieter verbunden.")
                        .foregroundStyle(Theme.textSecondary)
                    SettingsLink { Text("API-Schlüssel hinterlegen") }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
                .font(Theme.Fonts.small)
            }
        }
        .padding(.top, 40)
        .onAppear { appeared = true }
    }
}

// MARK: Leisten über dem Eingabefeld

private struct RevertBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(Theme.sage)
            VStack(alignment: .leading, spacing: 2) {
                Text("Zurückgesetzt")
                    .font(Theme.Fonts.sans(12.5, .medium))
                Text("Dateien sind auf dem früheren Stand. Eine neue Nachricht verwirft die ausgegrauten Schritte endgültig.")
                    .font(Theme.Fonts.sans(11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Wiederherstellen") { Task { await store.unrevert() } }
                .buttonStyle(PillButtonStyle(prominent: true, tint: Theme.sage))
        }
        .padding(14)
        .glass(cornerRadius: 18, tint: Theme.moss, tintOpacity: 0.2)
    }
}

private struct PlanBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Theme.sage)
            Text("Der Plan steht. Passt er?")
                .font(Theme.Fonts.sans(12.5, .medium))
            Spacer()
            Text("Oder schreib, was geändert werden soll.")
                .font(Theme.Fonts.sans(11))
                .foregroundStyle(Theme.textTertiary)
            Button("Plan umsetzen") { Task { await store.implementPlan() } }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
        .padding(14)
        .glass(cornerRadius: 18, tint: Theme.moss, tintOpacity: 0.2)
    }
}

// MARK: Eingabe

private struct Composer: View {
    @Environment(AppStore.self) private var store
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    @State private var isImporting = false

    private var isBusy: Bool { store.currentActivity != .idle }
    private var hasContent: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.attachments.isEmpty }

    /// `@teil` am Ende der Eingabe → passende Unteragenten vorschlagen.
    private var mentionQuery: String? {
        guard let last = draft.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst()).lowercased()
    }

    /// `/` am Anfang → Befehle vorschlagen.
    private var slashSuggestions: [MediaKind] {
        guard draft.hasPrefix("/"), !draft.contains(" ") else { return [] }
        return [MediaKind.image, .video].filter { $0.command.hasPrefix(draft.lowercased()) }
    }

    private var mentionSuggestions: [AgentInfo] {
        guard let query = mentionQuery else { return [] }
        return store.subagents.filter { query.isEmpty || $0.name.lowercased().hasPrefix(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !slashSuggestions.isEmpty {
                SlashSuggestions(kinds: slashSuggestions, hasImage: store.attachments.contains(where: \.isImage)) { kind in
                    draft = kind.command + " "
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !mentionSuggestions.isEmpty {
                MentionSuggestions(agents: mentionSuggestions) { agent in
                    var words = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                    words[words.count - 1] = "@\(agent.name) "
                    draft = words.joined(separator: " ")
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if isBusy {
                Text(hasContent
                     ? "↩ nachreichen – wird nach dem aktuellen Schritt berücksichtigt  ·  ⌘↩ sofort unterbrechen"
                     : "Die KI arbeitet – du kannst jederzeit weitere Anweisungen schicken.")
                    .font(Theme.Fonts.sans(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .contentTransition(.opacity)
            }

            VStack(alignment: .leading, spacing: 0) {
                if !store.attachments.isEmpty {
                    AttachmentStrip()
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                TextField(isBusy ? "Änderung oder Ergänzung …" : "Beschreibe, was entstehen soll …  (@ für Agenten)",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.sans(14))
                    .lineLimit(1...10)
                    .focused(focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                            draft.append("\n")
                        } else if let first = mentionSuggestions.first, mentionQuery?.isEmpty == false {
                            var words = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                            words[words.count - 1] = "@\(first.name) "
                            draft = words.joined(separator: " ")
                        } else {
                            submit(interrupt: press.modifiers.contains(.command))
                        }
                        return .handled
                    }
                    .onPasteCommand(of: [.image, .fileURL, .png, .tiff]) { _ in
                        let pasted = AttachmentFactory.fromPasteboard()
                        withAnimation(Theme.Motion.bouncy) { store.addAttachments(pasted) }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                HStack(spacing: 6) {
                    Button { isImporting = true } label: { Image(systemName: "paperclip") }
                        .buttonStyle(IconButtonStyle(size: 28))
                        .help("Dateien oder Bilder anhängen (auch per Drag & Drop oder ⌘V)")

                    PermissionModePill()

                    if let model = store.selectedModelInfo, store.attachments.contains(where: \.isImage), !model.supportsImages {
                        Label("\(model.name) sieht keine Bilder", systemImage: "eye.slash")
                            .font(Theme.Fonts.sans(10.5))
                            .foregroundStyle(Theme.clay)
                            .transition(.opacity)
                    }

                    Spacer()

                    if isBusy {
                        Button { Task { await store.abort() } } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(IconButtonStyle(size: 32, tint: Theme.clay))
                        .help("Aktuelle Arbeit abbrechen")
                        .transition(.scale.combined(with: .opacity))
                    }

                    Button { submit(interrupt: false) } label: {
                        Image(systemName: isBusy ? "plus" : "arrow.up")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(IconButtonStyle(size: 32, filled: hasContent ? Theme.ochre : Color.white.opacity(0.06)))
                    .disabled(!hasContent)
                    .help(isBusy ? "Nachreichen (↩) – ⌘↩ unterbricht und sendet sofort" : "Senden (↩)")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .background { ComposerAura(isWorking: isBusy) }
            .glass(cornerRadius: 22, tintOpacity: 0)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(hex: 0x3A3A3A), lineWidth: 1)
                    .opacity(focused.wrappedValue ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let new = urls.compactMap { url -> Attachment? in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return AttachmentFactory.from(url: url)
            }
            withAnimation(Theme.Motion.bouncy) { store.addAttachments(new) }
        }
        .animation(Theme.Motion.spring, value: isBusy)
        .animation(Theme.Motion.snappy, value: hasContent)
        .animation(Theme.Motion.spring, value: store.attachments.count)
        .animation(Theme.Motion.snappy, value: mentionSuggestions.map(\.name))
        .animation(Theme.Motion.snappy, value: slashSuggestions)
        .animation(Theme.Motion.gentle, value: focused.wrappedValue)
    }

    private func submit(interrupt: Bool) {
        let text = draft
        guard hasContent else { return }
        draft = ""
        Task {
            if interrupt && isBusy { await store.interruptAndSend(text) } else { await store.send(text) }
        }
    }
}

private struct AttachmentStrip: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(store.attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        withAnimation(Theme.Motion.bouncy) { store.removeAttachment(attachment) }
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .scrollIndicators(.never)
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let data = attachment.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: attachment.mime == "application/pdf" ? "doc.richtext" : "doc.text")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(Theme.ochre)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.void.opacity(0.4)))
            }
            Text(attachment.filename)
                .font(Theme.Fonts.sans(11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(4)
        .padding(.trailing, 8)
        .glass(cornerRadius: 11, tintOpacity: 0.3, shadow: false)
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.void)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.bone))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .opacity(hovering ? 1 : 0)
            .scaleEffect(hovering ? 1 : 0.5)
        }
        .onHover { hovering = $0 }
        .animation(Theme.Motion.bouncy, value: hovering)
    }
}

private struct SlashSuggestions: View {
    let kinds: [MediaKind]
    let hasImage: Bool
    let onPick: (MediaKind) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "slash.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ochre)
            ForEach(kinds, id: \.self) { kind in
                Button { onPick(kind) } label: {
                    Label("\(kind.command)  \(detail(kind))", systemImage: kind.symbol)
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .padding(.leading, 14)
    }

    private func detail(_ kind: MediaKind) -> String {
        let action = switch kind {
        case .image: hasImage ? "angehängtes Bild bearbeiten" : "Bild erzeugen"
        case .video: hasImage ? "angehängtes Bild animieren" : "Video erzeugen"
        }
        guard let cost = MediaSettings.current.estimatedCost(kind) else { return action }
        return action + String(format: " · ≈ $%.2f", cost)
    }
}

private struct MentionSuggestions: View {
    let agents: [AgentInfo]
    let onPick: (AgentInfo) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "at")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ochre)
            ForEach(agents) { agent in
                Button { onPick(agent) } label: {
                    Text(agent.displayName)
                }
                .buttonStyle(PillButtonStyle())
                .help(agent.description ?? "")
            }
        }
        .padding(.leading, 14)
    }
}

private struct PermissionModePill: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases) { mode in
                Button {
                    withAnimation(Theme.Motion.snappy) { store.permissionMode = mode }
                } label: {
                    Label(mode.title, systemImage: mode == store.permissionMode ? "checkmark" : mode.symbol)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: store.permissionMode.symbol)
                    .contentTransition(.symbolEffect(.replace))
                Text(store.permissionMode.title)
            }
            .font(Theme.Fonts.sans(11))
            .foregroundStyle(store.permissionMode == .full ? Theme.clay : Theme.textTertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.04)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.permissionMode.detail)
    }
}

// MARK: Berechtigungen

private struct PermissionBanner: View {
    @Environment(AppStore.self) private var store
    let request: PermissionRequest
    @State private var pulse = false
    @State private var showDiff = false

    private var diff: String? { request.metadata?["diff"]?.stringValue }

    private var title: String {
        switch request.permission {
        case "edit", "write": "Datei ändern"
        case "bash": "Befehl ausführen"
        case "external_directory": "Zugriff außerhalb des Projekts"
        case "webfetch": "Webseite laden"
        default: request.permission
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Theme.ochre)
                    .symbolEffect(.pulse, options: .repeating)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Freigabe nötig · \(title)")
                        .font(Theme.Fonts.sans(12.5, .medium))
                    if !request.patterns.isEmpty {
                        Text(request.patterns.joined(separator: "\n"))
                            .font(Theme.Fonts.mono(10.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if diff != nil {
                    Button(showDiff ? "Weniger" : "Änderung ansehen") {
                        withAnimation(Theme.Motion.spring) { showDiff.toggle() }
                    }
                    .buttonStyle(PillButtonStyle())
                }
                Button("Ablehnen") { Task { await store.reply(to: request, .reject) } }
                    .buttonStyle(PillButtonStyle())
                Button("Immer") { Task { await store.reply(to: request, .always) } }
                    .buttonStyle(PillButtonStyle())
                Button("Erlauben") { Task { await store.reply(to: request, .once) } }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
            if showDiff, let diff {
                DiffText(patch: diff)
                    .frame(maxHeight: 220)
                    .transition(.asymmetric(insertion: .riseIn, removal: .opacity))
            }
        }
        .padding(14)
        .glass(cornerRadius: 18, tint: Theme.ember, tintOpacity: 0.3)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.ochre.opacity(pulse ? 0.55 : 0.15), lineWidth: 1)
                .animation(.easeInOut(duration: 1.2).repeatForever(), value: pulse)
        }
        .onAppear { pulse = true }
    }
}
