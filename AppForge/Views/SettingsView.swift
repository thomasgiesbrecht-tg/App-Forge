import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Modelle", systemImage: "cpu") { ProvidersSettings() }
            Tab("Agenten", systemImage: "person.3") { AgentsSettings() }
            Tab("Konnektoren", systemImage: "puzzlepiece.extension") { ConnectorsSettings() }
            Tab("Medien", systemImage: "photo.on.rectangle") { MediaSettingsView() }
            Tab("Sparen", systemImage: "leaf") { SavingsSettings() }
            Tab("Skills", systemImage: "book") { SkillsSettings() }
            Tab("Engine", systemImage: "gearshape.2") { EngineSettings() }
        }
        .frame(width: 660, height: 540)
        .scrollContentBackground(.hidden)
        .background(Theme.black.ignoresSafeArea())
    }
}

// MARK: Anbieter & API-Schlüssel

private struct ProvidersSettings: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var editing: Provider?

    /// Häufig genutzte Anbieter stehen oben; alle anderen (models.dev-Katalog) über die Suche.
    private let featured = ["anthropic", "openai", "google", "openrouter", "mistral", "deepseek", "alibaba", "xai", "groq", "moonshotai", "zai"]

    /// Anzahl der Modelle eines Anbieters, die zur Suche passen (Suche findet auch Modellnamen wie „Qwen“).
    private func matchingModels(_ provider: Provider) -> Int {
        guard !search.isEmpty else { return 0 }
        return provider.models.values.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }.count
    }

    private var visible: [Provider] {
        let all = store.providers?.all ?? []
        if !search.isEmpty {
            let byName = all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
            let byModel = all.filter { matchingModels($0) > 0 && !byName.contains($0) }
                .sorted { matchingModels($0) > matchingModels($1) }
            return byName.sorted { $0.name < $1.name } + byModel
        }
        let connected = Set(store.providers?.connected ?? [])
        return all.filter { featured.contains($0.id) || connected.contains($0.id) }
            .sorted { (featured.firstIndex(of: $0.id) ?? 99, $0.name) < (featured.firstIndex(of: $1.id) ?? 99, $1.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Jeder Anbieter mit API-Schlüssel steht im Chat zur Auswahl – mit denselben Werkzeugen und Skills.")
                .foregroundStyle(.secondary)
            TextField("Anbieter oder Modell suchen, z. B. „Qwen“, „Claude“, „Gemini“ …", text: $search)
                .textFieldStyle(.roundedBorder)
            List(visible) { provider in
                let connected = store.providers?.connected.contains(provider.id) ?? false
                HStack {
                    Image(systemName: connected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(connected ? Theme.sage : Theme.textTertiary)
                    VStack(alignment: .leading) {
                        Text(provider.name)
                        let matches = matchingModels(provider)
                        Text(matches > 0 ? "\(matches) passende von \(provider.models.count) Modellen" : "\(provider.models.count) Modelle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if connected {
                        Button("Entfernen") { Task { await store.removeAPIKey(for: provider.id) } }
                    }
                    Button(connected ? "Schlüssel ändern" : "Verbinden") { editing = provider }
                }
            }
            Text("Schlüssel speichert OpenCode lokal in ~/.local/share/opencode/auth.json. Lokale Modelle (Ollama, LM Studio) folgen als eigener Anbieter-Typ.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .sheet(item: $editing) { provider in
            APIKeySheet(provider: provider)
        }
        .task { await store.refreshMeta() }
    }
}

private struct APIKeySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let provider: Provider
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(provider.name) verbinden").font(.title3.bold())
            SecureField("API-Schlüssel", text: $key)
                .textFieldStyle(.roundedBorder)
            if !provider.env.isEmpty {
                Text("Alternativ liest OpenCode die Umgebungsvariable \(provider.env.joined(separator: " / ")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Speichern") {
                    let value = key
                    Task {
                        await store.setAPIKey(value, for: provider.id)
                        dismiss()
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(key.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: Skills

private struct SkillsSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skills lädt jedes Modell bei Bedarf selbst. Gefunden werden die mitgelieferten Apple-Skills, deine Claude-Skills aus ~/.claude/skills sowie Skills im Projekt (.claude/skills, .opencode/skills, .agents/skills).")
                .foregroundStyle(.secondary)
            List(store.skills) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(skill.name).fontWeight(.medium)
                        Spacer()
                        Text(source(of: skill)).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let description = skill.description {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .contextMenu {
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: skill.location)])
                    }
                }
            }
            HStack {
                Text("\(store.skills.count) Skills").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Aktualisieren") { Task { await store.refreshMeta() } }
            }
        }
        .padding()
        .task { await store.refreshMeta() }
    }

    private func source(of skill: SkillInfo) -> String {
        if skill.location.hasPrefix(EngineConfig.configDirectory.path) { return "AppForge" }
        if skill.location.contains("/.claude/") { return "Claude" }
        if skill.location.contains("/.agents/") { return "Agents" }
        return "OpenCode"
    }
}

