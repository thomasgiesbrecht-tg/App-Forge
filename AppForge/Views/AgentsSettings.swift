import SwiftUI

/// Agenten anlegen und bearbeiten. Jeder Agent kann ein eigenes Modell eines beliebigen Anbieters nutzen.
struct AgentsSettings: View {
    @Environment(AppStore.self) private var store
    @State private var editing: AgentDefinition?
    @State private var editingOriginalName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agenten sind Rollen mit eigenen Anweisungen, Rechten und – wenn du willst – eigenem Modell. Hauptagenten wählst du im Chat oben aus, Unteragenten werden beauftragt oder mit @Name gerufen.")
                .font(Theme.Fonts.small)
                .foregroundStyle(Theme.textSecondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.agentDefinitions) { agent in
                        AgentRow(agent: agent) {
                            editingOriginalName = agent.name
                            editing = agent
                        }
                    }
                }
            }
            .scrollIndicators(.never)

            HStack {
                Menu {
                    ForEach(AgentLibrary.Template.allCases) { template in
                        Button {
                            editingOriginalName = nil
                            editing = template.make(connectors: store.connectors)
                        } label: {
                            Label(template.title, systemImage: template.symbol)
                        }
                    }
                } label: {
                    Label("Neuer Agent", systemImage: "plus")
                }
                .menuStyle(.button)
                .fixedSize()

                if AgentLibrary.starters.contains(where: { starter in !store.agentDefinitions.contains { $0.name == starter.name } }) {
                    Button("Starter-Team wiederherstellen") { Task { await store.restoreStarterAgents() } }
                        .buttonStyle(PillButtonStyle())
                }
                Spacer()
                Text("Eingebaut: Bauen, Planen, Allgemein, Erkunden")
                    .font(Theme.Fonts.sans(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding()
        .sheet(item: $editing) { agent in
            AgentEditor(agent: agent, originalName: editingOriginalName)
        }
        .task { await store.refreshMeta() }
    }
}

private struct AgentRow: View {
    let agent: AgentDefinition
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(alignment: .top, spacing: 12) {
                AgentAvatar(name: agent.name)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(agent.displayName)
                            .font(Theme.Fonts.sans(13, .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text(agent.role.title)
                            .font(Theme.Fonts.sans(9.5, .medium))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(agent.role == .subagent ? Theme.sage : Theme.ochre)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.05)))
                    }
                    Text(agent.description)
                        .font(Theme.Fonts.sans(11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    HStack(spacing: 10) {
                        Label(agent.model ?? "Modell aus dem Chat", systemImage: "cpu")
                        if !agent.canEdit { Label("liest nur", systemImage: "eye") }
                        if agent.canDelegate { Label("beauftragt andere", systemImage: "arrow.triangle.branch") }
                    }
                    .font(Theme.Fonts.sans(10))
                    .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
        }
        .buttonStyle(RowButtonStyle())
        .glass(cornerRadius: 14, tintOpacity: 0.3, shadow: false)
    }
}

private struct AgentEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var agent: AgentDefinition
    let originalName: String?
    @State private var confirmDelete = false

    private var nameIsValid: Bool {
        let slug = AgentDefinition.slug(agent.name)
        let builtIn = ["build", "plan", "general", "explore", "scout", "compaction", "title", "summary"]
        let taken = store.agentDefinitions.contains { $0.name == slug && $0.name != originalName }
        return !slug.isEmpty && !builtIn.contains(slug) && !taken
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AgentAvatar(name: agent.name.isEmpty ? "?" : agent.name)
                Text(originalName == nil ? "Neuer Agent" : "Agent bearbeiten")
                    .font(Theme.Fonts.sans(18, .light))
            }

            Form {
                TextField("Name", text: $agent.name, prompt: Text("z. B. ui-designer"))
                if !agent.name.isEmpty {
                    Text(nameIsValid ? "Aufruf im Chat: @\(AgentDefinition.slug(agent.name))" : "Name ist schon vergeben oder reserviert.")
                        .font(Theme.Fonts.sans(10.5))
                        .foregroundStyle(nameIsValid ? Theme.textTertiary : Theme.clay)
                }
                TextField("Beschreibung", text: $agent.description, prompt: Text("Wofür ist er da? Andere Agenten entscheiden danach."), axis: .vertical)
                    .lineLimit(2...3)

                Picker("Rolle", selection: $agent.role) {
                    ForEach(AgentDefinition.Role.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                Text(agent.role.detail)
                    .font(Theme.Fonts.sans(10.5))
                    .foregroundStyle(Theme.textTertiary)

                Picker("Modell", selection: Binding(
                    get: { agent.model ?? "" },
                    set: { agent.model = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Modell aus dem Chat").tag("")
                    ForEach(store.connectedProviders) { provider in
                        Section(provider.name) {
                            ForEach(provider.sortedModels) { model in
                                Text(model.name).tag("\(provider.id)/\(model.id)")
                            }
                        }
                    }
                }

                Toggle("Darf Dateien ändern", isOn: $agent.canEdit)
                Toggle("Darf Terminal-Befehle ausführen", isOn: $agent.canRunCommands)
                Toggle("Darf andere Agenten beauftragen", isOn: $agent.canDelegate)

                if !store.connectors.isEmpty {
                    Section("Konnektoren") {
                        ForEach(store.connectors) { connector in
                            Toggle(isOn: Binding(
                                get: { connector.scope == .allAgents || agent.connectors.contains(connector.id) },
                                set: { on in
                                    agent.connectors.removeAll { $0 == connector.id }
                                    if on { agent.connectors.append(connector.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(connector.title)
                                    if connector.scope == .allAgents {
                                        Text("steht allen Agenten zur Verfügung").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(connector.scope == .allAgents)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 420)

            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Anweisungen")
                TextEditor(text: $agent.instructions)
                    .font(Theme.Fonts.mono(12))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 160)
                    .background(Theme.void.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
            }

            HStack {
                if originalName != nil {
                    Button("Löschen", role: .destructive) { confirmDelete = true }
                        .buttonStyle(PillButtonStyle(tint: Theme.clay))
                }
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(PillButtonStyle())
                Button("Speichern") {
                    var saved = agent
                    saved.name = AgentDefinition.slug(agent.name)
                    Task {
                        await store.saveAgent(saved, replacing: originalName)
                        dismiss()
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(!nameIsValid || agent.description.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.night)
        .confirmationDialog("„\(agent.displayName)“ löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                Task {
                    await store.deleteAgent(originalName ?? agent.name)
                    dismiss()
                }
            }
        }
    }
}
