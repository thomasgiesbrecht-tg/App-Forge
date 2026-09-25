import SwiftUI

/// Einstellungen → Konnektoren: Xcode-Werkzeuge, übernommene und eigene MCP-Konnektoren.
struct ConnectorsSettings: View {
    @Environment(AppStore.self) private var store
    @State private var xcodeEnabled: [String: Bool] = Dictionary(
        uniqueKeysWithValues: EngineConfig.mcpServers.map { ($0.id, EngineConfig.isEnabled($0)) }
    )
    @State private var importing = false
    @State private var editing: Connector?
    @State private var isNew = false

    var body: some View {
        Form {
            Section {
                ForEach(EngineConfig.mcpServers) { server in
                    Toggle(isOn: Binding(
                        get: { xcodeEnabled[server.id] ?? true },
                        set: { xcodeEnabled[server.id] = $0; EngineConfig.setEnabled(server, $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(server.title); StatusBadge(status: store.mcpStatus[server.id]) }
                            Text(server.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Xcode (für alle Agenten)")
            }

            Section {
                if store.connectors.isEmpty {
                    Text("Noch keine eigenen Konnektoren. Übernimm sie aus Claude oder füge einen hinzu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.connectors) { connector in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { connector.enabled },
                            set: { value in
                                var changed = connector
                                changed.enabled = value
                                store.saveConnector(changed)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(connector.title).fontWeight(.medium)
                                StatusBadge(status: store.mcpStatus[connector.id])
                            }
                            Text(connector.summary)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 8) {
                                Text(connector.scope.title)
                                if let source = connector.source { Text("· aus \(source)") }
                                if connector.scope == .selectedAgents {
                                    let users = store.agentDefinitions.filter { $0.connectors.contains(connector.id) }.map(\.displayName)
                                    Text("· " + (users.isEmpty ? "noch kein Agent" : users.joined(separator: ", ")))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Bearbeiten") { isNew = false; editing = connector }
                    }
                    .contextMenu {
                        Button("Entfernen", role: .destructive) { store.removeConnector(connector) }
                    }
                }
                HStack {
                    Button("Aus Claude übernehmen …") { importing = true }
                    Button("Eigenen hinzufügen …") {
                        isNew = true
                        editing = Connector(id: "", title: "")
                    }
                }
            } header: {
                Text("Weitere Konnektoren")
            } footer: {
                Text("„Nur ausgewählte Agenten“ hält die Werkzeuge aus allen anderen Agenten heraus – das spart Kontext und Kosten. Welche Agenten sie nutzen, stellst du unter „Agenten“ ein. Änderungen starten die Engine neu.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $importing) { ImportSheet() }
        .sheet(item: $editing) { connector in
            ConnectorEditor(connector: connector, isNew: isNew)
        }
        .task { await store.refreshMeta() }
    }
}

private struct StatusBadge: View {
    let status: MCPStatus?

    var body: some View {
        if let status {
            let ok = status.isConnected
            Text(ok ? "verbunden" : status.status == "disabled" ? "aus" : "Fehler")
                .font(.caption2.weight(.medium))
                .foregroundStyle(ok ? Theme.success : Theme.textSecondary)
                .help(status.error ?? "")
        }
    }
}

/// Auswahl der gefundenen Claude-Konnektoren.
private struct ImportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var found: [Connector] = []
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Aus Claude übernehmen").font(.title3)
            Text("Gefunden in Claude Code, Claude Desktop und deinen Claude-Erweiterungen. Online-Konnektoren von claude.ai (z. B. Gmail) laufen über dein Claude-Konto und lassen sich nicht übernehmen.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(found, selection: $selected) { connector in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(connector.title).fontWeight(.medium)
                        Text(connector.source ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(connector.summary).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                .tag(connector.id)
            }
            .frame(height: 260)
            HStack {
                Text("\(selected.count) ausgewählt").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Übernehmen") {
                    for connector in found where selected.contains(connector.id) {
                        var imported = connector
                        // Große Werkzeugsammlungen (DaVinci, Blender …) standardmäßig nur für ausgewählte Agenten
                        imported.scope = .selectedAgents
                        store.saveConnector(imported, restart: false)
                    }
                    Task { await store.restartEngine() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            let existing = Set(store.connectors.map(\.summary))
            found = ConnectorLibrary.discoverFromClaude().filter { !existing.contains($0.summary) }
            selected = Set(found.map(\.id))
        }
    }
}

/// Konnektor anlegen oder bearbeiten.
private struct ConnectorEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var connector: Connector
    let isNew: Bool
    @State private var commandText = ""
    @State private var envText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Konnektor hinzufügen" : "Konnektor bearbeiten").font(.title3)
            Form {
                TextField("Name", text: $connector.title, prompt: Text("z. B. Figma"))
                Picker("Art", selection: $connector.kind) {
                    Text("Programm auf diesem Mac").tag(Connector.Kind.local)
                    Text("Web-Adresse").tag(Connector.Kind.remote)
                }
                if connector.kind == .local {
                    TextField("Befehl", text: $commandText, prompt: Text("z. B. npx -y @figma/mcp"), axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                    TextField("Umgebungsvariablen", text: $envText, prompt: Text("NAME=wert, eine pro Zeile"), axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...5)
                } else {
                    TextField("Adresse", text: Binding(get: { connector.url ?? "" }, set: { connector.url = $0 }), prompt: Text("https://…/mcp"))
                }
                Picker("Verfügbar für", selection: $connector.scope) {
                    ForEach(Connector.Scope.allCases) { Text($0.title).tag($0) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                if !isNew {
                    Button("Entfernen", role: .destructive) { store.removeConnector(connector); dismiss() }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Speichern") {
                    var saved = connector
                    if isNew { saved.id = Connector.makeID(saved.title, taken: Set(store.connectors.map(\.id))) }
                    if saved.kind == .local {
                        saved.command = Self.split(commandText)
                        saved.environment = Dictionary(envText.split(separator: "\n").compactMap { line in
                            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                            return parts.count == 2 ? (parts[0], parts[1]) : nil
                        }, uniquingKeysWith: { $1 })
                    }
                    store.saveConnector(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(connector.title.isEmpty || (connector.kind == .local ? commandText.isEmpty : (connector.url ?? "").isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            commandText = connector.command.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
            envText = connector.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }
    }

    /// Zerlegt eine Befehlszeile; Anführungszeichen halten Pfade mit Leerzeichen zusammen.
    static func split(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in line {
            if character == "\"" { quoted.toggle(); continue }
            if character.isWhitespace && !quoted {
                if !current.isEmpty { parts.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
