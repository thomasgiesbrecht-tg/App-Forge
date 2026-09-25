import Foundation
import Network
import Observation
import UIKit
import WidgetKit

/// Zustand der iPhone-App: Verbindung zum Mac, letzter bekannter Stand und alles,
/// was noch zum Mac muss (Ideen, Chat-Nachrichten, Aufträge).
@MainActor
@Observable
final class CompanionModel {
    enum Connection: Equatable {
        case unpaired
        case searching
        case connected(macName: String)
        case offline(reason: String?)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    enum ModelError: LocalizedError {
        case offline, timeout, mac(String), unexpected

        var errorDescription: String? {
            switch self {
            case .offline: "Der Mac ist gerade nicht erreichbar."
            case .timeout: "Der Mac hat nicht rechtzeitig geantwortet."
            case .mac(let message): message
            case .unexpected: "Unerwartete Antwort vom Mac."
            }
        }
    }

    // MARK: Zustand

    private(set) var connection: Connection = .unpaired
    private(set) var pairing: PairingInfo?
    private(set) var lastConnected: Date? = SharedStore.defaults.object(forKey: "lastConnected") as? Date

    private(set) var projects: [CompanionProject] = SharedStore.projects()
    private(set) var snapshot: CompanionSnapshot? = SharedStore.snapshot()
    private(set) var ideas: [String: [Idea]] = SharedStore.ideas()
    private(set) var pendingIdeas: [Idea] = SharedStore.pendingIdeas()
    private(set) var sessions: [String: [CompanionSession]] = SharedStore.sessions()
    private(set) var outbox: [OutboxItem] = SharedStore.outbox()
    private(set) var chat: CompanionChat?
    private(set) var lastError: String?

    /// Ideen-Erfassung, die gerade offen sein soll (Widget, Kontrollzentrum, Siri, Knopf in der App).
    var capture: CaptureRequest?
    /// Chat, der geöffnet werden soll (z. B. aus einer Benachrichtigung).
    var pendingChat: (projectID: String, sessionID: String)?
    var selectedTab: AppTab = .apps

    struct CaptureRequest: Identifiable, Equatable {
        let id = UUID()
        var projectID: String
        var mode: CaptureMode
    }

    enum AppTab: Hashable { case apps, zentrale, missions, mac }

    let liveActivities = LiveActivityManager()
    var pushToken: String? {
        didSet { if pushToken != oldValue { registerPush() } }
    }

    @ObservationIgnored private var channel: CompanionChannel?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [UUID: CheckedContinuation<CompanionReply.Payload, Error>] = [:]
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var active = false

    private let deviceID: String = {
        if let id = SharedStore.defaults.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        SharedStore.defaults.set(id, forKey: "deviceID")
        return id
    }()