// MARK: Engine

private struct EngineSettings: View {
    @Environment(AppStore.self) private var store
    @State private var log = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section("OpenCode") {
                TextField("Pfad zur opencode-Datei (leer = automatisch)", text: $store.binaryOverride)
                LabeledContent("Status", value: statusText)
                Button("Engine neu starten") { Task { await store.restartEngine() } }
            }
            Section("Konfiguration") {
                LabeledContent("Ordner") {
                    Button(EngineConfig.supportDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        NSWorkspace.shared.open(EngineConfig.supportDirectory)
                    }
                    .buttonStyle(.link)
                }
            }
            Section("Protokoll") {
                ScrollView {
                    Text(log.isEmpty ? "–" : log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                Button("Aktualisieren") { log = store.engineLog }
            }
        }
        .formStyle(.grouped)
        .onAppear { log = store.engineLog }
    }

    private var statusText: String {
        switch store.engineState {
        case .stopped: "gestoppt"
        case .starting: "startet …"
        case .running: "läuft"
        case .failed: "Fehler"
        }
    }
}

// MARK: Medien (/foto, /video)

struct MediaSettingsView: View {
    @State private var settings = MediaSettings.current
    @State private var hasKey = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: hasKey ? "checkmark.circle.fill" : "key")
                        .foregroundStyle(hasKey ? Theme.sage : Theme.attention)
                    Text(hasKey ? "Alibaba-Schlüssel gefunden" : "Kein Alibaba-Schlüssel – verbinde unter „Modelle“ den Anbieter „Alibaba“.")
                        .font(Theme.Fonts.small)
                }
                Picker("Region", selection: $settings.region) {
                    ForEach(MediaSettings.Region.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Alibaba Model Studio")
            } footer: {
                Text("Im Chat: „/foto …“ erzeugt ein Bild, „/video …“ ein Video. Mit angehängtem Bild wird es bearbeitet bzw. animiert. Dateien liegen in ~/Library/Application Support/AppForge/Medien. Schlüssel gelten nur für ihre Region. Neue Konten in Singapur haben 100 Gratis-Bilder und 50 Gratis-Videosekunden.")
            }

            Section("Foto (Qwen-Image)") {
                TextField("Modell", text: $settings.imageModel)
                TextField("Modell zum Bearbeiten", text: $settings.imageEditModel)
                Picker("Format", selection: $settings.imageSize) {
                    ForEach(MediaSettings.imageSizes, id: \.0) { Text("\($0.1) · \($0.0.replacingOccurrences(of: "*", with: "×"))").tag($0.0) }
                }
                if let cost = settings.estimatedCost(.image) {
                    Text("≈ " + Money.format(cost, precise: true) + " pro Bild").font(Theme.Fonts.small).foregroundStyle(Theme.textTertiary)
                }
            }

            Section("Video (Wan)") {
                TextField("Modell Text → Video", text: $settings.textToVideoModel)
                TextField("Modell Bild → Video", text: $settings.imageToVideoModel)
                Picker("Seitenverhältnis", selection: $settings.videoRatio) {
                    ForEach(MediaSettings.videoRatios, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Auflösung", selection: $settings.videoResolution) {
                    Text("720p").tag("720P")
                    Text("1080p").tag("1080P")
                }
                Stepper("Länge: \(settings.videoDuration) Sekunden", value: $settings.videoDuration, in: 2...15)
                if let cost = settings.estimatedCost(.video) {
                    Text("≈ " + Money.format(cost) + " pro Video").font(Theme.Fonts.small).foregroundStyle(Theme.textTertiary)
                }
            }

            Section {
                Button("Medienordner öffnen") {
                    try? FileManager.default.createDirectory(at: MediaStudio.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(MediaStudio.directory)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.region) { hasKey = DashScopeClient.apiKey(provider: settings.region.providerID) != nil }
        .onAppear { hasKey = DashScopeClient.apiKey(provider: settings.region.providerID) != nil }
        .onDisappear { settings.save() }
        .onChange(of: settingsFingerprint) { settings.save() }
    }

    private var settingsFingerprint: String {
        (try? String(decoding: JSONEncoder().encode(settings), as: UTF8.self)) ?? ""
    }
}
