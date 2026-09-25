import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    enum EngineState: Equatable {
        case stopped, starting, running
        case failed(String)
    }

    // Engine
    private(set) var engineState: EngineState = .stopped
    private(set) var client: OpenCodeClient?
    private let engine = EngineProcess()
    private var eventTask: Task<Void, Never>?

    // Projekte & Sessions
    private(set) var projects: [String] = UserDefaults.standard.stringArray(forKey: "projects") ?? []
    private(set) var selectedProject: String?
    private(set) var sessions: [Session] = []
    var selectedSessionID: String? {
        didSet { if let selectedSessionID, selectedSessionID != oldValue { Task { await loadMessages(selectedSessionID) } } }
    }
    private(set) var messages: [String: [ChatMessage]] = [:]
    private(set) var activity: [String: SessionActivity] = [:]
    private(set) var sessionErrors: [String: String] = [:]
    private(set) var permissions: [PermissionRequest] = []

    // Modelle, Skills, Werkzeuge
    private(set) var providers: ProviderList?
    private(set) var skills: [SkillInfo] = []
    private(set) var mcpStatus: [String: MCPStatus] = [:]
    var lastError: String?

    var selectedModel: ModelSelection? {
        didSet { persist(selectedModel, key: "selectedModel") }
    }
    var platform: TargetPlatform = TargetPlatform(rawValue: UserDefaults.standard.string(forKey: "platform") ?? "") ?? .iOS {
        didSet { UserDefaults.standard.set(platform.rawValue, forKey: "platform") }
    }
    var binaryOverride: String = UserDefaults.standard.string(forKey: "binaryOverride") ?? "" {
        didSet { UserDefaults.standard.set(binaryOverride, forKey: "binaryOverride") }
    }

    // Agenten
    private(set) var agents: [AgentInfo] = []
    private(set) var agentDefinitions: [AgentDefinition] = AgentLibrary.load()
    var selectedAgent: String = UserDefaults.standard.string(forKey: "selectedAgent") ?? "build" {
        didSet { UserDefaults.standard.set(selectedAgent, forKey: "selectedAgent") }
    }

    // Berechtigungen
    var permissionMode: PermissionMode = PermissionMode(rawValue: UserDefaults.standard.string(forKey: "permissionMode") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(permissionMode.rawValue, forKey: "permissionMode") }
    }

    // Konnektoren (DaVinci, Blender, …)
    private(set) var connectors: [Connector] = ConnectorLibrary.load()

    // Anhänge im Eingabefeld
    var attachments: [Attachment] = []

    /// Unter-Chat → übergeordneter Chat (Unteragenten), damit deren Freigaben im Haupt-Chat erscheinen.
    private var parentOf: [String: String] = [:]

    // Dateiänderungen je Chat (aus session.diff-Events)
    private(set) var sessionDiffs: [String: [FileChange]] = [:]

    // Seitenleiste rechts: Simulator & Änderungen
    enum InspectorTab: String { case simulator, changes, ideas }
    var inspectorVisible = false
    var inspectorTab: InspectorTab = .simulator
    let simulator = SimulatorService()

    // Zentrale (Startseite)
    let dispatcher = Dispatcher()
    let media = MediaStudio()
    var showHome = true

    // Ideen je App und die Verbindung zum iPhone
    let ideas = IdeaStore()
    let companion = CompanionBridge()

    init() {
        dispatcher.store = self
        media.store = self
        ideas.store = self
        companion.store = self
        ideas.onChange = { [weak self] projectID in self?.companion.ideasChanged(projectID) }
        if let data = UserDefaults.standard.data(forKey: "selectedModel") {
            selectedModel = try? JSONDecoder().decode(ModelSelection.self, from: data)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [engine] _ in
            engine.stop()
        }
    }

    // MARK: Oberfläche

    var sidebarVisible = true

    /// Arbeitet irgendein Chat gerade? Steuert u. a. das Glühen des Hintergrunds.
    var isWorking: Bool { activity.values.contains { $0 != .idle } }

    /// Die Antwort, die gerade einläuft (für den blinkenden Cursor).
    var streamingMessageID: String? {
        guard currentActivity != .idle, let last = currentMessages.last,
              !last.info.isUser, last.info.time.completed == nil else { return nil }
        return last.id
    }

    /// „denkt nach“ – solange noch nichts Sichtbares von der Antwort da ist.
    var showsThinkingIndicator: Bool {
        guard currentActivity != .idle else { return false }
        guard let last = currentMessages.last else { return true }
        if last.info.isUser { return true }
        return !last.parts.contains { part in
            switch part.type {
            case "text", "reasoning": !(part.text ?? "").isEmpty
            case "tool": true
            default: false
            }
        }
    }

    // MARK: Abgeleitete Werte

    var currentSession: Session? { sessions.first { $0.id == selectedSessionID } }

    /// Nachricht, ab der der Chat zurückgesetzt ist (noch wiederherstellbar).
    var revertedFromMessageID: String? { currentSession?.revert?.messageID }

    /// Alle Dateiänderungen des aktuellen Chats, je Datei zusammengefasst.
    var currentChanges: [FileChange] {
        guard let selectedSessionID else { return [] }
        if let live = sessionDiffs[selectedSessionID], !live.isEmpty { return live }
        var byFile: [String: FileChange] = [:]
        var order: [String] = []
        for message in currentMessages where message.info.isUser {
            for change in message.info.fileChanges {
                let key = change.file ?? change.id
                if byFile[key] == nil { order.append(key) }
                byFile[key] = change  // neuester Stand je Datei
            }
        }
        return order.compactMap { byFile[$0] }
    }

    var primaryAgents: [AgentInfo] {
        agents.filter { $0.isPrimary && $0.isVisible }
            .sorted { rank($0) < rank($1) }
    }

    var subagents: [AgentInfo] {
        agents.filter { $0.isSubagent && $0.isVisible }.sorted { $0.name < $1.name }
    }

    private func rank(_ agent: AgentInfo) -> String {
        switch agent.name {
        case "build": "0"
        case "plan": "1"
        default: "2" + agent.name
        }
    }

    var selectedAgentInfo: AgentInfo? { agents.first { $0.name == selectedAgent } }

    /// Zeigt „Plan umsetzen“, wenn die letzte Antwort vom Plan-Agenten stammt.
    var canImplementPlan: Bool {
        guard currentActivity == .idle, let last = currentMessages.last(where: { !$0.info.isUser }) else { return false }
        return last.info.agent == "plan" && last.info.time.completed != nil
    }

    var currentMessages: [ChatMessage] {
        guard let selectedSessionID else { return [] }
        return messages[selectedSessionID] ?? []
    }

    var currentActivity: SessionActivity {
        guard let selectedSessionID else { return .idle }
        return activity[selectedSessionID] ?? .idle
    }

    /// Offene Freigaben eines Auftrags (inkl. seiner Unteragenten).
    func permissions(forRoot sessionID: String) -> [PermissionRequest] {
        guard !sessionID.isEmpty else { return [] }
        return permissions.filter { rootSession(of: $0.sessionID) == sessionID }
    }

    var currentPermissions: [PermissionRequest] {
        permissions.filter { rootSession(of: $0.sessionID) == selectedSessionID }
    }

    func rootSession(of sessionID: String) -> String {
        var current = sessionID
        var guardCount = 0
        while let parent = parentOf[current], guardCount < 10 { current = parent; guardCount += 1 }
        return current
    }

    /// Modelle aller Anbieter, für die ein Schlüssel hinterlegt ist.
    var connectedProviders: [Provider] {
        guard let providers else { return [] }
        return providers.all
            .filter { providers.connected.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var selectedModelInfo: ModelInfo? {
        guard let selectedModel else { return nil }
        return providers?.all.first { $0.id == selectedModel.providerID }?.models[selectedModel.modelID]
    }

    // MARK: Engine

    func startEngine() async {
        eventTask?.cancel()
        companion.startIfEnabled()
        engineState = .starting
        do {
            client = try await engine.start(binaryOverride: binaryOverride)
            engineState = .running
            await refreshMeta()
            await dispatcher.start()
            if let selectedProject { await openProject(selectedProject) }
            else if let first = projects.first { await openProject(first) }
            Task { await ideas.analyzeOutstanding() }
        } catch {
            client = nil
            engineState = .failed(error.localizedDescription)
        }
    }

    func restartEngine() async {
        engine.stop()
        await startEngine()
    }

    var engineLog: String { engine.log }

    // MARK: Projekte

    func addProject(_ url: URL) async {
        let path = url.path(percentEncoded: false)
        if !projects.contains(path) {
            projects.append(path)
            UserDefaults.standard.set(projects, forKey: "projects")
        }
        await openProject(path)
    }

    func removeProject(_ path: String) {
        projects.removeAll { $0 == path }
        UserDefaults.standard.set(projects, forKey: "projects")
        if selectedProject == path {
            selectedProject = nil
            sessions = []
            selectedSessionID = nil
            eventTask?.cancel()
        }
    }

    func openProject(_ path: String) async {
        selectedProject = path
        sessions = []
        selectedSessionID = nil
        permissions = []
        guard let client else { return }
        subscribeToEvents(directory: path)
        do {
            sessions = try await client.sessions(directory: path)
                .filter { $0.parentID == nil && !IdeaStore.isAgentSession($0) }
                .sorted { $0.time.updated > $1.time.updated }
            selectedSessionID = sessions.first?.id
            permissions = (try? await client.pendingPermissions(directory: path)) ?? []
        } catch {
            lastError = error.localizedDescription
        }
        await refreshMeta()
    }

    /// Lädt Anbieter/Modelle, Skills und MCP-Status neu.
    func refreshMeta() async {
        guard let client else { return }
        let directory = selectedProject ?? projects.first ?? Dispatcher.directory.path
        try? FileManager.default.createDirectory(at: Dispatcher.directory, withIntermediateDirectories: true)
        async let providers = try? client.providers(directory: directory)
        async let skills = try? client.skills(directory: directory)
        async let mcp = try? client.mcpStatus(directory: directory)
        async let agents = try? client.agents(directory: directory)
        self.agents = await agents ?? []
        if !self.agents.isEmpty, !self.agents.contains(where: { $0.name == selectedAgent && $0.isPrimary }) {
            selectedAgent = "build"
        }
        self.providers = await providers
        self.skills = (await skills ?? []).sorted { $0.name < $1.name }
        self.mcpStatus = await mcp ?? [:]
        ensureValidModel()
    }

    private func ensureValidModel() {
        guard let providers else { return }
        if let selectedModel, providers.connected.contains(selectedModel.providerID),
           providers.all.first(where: { $0.id == selectedModel.providerID })?.models[selectedModel.modelID] != nil {
            return
        }
        for provider in connectedProviders {
            if let modelID = providers.default[provider.id] ?? provider.sortedModels.first?.id {
                selectedModel = ModelSelection(providerID: provider.id, modelID: modelID)
                return
            }
        }
        selectedModel = nil
    }

    // MARK: Sessions & Nachrichten

    func newSession() async {
        guard let client, let selectedProject else { return }
        do {
            let session = try await client.createSession(directory: selectedProject)
            upsert(session)
            selectedSessionID = session.id
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteSession(_ id: String) async {
        guard let client, let selectedProject else { return }
        do {
            try await client.deleteSession(id, directory: selectedProject)
            sessions.removeAll { $0.id == id }
            if selectedSessionID == id { selectedSessionID = sessions.first?.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadMessages(_ sessionID: String) async {
        guard let client, let selectedProject else { return }
        do {
            let envelopes = try await client.messages(sessionID: sessionID, directory: selectedProject)
            messages[sessionID] = envelopes.map { ChatMessage(info: $0.info, parts: $0.parts) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func send(_ text: String, agent: String? = nil) async {
        // /foto und /video gehen an die Medienerzeugung statt an ein Sprachmodell
        if let (kind, prompt) = MediaStudio.parse(text) {
            let input = attachments.first(where: \.isImage)
            attachments.removeAll { $0.id == input?.id }
            await media.run(kind, prompt: prompt, inputImage: input)
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, let client, let selectedProject else { return }
        if selectedSessionID == nil { await newSession() }
        guard let sessionID = selectedSessionID else { return }
        let files = attachments
        attachments = []
        sessionErrors[sessionID] = nil
        activity[sessionID] = .busy
        do {
            try await client.prompt(
                sessionID: sessionID,
                directory: selectedProject,
                text: trimmed.isEmpty ? "Siehe Anhang." : trimmed,
                attachments: files,
                mentions: mentionedSubagents(in: trimmed),
                model: selectedModel,
                agent: agent ?? selectedAgent,
                system: platform.systemHint
            )
        } catch {
            activity[sessionID] = .idle
            attachments = files
            sessionErrors[sessionID] = error.localizedDescription
        }
    }

    /// `@lektor prüf mal …` – erwähnte Unteragenten werden direkt beauftragt.
    private func mentionedSubagents(in text: String) -> [String] {
        let names = Set(subagents.map(\.name))
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ":" })
        return words.compactMap { word -> String? in
            guard word.hasPrefix("@") else { return nil }
            let name = String(word.dropFirst())
            return names.contains(name) ? name : nil
        }
    }

    func implementPlan() async {
        let agent = selectedAgent == "plan" ? "build" : selectedAgent
        selectedAgent = agent
        await send("Setze den Plan jetzt Schritt für Schritt um.", agent: agent)
    }

    // MARK: Anhänge

    func addAttachments(_ new: [Attachment]) {
        attachments.append(contentsOf: new)
    }

    func removeAttachment(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    // MARK: Zurücksetzen

    /// Setzt Chat und Dateien auf den Stand vor dieser Nachricht zurück (wiederherstellbar bis zur nächsten Nachricht).
    func revert(to messageID: String) async {
        guard let client, let selectedProject, let sessionID = selectedSessionID else { return }
        do {
            let session = try await client.revert(sessionID: sessionID, messageID: messageID, directory: selectedProject)
            upsert(session)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unrevert() async {
        guard let client, let selectedProject, let sessionID = selectedSessionID else { return }
        do {
            let session = try await client.unrevert(sessionID: sessionID, directory: selectedProject)
            upsert(session)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Nachricht bearbeiten = ab ihr zurücksetzen und den Text wieder ins Eingabefeld legen.
    func edit(_ message: ChatMessage) async -> String {
        await revert(to: message.id)
        attachments = message.parts.filter { $0.type == "file" }.compactMap { part in
            guard let url = part.url, let mime = part.mime else { return nil }
            return Attachment(filename: part.filename ?? "Anhang", mime: mime, url: url, thumbnail: nil)
        }
        return message.parts.filter { $0.type == "text" && $0.synthetic != true }.compactMap(\.text).joined(separator: "\n")
    }

    // MARK: Unteragenten

    /// Lädt den Verlauf eines Unter-Chats (Unteragent), falls noch nicht vorhanden.
    func loadChildSession(_ sessionID: String) async {
        guard messages[sessionID] == nil, let client, let selectedProject else { return }
        if let envelopes = try? await client.messages(sessionID: sessionID, directory: selectedProject) {
            messages[sessionID] = envelopes.map { ChatMessage(info: $0.info, parts: $0.parts) }
        }
    }

    // MARK: Agenten verwalten

    func saveAgent(_ agent: AgentDefinition, replacing oldName: String?) async {
        do {
            try AgentLibrary.save(agent, replacing: oldName)
            agentDefinitions = AgentLibrary.load()
            await reloadInstance()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteAgent(_ name: String) async {
        try? AgentLibrary.delete(name)
        agentDefinitions = AgentLibrary.load()
        if selectedAgent == name { selectedAgent = "build" }
        await reloadInstance()
    }

    // MARK: Konnektoren

    func saveConnector(_ connector: Connector, restart: Bool = true) {
        if let index = connectors.firstIndex(where: { $0.id == connector.id }) {
            connectors[index] = connector
        } else {
            connectors.append(connector)
        }
        ConnectorLibrary.save(connectors)
        if restart { Task { await restartEngine() } }
    }

    func removeConnector(_ connector: Connector) {
        connectors.removeAll { $0.id == connector.id }
        ConnectorLibrary.save(connectors)
        // Freischaltungen in Agenten-Dateien mit aufräumen
        for var agent in agentDefinitions where agent.connectors.contains(connector.id) {
            agent.connectors.removeAll { $0 == connector.id }
            try? AgentLibrary.save(agent)
        }
        agentDefinitions = AgentLibrary.load()
        Task { await restartEngine() }
    }

    func restoreStarterAgents() async {
        for agent in AgentLibrary.starters where !agentDefinitions.contains(where: { $0.name == agent.name }) {
            try? AgentLibrary.save(agent)
        }
        agentDefinitions = AgentLibrary.load()
        await reloadInstance()
    }

    /// Öffnet den Chat eines Auftrags der Zentrale.
    func open(_ mission: Mission) async {
        if selectedProject != mission.directory {
            if !projects.contains(mission.directory) { await addProject(URL(filePath: mission.directory)) }
            else { await openProject(mission.directory) }
        }
        if !sessions.contains(where: { $0.id == mission.sessionID }), let client,
           let session = try? await client.sessions(directory: mission.directory).first(where: { $0.id == mission.sessionID }) {
            upsert(session)
        }
        selectedSessionID = mission.sessionID
        showHome = false
    }

    func abort() async {
        guard let client, let selectedProject, let selectedSessionID else { return }
        try? await client.abort(sessionID: selectedSessionID, directory: selectedProject)
    }

    /// Bricht die laufende Arbeit ab und schickt die neue Anweisung sofort hinterher.
    func interruptAndSend(_ text: String) async {
        guard let sessionID = selectedSessionID else { return await send(text) }
        await abort()
        // Kurz warten, bis der Server den Abbruch bestätigt (session.status → idle).
        for _ in 0..<40 where activity[sessionID] != .idle {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await send(text)
    }

    /// Nutzer-Nachrichten, die während laufender Arbeit geschickt wurden und noch auf Bearbeitung warten.
    var queuedMessageIDs: Set<String> {
        guard currentActivity != .idle else { return [] }
        let messages = currentMessages
        // Nur wenn gerade wirklich eine Antwort läuft – sonst ist eine neue Nachricht einfach „dran“.
        guard messages.contains(where: { !$0.info.isUser && $0.info.time.completed == nil }) else { return [] }
        let answered = Set(messages.compactMap { $0.info.isUser ? nil : $0.info.parentID })
        guard let lastAnswered = messages.lastIndex(where: { $0.info.isUser && answered.contains($0.id) }) else { return [] }
        return Set(messages[(lastAnswered + 1)...].filter { $0.info.isUser && !answered.contains($0.id) }.map(\.id))
    }

    func reply(to request: PermissionRequest, _ reply: PermissionReply) async {
        guard let client, let selectedProject else { return }
        do {
            try await client.replyPermission(requestID: request.id, directory: selectedProject, reply: reply)
            permissions.removeAll { $0.id == request.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: API-Schlüssel

    func setAPIKey(_ key: String, for providerID: String) async {
        guard let client else { return }
        do {
            try await client.setAPIKey(providerID: providerID, key: key)
            await reloadInstance()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeAPIKey(for providerID: String) async {
        guard let client else { return }
        do {
            try await client.removeAPIKey(providerID: providerID)
            await reloadInstance()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Lädt die Projekt-Instanz neu, damit neue Schlüssel/MCP-Einstellungen greifen.
    private func reloadInstance() async {
        guard let client, let directory = selectedProject ?? projects.first else { return }
        try? await client.disposeInstance(directory: directory)
        await refreshMeta()
    }

    // MARK: Events

    private func subscribeToEvents(directory: String) {
        eventTask?.cancel()
        guard let client else { return }
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
        case .messageUpdated(let info):
            var list = messages[info.sessionID] ?? []
            if let index = list.firstIndex(where: { $0.id == info.id }) {
                list[index].info = info
            } else {
                list.append(ChatMessage(info: info, parts: []))
                list.sort { $0.info.time.created < $1.info.time.created }
            }
            messages[info.sessionID] = list

        case .messageRemoved(let sessionID, let messageID):
            messages[sessionID]?.removeAll { $0.id == messageID }

        case .partUpdated(let part):
            var list = messages[part.sessionID] ?? []
            let index = list.firstIndex(where: { $0.id == part.messageID }) ?? {
                let placeholder = MessageInfo(
                    id: part.messageID, sessionID: part.sessionID, role: "assistant",
                    time: .init(created: Date().timeIntervalSince1970 * 1000)
                )
                list.append(ChatMessage(info: placeholder, parts: []))
                return list.count - 1
            }()
            if let partIndex = list[index].parts.firstIndex(where: { $0.id == part.id }) {
                list[index].parts[partIndex] = part
            } else {
                list[index].parts.append(part)
            }
            messages[part.sessionID] = list

        case .partDelta(let sessionID, let messageID, let partID, let field, let delta):
            guard field == "text",
                  var list = messages[sessionID],
                  let messageIndex = list.firstIndex(where: { $0.id == messageID }),
                  let partIndex = list[messageIndex].parts.firstIndex(where: { $0.id == partID })
            else { return }
            list[messageIndex].parts[partIndex].text = (list[messageIndex].parts[partIndex].text ?? "") + delta
            messages[sessionID] = list

        case .partRemoved(let sessionID, let messageID, let partID):
            guard let messageIndex = messages[sessionID]?.firstIndex(where: { $0.id == messageID }) else { return }
            messages[sessionID]?[messageIndex].parts.removeAll { $0.id == partID }

        case .sessionUpdated(let session):
            if let parent = session.parentID { parentOf[session.id] = parent }
            guard session.parentID == nil, session.directory == selectedProject, !IdeaStore.isAgentSession(session) else { return }
            let wasReverted = sessions.first { $0.id == session.id }?.revert != nil
            upsert(session)
            // Zurücksetzung aufgehoben oder endgültig verworfen → Verlauf neu laden
            if wasReverted, session.revert == nil, session.id == selectedSessionID { Task { await loadMessages(session.id) } }

        case .sessionDeleted(let session):
            sessions.removeAll { $0.id == session.id }

        case .sessionStatus(let sessionID, let newActivity):
            activity[sessionID] = newActivity

        case .sessionError(let sessionID, let message):
            if let sessionID { sessionErrors[sessionID] = message } else { lastError = message }

        case .permissionAsked(let request):
            if permissionMode.autoApproves(request), let client, let directory = selectedProject {
                Task { try? await client.replyPermission(requestID: request.id, directory: directory, reply: .once) }
                return
            }
            permissions.removeAll { $0.id == request.id }
            permissions.append(request)
            if let mission = dispatcher.mission(forRootSession: rootSession(of: request.sessionID)) {
                dispatcher.log(mission.title, "braucht deine Freigabe · \(request.permission)", .attention)
            }

        case .permissionReplied(_, let requestID):
            permissions.removeAll { $0.id == requestID }

        case .sessionDiff(let sessionID, let changes):
            sessionDiffs[sessionID] = changes

        case .other:
            break
        }
    }

    func sessionError(_ sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        return sessionErrors[sessionID]
    }

    private func upsert(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.time.updated > $1.time.updated }
    }

    private func persist<T: Encodable>(_ value: T?, key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