    init() {
        // Eingebaute Kopplung hat Vorrang: Nach einem neuen Build mit neuem Mac-Schlüssel gilt sofort der neue.
        if let builtIn = BuiltInPairing.load(), builtIn != Keychain.loadPairing() {
            Keychain.savePairing(builtIn)
        }
        pairing = Keychain.loadPairing()
        if pairing != nil { connection = .offline(reason: nil) }
        NotificationCenter.default.addObserver(forName: .pendingIdeasChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadPendingIdeas() }
        }
        NotificationCenter.default.addObserver(forName: .captureRequested, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.takeCaptureRequest() }
        }
    }

    var isConnected: Bool { connection.isConnected }

    func clearError() { lastError = nil }
    var macName: String { pairing?.macName ?? "Mac" }

    func project(_ id: String) -> CompanionProject? { projects.first { $0.id == id } }

    var permissions: [CompanionPermission] { isConnected ? (snapshot?.permissions ?? []) : [] }

    // MARK: Lebenszyklus

    func becameActive() {
        active = true
        reloadPendingIdeas()
        takeCaptureRequest()
        if !isConnected { connect() }
    }

    func becameInactive() {
        active = false
        retryTask?.cancel()
    }

    // MARK: Kopplung

    func pair(with url: URL) -> Bool {
        guard let info = PairingInfo(url: url) else { return false }
        Keychain.savePairing(info)
        pairing = info
        disconnect(reason: nil)
        connect()
        return true
    }

    func unpair() {
        Keychain.deletePairing()
        pairing = nil
        disconnect(reason: nil)
        connection = .unpaired
    }

    // MARK: Verbindung

    /// Sucht den Mac im WLAN (Bonjour) und – falls hinterlegt – parallel über die Adresse für unterwegs.
    func connect() {
        guard let pairing, channel == nil else { return }
        retryTask?.cancel()
        connection = .searching

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: CompanionProtocol.bonjourType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor in self?.found(endpoints) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.browseFailed(error.localizedDescription) }
            }
        }
        browser.start(queue: .main)
        self.browser = browser

        // Unterwegs: direkte Adresse versuchen, wenn der Mac nicht schnell im WLAN auftaucht.
        if let host = pairing.remoteHost, !host.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.channel == nil, self.connection == .searching,
                      let port = NWEndpoint.Port(rawValue: pairing.port) else { return }
                self.open(.hostPort(host: NWEndpoint.Host(host), port: port))
            }
        }

        // Nichts gefunden → als nicht erreichbar zeigen und später erneut versuchen.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.connection == .searching, self.channel == nil else { return }
            self.disconnect(reason: "nicht gefunden")
        }
    }

    private func found(_ endpoints: [NWEndpoint]) {
        guard channel == nil, let pairing else { return }
        let preferred = endpoints.first { endpoint in
            if case .service(let name, _, _, _) = endpoint { return name == pairing.macName }
            return false
        } ?? endpoints.first
        if let preferred { open(preferred) }
    }

    private func browseFailed(_ message: String) {
        browser?.cancel()
        browser = nil
        if channel == nil { disconnect(reason: message) }
    }

    private func open(_ endpoint: NWEndpoint) {
        guard channel == nil, let pairing else { return }
        let channel = CompanionChannel(endpoint: endpoint, secret: pairing.secret)
        self.channel = channel
        let id = channel.id
        channel.start { [weak self] state in
            Task { @MainActor in self?.channelChanged(id, state) }
        } onMessage: { [weak self] data in
            Task { @MainActor in self?.receive(data) }
        }
    }

    private func channelChanged(_ id: UUID, _ state: CompanionChannel.State) {
        guard channel?.id == id else { return }
        switch state {
        case .ready:
            browser?.cancel()
            browser = nil
            Task { await handshake() }
        case .failed(let message):
            disconnect(reason: message)
        case .closed:
            disconnect(reason: nil)
        case .connecting:
            break
        }
    }

    private func handshake() async {
        do {
            let payload = try await request(
                .hello(deviceID: deviceID, deviceName: UIDevice.current.name, protocolVersion: CompanionProtocol.version),
                requireConnection: false
            )
            guard case .welcome(let macName, _) = payload else { throw ModelError.unexpected }
            connection = .connected(macName: macName)
            attempt = 0
            lastConnected = .now
            SharedStore.defaults.set(lastConnected, forKey: "lastConnected")
            registerPush()
            await flush()
        } catch {
            disconnect(reason: error.localizedDescription)
        }
    }

    private func disconnect(reason: String?) {
        browser?.cancel()
        browser = nil
        let old = channel
        channel = nil
        old?.close()
        for (_, continuation) in pending { continuation.resume(throwing: ModelError.offline) }
        pending = [:]
        guard pairing != nil else { connection = .unpaired; return }
        connection = .offline(reason: reason)
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard active else { return }
        retryTask?.cancel()
        attempt += 1
        let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    func reconnect() {
        attempt = 0
        disconnect(reason: nil)
        connect()
    }

    // MARK: Nachrichten

    @discardableResult
    func request(_ action: CompanionRequest.Action, timeout: Double = 30, requireConnection: Bool = true) async throws -> CompanionReply.Payload {
        guard let channel, !requireConnection || isConnected else { throw ModelError.offline }
        let request = CompanionRequest(action: action)
        let payload: CompanionReply.Payload = try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            channel.send(request)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if let continuation = self?.pending.removeValue(forKey: request.id) {
                    continuation.resume(throwing: ModelError.timeout)
                }
            }
        }
        if case .error(let message) = payload { throw ModelError.mac(message) }
        return payload
    }

    private func receive(_ data: Data) {
        guard let reply = try? CompanionCoding.decoder().decode(CompanionReply.self, from: data) else { return }
        if let id = reply.requestID, let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: reply.payload)
        }
        apply(reply.payload)
    }

    private func apply(_ payload: CompanionReply.Payload) {
        switch payload {
        case .snapshot(let snapshot):
            self.snapshot = snapshot
            SharedStore.saveSnapshot(snapshot)
            if SharedStore.eurPerUsd != snapshot.eurPerUsd { SharedStore.eurPerUsd = snapshot.eurPerUsd }
        case .projects(let projects):
            self.projects = projects
            SharedStore.saveProjects(projects)
            WidgetCenter.shared.reloadAllTimelines()
        case .ideas(let projectID, let list):
            ideas[projectID] = list
            SharedStore.saveIdeas(ideas)
        case .sessions(let projectID, let list):
            sessions[projectID] = list
            SharedStore.saveSessions(sessions)
        case .chat(let chat):
            if self.chat == nil || self.chat?.sessionID == chat.sessionID { self.chat = chat }
        default:
            break
        }
    }

    // MARK: Warteschlange

    /// Schickt alles, was offline gesammelt wurde. Ideen zuerst, dann Chats und Aufträge in Reihenfolge.
    func flush() async {
        guard isConnected, !flushing else { return }
        flushing = true
        defer { flushing = false }

        reloadPendingIdeas()
        if !pendingIdeas.isEmpty {
            let batch = pendingIdeas
            if (try? await request(.addIdeas(batch))) != nil {
                SharedStore.removePendingIdeas(Set(batch.map(\.id)))
                reloadPendingIdeas()
                for projectID in Set(batch.map(\.projectID)) { await loadIdeas(projectID) }
            }
        }

        for item in outbox {
            do {
                switch item {
                case .chat(_, let projectID, let sessionID, let text, _):
                    let payload = try await request(.sendChat(projectID: projectID, sessionID: sessionID, text: text, agent: nil))
                    if case .chatStarted(let projectID, let sessionID, let notify) = payload {
                        startLiveActivity(.session(projectID: projectID, sessionID: sessionID), title: text, projectID: projectID, notify: notify)
                    }
                case .zentrale(_, let text, let projectID, _):
                    try await request(.zentrale(text: text, projectID: projectID))
                }
                outbox.removeAll { $0.id == item.id }
                SharedStore.saveOutbox(outbox)
            } catch ModelError.offline {
                return
            } catch {
                // Der Mac hat abgelehnt (z. B. Engine aus) – Eintrag behalten und später erneut versuchen.
                lastError = error.localizedDescription
                return
            }
        }
    }

    private func reloadPendingIdeas() {
        pendingIdeas = SharedStore.pendingIdeas()
        if isConnected, !pendingIdeas.isEmpty { Task { await flush() } }
    }

    // MARK: Ideen

    func ideas(for projectID: String) -> [Idea] {
        let synced = ideas[projectID] ?? []
        let syncedIDs = Set(synced.map(\.id))
        let waiting = pendingIdeas.filter { $0.projectID == projectID && !syncedIDs.contains($0.id) }
        return (waiting + synced).sorted { $0.createdAt > $1.createdAt }
    }

    func isPending(_ idea: Idea) -> Bool { pendingIdeas.contains { $0.id == idea.id } }

    /// Neue Idee: sofort lokal gespeichert, dann (falls möglich) direkt zum Mac.
    func addIdea(_ text: String, projectID: String, source: Idea.Source = .iphone) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SharedStore.addPendingIdea(Idea(projectID: projectID, text: trimmed, source: source))
        reloadPendingIdeas()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func loadIdeas(_ projectID: String) async {
        guard isConnected, case .ideas(let id, let list) = try? await request(.ideas(projectID: projectID)) else { return }
        ideas[id] = list
        SharedStore.saveIdeas(ideas)
    }

    func setStatus(_ status: Idea.Status, of idea: Idea) async {
        do {
            try await request(.setIdeaStatus(id: idea.id, projectID: idea.projectID, status: status))
        } catch { lastError = error.localizedDescription }
    }

    func delete(_ idea: Idea) async {
        if isPending(idea) {
            SharedStore.removePendingIdeas([idea.id])
            reloadPendingIdeas()
            return
        }
        do {
            try await request(.deleteIdea(id: idea.id, projectID: idea.projectID))
        } catch { lastError = error.localizedDescription }
    }

    func analyze(_ idea: Idea) async {
        try? await request(.analyzeIdea(id: idea.id, projectID: idea.projectID))
    }

    func askIdeas(_ question: String, projectID: String) async throws -> String {
        guard case .answer(let text) = try await request(.askIdeas(projectID: projectID, question: question), timeout: 320) else {
            throw ModelError.unexpected
        }
        return text
    }

    // MARK: Chats

    func loadSessions(_ projectID: String) async {
        guard isConnected, case .sessions(let id, let list) = try? await request(.sessions(projectID: projectID)) else { return }
        sessions[id] = list
        SharedStore.saveSessions(sessions)
    }

    func openChat(projectID: String, sessionID: String) async {
        if chat?.sessionID != sessionID { chat = nil }
        try? await request(.openChat(projectID: projectID, sessionID: sessionID))
    }

    func closeChat() async {
        chat = nil
        try? await request(.closeChat)
    }

    /// Schickt eine Nachricht in einen Chat (ohne `sessionID`: neuer Chat). Offline landet sie in der Warteschlange.
    /// Gibt die Chat-ID zurück, sobald der Mac sie kennt.
    @discardableResult
    func sendChat(_ text: String, projectID: String, sessionID: String?) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        SharedStore.markUsed(projectID)
        if isConnected {
            do {
                let payload = try await request(.sendChat(projectID: projectID, sessionID: sessionID, text: trimmed, agent: nil))
                if case .chatStarted(let projectID, let sessionID, let notify) = payload {
                    startLiveActivity(.session(projectID: projectID, sessionID: sessionID), title: trimmed, projectID: projectID, notify: notify)
                    Task { await loadSessions(projectID) }
                    return sessionID
                }
            } catch ModelError.mac(let message) {
                lastError = message
                return nil
            } catch {
                // Verbindung weg – unten in die Warteschlange.
            }
        }
        enqueue(.chat(id: UUID(), projectID: projectID, sessionID: sessionID, text: trimmed, createdAt: .now))
        return sessionID
    }

    func abortChat(projectID: String, sessionID: String) async {
        try? await request(.abortChat(projectID: projectID, sessionID: sessionID))
    }

    func setNotify(_ enabled: Bool, target: LiveTarget) async {
        try? await request(.setNotify(target: target, enabled: enabled))
    }

    func queuedChats(projectID: String, sessionID: String?) -> [OutboxItem] {
        outbox.filter {
            if case .chat(_, let p, let s, _, _) = $0 { return p == projectID && s == sessionID }
            return false
        }
    }

    func removeFromOutbox(_ item: OutboxItem) {
        outbox.removeAll { $0.id == item.id }
        SharedStore.saveOutbox(outbox)
    }

    private func enqueue(_ item: OutboxItem) {
        outbox.append(item)
        SharedStore.saveOutbox(outbox)
    }

    // MARK: Zentrale & Aufträge

    func sendToZentrale(_ text: String, projectID: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isConnected {
            do {
                try await request(.zentrale(text: trimmed, projectID: projectID), timeout: 60)
                return
            } catch ModelError.mac(let message) {
                lastError = message
                return
            } catch {}
        }
        enqueue(.zentrale(id: UUID(), text: trimmed, projectID: projectID, createdAt: .now))
    }

    var queuedZentrale: [OutboxItem] {
        outbox.filter { if case .zentrale = $0 { return true }; return false }
    }

    func newZentraleConversation() async {
        try? await request(.newZentraleConversation)
    }

    func launch(_ message: CompanionZentraleMessage) async {
        do {
            let payload = try await request(.launchProposal(messageID: message.id), timeout: 60)
            if case .launched(let groupID?, let title, _, let notify) = payload {
                let projectID = snapshot?.missions.first { !$0.isFinished }?.projectID ?? snapshot?.selectedProjectID ?? ""
                startLiveActivity(.missionGroup(groupID), title: title, projectID: projectID, notify: notify)
            }
        } catch { lastError = error.localizedDescription }
    }

    func stop(_ mission: CompanionMission) async {
        do { try await request(.stopMission(id: mission.id)) } catch { lastError = error.localizedDescription }
    }

    func reply(_ permission: CompanionPermission, _ answer: PermissionAnswer) async {
        do {
            try await request(.replyPermission(id: permission.id, directory: permission.directory, answer: answer))
        } catch { lastError = error.localizedDescription }
    }

    /// Für Benachrichtigungs-Aktionen: Verbindung aufbauen (falls nötig) und Freigabe senden.
    func replyFromNotification(permissionID: String, directory: String, answer: PermissionAnswer) async -> Bool {
        if !isConnected {
            connect()
            for _ in 0..<40 where !isConnected { try? await Task.sleep(for: .milliseconds(250)) }
        }
        return (try? await request(.replyPermission(id: permissionID, directory: directory, answer: answer))) != nil
    }

    // MARK: Mac

    func discoverProjects() async throws -> [DiscoveredProject] {
        guard case .discovered(let list) = try await request(.discoverProjects, timeout: 60) else { throw ModelError.unexpected }
        return list
    }

    func addProject(_ path: String) async throws {
        try await request(.addProject(path: path), timeout: 60)
    }

    func screenshot() async -> Data? {
        guard case .screenshot(let data) = try? await request(.simulatorScreenshot, timeout: 20) else { return nil }
        return data
    }

    // MARK: Benachrichtigungen & Live-Aktivitäten

    static var pushEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    private func registerPush() {
        guard isConnected, let pushToken else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.captureworks.AppForge.Companion"
        Task { try? await request(.registerPush(token: pushToken, environment: Self.pushEnvironment, bundleID: bundleID)) }
    }

    private func startLiveActivity(_ target: LiveTarget, title: String, projectID: String, notify: Bool) {
        let project = project(projectID)
        liveActivities.start(
            target: target, title: title, projectID: projectID,
            projectName: project?.name ?? "AppForge", isMac: project?.isMac ?? false
        ) { [weak self] token in
            Task { @MainActor in
                try? await self?.request(.registerLiveActivity(target: target, token: token, environment: Self.pushEnvironment))
            }
        }
    }

    // MARK: Links & Erfassung

    func handle(_ url: URL) {
        if pair(with: url) { selectedTab = .mac; return }
        guard url.scheme == CompanionProtocol.urlScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            if url.host == "auftraege" { selectedTab = .missions }
            return
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host {
        case "idee":
            if let projectID = value("projekt") {
                capture = CaptureRequest(projectID: projectID, mode: CaptureMode(rawValue: value("modus") ?? "") ?? .write)
            }
        case "chat":
            if let projectID = value("projekt"), let sessionID = value("chat") {
                selectedTab = .apps
                pendingChat = (projectID, sessionID)
            }
        default:
            break
        }
    }

    private func takeCaptureRequest() {
        guard let request = SharedStore.takeCaptureRequest(), !request.projectID.isEmpty else { return }
        capture = CaptureRequest(projectID: request.projectID, mode: request.mode)
    }
}
