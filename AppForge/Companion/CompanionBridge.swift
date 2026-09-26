import AppKit
import Foundation
import Observation

/// Verbindet AppForge mit der iPhone-App: nimmt Befehle entgegen, schickt den Live-Zustand,
/// überwacht Aufgaben vom iPhone und meldet sich per Push und Live-Aktivität.
///
/// Das iPhone spricht nie direkt mit der Engine, sondern immer mit dieser Bridge – so gelten
/// Zentrale, Budgets und Berechtigungsmodus auch unterwegs.
@MainActor
@Observable
final class CompanionBridge {
    @ObservationIgnored weak var store: AppStore?

    struct Client: Identifiable {
        let channel: CompanionChannel
        var deviceID: String?
        var deviceName = "iPhone"
        var ready = false
        var openChat: (projectID: String, sessionID: String)?
        var chatTitle: String?
        var lastChat: Data?
        var id: UUID { channel.id }
    }

    /// Ein gekoppeltes iPhone mit Push-Adresse.
    struct Device: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        var pushToken: String?
        var environment: String = "production"
        var bundleID: String = "com.captureworks.AppForge.Companion"
        var lastSeen: Date = .now
    }

    /// Eine Aufgabe vom iPhone, die beobachtet wird – für Benachrichtigungen und die Live-Aktivität.
    struct Watch: Codable, Hashable {
        var target: LiveTarget
        var projectID: String
        var title: String
        var notify: Bool
        var armedAt: Date = .now
        var liveToken: String?
        var liveEnvironment: String?
        var lastState: LiveTaskState?
        var lastLivePush: Date?
        var notifiedPermissions: [String] = []
        var finished = false
        var finishedAt: Date?
    }

    enum BridgeError: LocalizedError {
        case engineOffline, notFound(String), failed(String)

        var errorDescription: String? {
            switch self {
            case .engineOffline: "Die Engine auf dem Mac läuft gerade nicht."
            case .notFound(let what): "\(what) nicht gefunden."
            case .failed(let message): message
            }
        }
    }

    // MARK: Einstellungen

    var enabled: Bool = UserDefaults.standard.object(forKey: "companion.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "companion.enabled")
            if enabled { start() } else { stop() }
        }
    }

    /// Mac nicht einschlafen lassen, damit das iPhone ihn jederzeit erreicht.
    var keepAwake: Bool = UserDefaults.standard.object(forKey: "companion.keepAwake") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "companion.keepAwake")
            awake.set(enabled && keepAwake)
        }
    }

    /// Adresse für unterwegs, z. B. die Tailscale-Adresse. Landet im QR-Code.
    var remoteHost: String = UserDefaults.standard.string(forKey: "companion.remoteHost") ?? "" {
        didSet { UserDefaults.standard.set(remoteHost, forKey: "companion.remoteHost") }
    }

    // MARK: Zustand

    private(set) var serverState: CompanionServer.State = .stopped
    private(set) var clients: [Client] = []
    private(set) var devices: [Device] = []
    private(set) var watches: [Watch] = []
    let push = PushService()

    @ObservationIgnored private let server = CompanionServer()
    @ObservationIgnored private let awake = KeepAwake()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var lastSnapshot: Data?
    @ObservationIgnored private var lastProjects: Data?
    @ObservationIgnored private var iconCache: [String: Data] = [:]
    /// Offene Freigaben aus Projekten, die am Mac gerade nicht geöffnet sind.
    @ObservationIgnored private var otherPermissions: [String: [PermissionRequest]] = [:]
    /// „Sag Bescheid“ in einer Nachricht an die Zentrale gilt für den nächsten gestarteten Vorschlag.
    @ObservationIgnored private var zentraleNotifyPending = false

    /// Der Bereich „Mac“ arbeitet im Benutzerordner.
    static var macWorkspace: String { FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingSuffix("/") }

    /// Hinweis an jeden Agenten, der eine Aufgabe vom iPhone bekommt.
    static let phoneHint = """
    Diese Nachricht kommt von der AppForge-iPhone-App. Die Nutzerin bzw. der Nutzer sitzt NICHT am Mac und sieht den Bildschirm nicht – das iPhone dient nur zum Senden und Lesen.
    - Arbeite selbstständig auf dem Mac und nutze alle verfügbaren Werkzeuge, Konnektoren und MCP-Server.
    - Verweise nicht auf Dinge, die man nur am Mac sieht („schau in Xcode“, „klick auf …“). Berichte Ergebnisse knapp als Text.
    - Wenn du die UI änderst, prüfe sie im Simulator per Screenshot und hänge den Screenshot an, damit er auf dem iPhone sichtbar ist.
    - Frag nur nach, wenn du ohne Antwort wirklich nicht weiterkommst – und dann mit einer klaren, kurzen Frage.
    """

    init() {
        devices = Self.load("companion.devices") ?? []
        watches = Self.load("companion.watches") ?? []
    }

    // MARK: Start & Stopp

    var isRunning: Bool {
        if case .listening = serverState { return true }
        return false
    }

    func startIfEnabled() {
        guard enabled, loopTask == nil else { return }
        start()
    }

    private func start() {
        let name = CompanionPairing.macName
        server.start(secret: CompanionPairing.secret(), port: CompanionProtocol.defaultPort, name: name) { [weak self] state in
            Task { @MainActor in self?.serverState = state }
        } onConnection: { [weak self] channel in
            Task { @MainActor in self?.accept(channel) }
        }
        awake.set(keepAwake)
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runTick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if remoteHost.isEmpty {
            Task { if let host = await CompanionPairing.detectTailscaleHost() { remoteHost = host } }
        }
    }

    private func stop() {
        loopTask?.cancel()
        loopTask = nil
        server.stop()
        clients.forEach { $0.channel.close() }
        clients = []
        awake.set(false)
        serverState = .stopped
    }

    /// Neuer Schlüssel – alle iPhones müssen neu gekoppelt werden.
    func resetPairing() {
        CompanionPairing.resetSecret()
        devices = []
        save(devices, "companion.devices")
        if enabled { stop(); start() }
    }

    var pairingInfo: PairingInfo {
        CompanionPairing.info(remoteHost: remoteHost.isEmpty ? nil : remoteHost)
    }

    // MARK: Verbindungen

    private func accept(_ channel: CompanionChannel) {
        clients.append(Client(channel: channel))
        let id = channel.id
        channel.start { [weak self] state in
            Task { @MainActor in self?.channelChanged(id, state) }
        } onMessage: { [weak self] data in
            Task { @MainActor in self?.receive(data, from: id) }
        }
    }

    private func channelChanged(_ id: UUID, _ state: CompanionChannel.State) {
        switch state {
        case .failed, .closed:
            clients.removeAll { $0.id == id }
        default:
            break
        }
    }

    private func receive(_ data: Data, from id: UUID) {
        guard let request = try? CompanionCoding.decoder().decode(CompanionRequest.self, from: data),
              let client = clients.first(where: { $0.id == id }) else { return }
        let channel = client.channel
        let requestID = request.id
        func reply(_ payload: CompanionReply.Payload) {
            channel.send(CompanionReply(requestID: requestID, payload: payload))
        }
        func run(_ work: @escaping @MainActor () async throws -> CompanionReply.Payload) {
            Task { @MainActor in
                do { reply(try await work()) } catch { reply(.error(error.localizedDescription)) }
            }
        }

        switch request.action {
        case .hello(let deviceID, let deviceName, _):
            updateClient(id) { $0.deviceID = deviceID; $0.deviceName = deviceName; $0.ready = true }
            upsertDevice(id: deviceID) { $0.name = deviceName; $0.lastSeen = .now }
            reply(.welcome(macName: CompanionPairing.macName, protocolVersion: CompanionProtocol.version))
            channel.send(CompanionReply(requestID: nil, payload: .projects(projects())))
            if let snapshot = makeSnapshot() { channel.send(CompanionReply(requestID: nil, payload: .snapshot(snapshot))) }

        case .projects:
            reply(.projects(projects()))

        case .ideas(let projectID):
            reply(.ideas(projectID: projectID, ideas: ideas.ideas(for: projectID)))

        case .addIdeas(let list):
            ideas.add(list)
            reply(.ok)

        case .setIdeaStatus(let ideaID, let projectID, let status):
            ideas.setStatus(status, id: ideaID, projectID: projectID)
            reply(.ok)

        case .deleteIdea(let ideaID, let projectID):
            ideas.delete(id: ideaID, projectID: projectID)
            reply(.ok)

        case .analyzeIdea(let ideaID, let projectID):
            Task { await ideas.analyze(ideaID, projectID: projectID) }
            reply(.ok)

        case .askIdeas(let projectID, let question):
            run { return .answer(try await self.ideas.ask(question, projectID: projectID)) }

        case .sessions(let projectID):
            run { return .sessions(projectID: projectID, sessions: try await self.sessions(projectID)) }

        case .openChat(let projectID, let sessionID):
            updateClient(id) { $0.openChat = (projectID, sessionID); $0.lastChat = nil; $0.chatTitle = nil }
            Task { await pushChat(to: id) }
            reply(.ok)

        case .closeChat:
            updateClient(id) { $0.openChat = nil; $0.lastChat = nil }
            reply(.ok)

        case .sendChat(let projectID, let sessionID, let text, let agent):
            run {
                let (session, notify) = try await self.sendChat(projectID: projectID, sessionID: sessionID, text: text, agent: agent)
                return .chatStarted(projectID: projectID, sessionID: session, notify: notify)
            }

        case .abortChat(let projectID, let sessionID):
            run {
                guard let client = self.store?.client else { throw BridgeError.engineOffline }
                try await client.abort(sessionID: sessionID, directory: projectID)
                return .ok
            }

        case .setNotify(let target, let enabled):
            if let index = watches.firstIndex(where: { $0.target == target }) {
                watches[index].notify = enabled
                save(watches, "companion.watches")
            } else if enabled, case .session(let projectID, _) = target {
                arm(target, projectID: projectID, title: projectName(projectID), notify: true)
            }
            reply(.ok)

        case .discoverProjects:
            let existing = Set(store?.projects ?? [])
            run { return .discovered(await Self.discoverProjects(excluding: existing)) }

        case .addProject(let path):
            run {
                guard let store = self.store else { throw BridgeError.engineOffline }
                await store.addProject(URL(filePath: path))
                self.lastProjects = nil
                return .projects(self.projects())
            }

        case .registerPush(let token, let environment, let bundleID):
            if let deviceID = client.deviceID {
                upsertDevice(id: deviceID) { $0.pushToken = token; $0.environment = environment; $0.bundleID = bundleID }
            }
            reply(.ok)

        case .registerLiveActivity(let target, let token, let environment):
            if let index = watches.firstIndex(where: { $0.target == target }) {
                watches[index].liveToken = token
                watches[index].liveEnvironment = environment
                watches[index].lastState = nil
                save(watches, "companion.watches")
            }
            reply(.ok)

        case .zentrale(let text, let projectID):
            run {
                guard let store = self.store else { throw BridgeError.engineOffline }
                if let projectID, projectID != store.selectedProject, store.projects.contains(projectID) {
                    await store.openProject(projectID)
                }
                if NotifyIntent.wants(text) { self.zentraleNotifyPending = true }
                await store.dispatcher.send(text + "\n\n(Gesendet vom iPhone – ich sitze nicht am Mac.)")
                if let error = store.dispatcher.error { throw BridgeError.failed(error) }
                return .ok
            }

        case .newZentraleConversation:
            store?.dispatcher.newConversation()
            reply(.ok)

        case .launchProposal(let messageID):
            run { try await self.launch(messageID) }

        case .stopMission(let missionID):
            run {
                guard let dispatcher = self.store?.dispatcher,
                      let mission = dispatcher.missions.first(where: { $0.id == missionID }) else { throw BridgeError.notFound("Auftrag") }
                await dispatcher.stop(mission)
                return .ok
            }

        case .replyPermission(let requestID, let directory, let answer):
            run {
                try await self.replyPermission(requestID, directory: directory, answer: answer)
                return .ok
            }

        case .simulatorScreenshot:
            run { return .screenshot(await self.screenshot()) }
        }
    }

    private func updateClient(_ id: UUID, _ change: (inout Client) -> Void) {
        guard let index = clients.firstIndex(where: { $0.id == id }) else { return }
        change(&clients[index])
    }

    private func upsertDevice(id: String, _ change: (inout Device) -> Void) {
        if let index = devices.firstIndex(where: { $0.id == id }) {
            change(&devices[index])
        } else {
            var device = Device(id: id, name: "iPhone")
            change(&device)
            devices.append(device)
        }
        save(devices, "companion.devices")
    }

    private func broadcast(_ payload: CompanionReply.Payload) {
        let reply = CompanionReply(requestID: nil, payload: payload)
        guard let data = try? CompanionCoding.encoder().encode(reply) else { return }
        for client in clients where client.ready { client.channel.send(data) }
    }

    // MARK: Takt

    private func runTick() async {
        tick += 1
        let hasClients = clients.contains { $0.ready }
        if hasClients {
            if let snapshot = makeSnapshot(), let data = try? CompanionCoding.encoder().encode(snapshot), data != lastSnapshot {
                lastSnapshot = data
                broadcast(.snapshot(snapshot))
            }
            if tick % 5 == 0 { broadcastProjectsIfChanged() }
            for client in clients where client.openChat != nil { await pushChat(to: client.id) }
        }
        if tick % 3 == 0 {
            await pollOtherPermissions()
            await evaluateWatches()
        }
    }

    /// Von `IdeaStore` aufgerufen, wenn sich Ideen geändert haben.
    func ideasChanged(_ projectID: String) {
        broadcast(.ideas(projectID: projectID, ideas: ideas.ideas(for: projectID)))
        broadcastProjectsIfChanged()
    }

    private func broadcastProjectsIfChanged() {
        let list = projects()
        guard let data = try? CompanionCoding.encoder().encode(list), data != lastProjects else { return }
        lastProjects = data
        broadcast(.projects(list))
    }

    private var ideas: IdeaStore { store!.ideas }

    // MARK: Projekte

    private func projects() -> [CompanionProject] {
        guard let store else { return [] }
        var list = store.projects.map { path in
            let info = ProjectInfoCache.info(for: path)
            return CompanionProject(
                id: path, name: info.appName, folderName: info.folderName,
                iconPNG: icon(for: path, image: info.icon), openIdeas: ideas.openCount(for: path),
                spentUSD: store.ledger.total(for: path), isMac: false
            )
        }
        let mac = Self.macWorkspace
        list.append(CompanionProject(id: mac, name: "Mac", folderName: "Benutzerordner", iconPNG: nil,
                                     openIdeas: ideas.openCount(for: mac), spentUSD: store.ledger.total(for: mac), isMac: true))
        return list
    }

    private func projectName(_ projectID: String) -> String {
        projectID == Self.macWorkspace ? "Mac" : ProjectInfoCache.info(for: projectID).appName
    }

    private func icon(for path: String, image: NSImage?) -> Data? {
        if let cached = iconCache[path] { return cached }
        guard let image, let data = Self.png(image, size: 120) else { return nil }
        iconCache[path] = data
        return data
    }

    private static func png(_ image: NSImage, size: CGFloat) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Sucht Xcode-Projekte in den üblichen Ordnern, die noch nicht in AppForge sind.
    nonisolated private static func discoverProjects(excluding existing: Set<String>) async -> [DiscoveredProject] {
        await Task.detached(priority: .utility) { scanForProjects(excluding: existing) }.value
    }

    /// Synchron, weil `FileManager.DirectoryEnumerator` nicht in asynchronem Kontext durchlaufen werden darf.
    nonisolated private static func scanForProjects(excluding existing: Set<String>) -> [DiscoveredProject] {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let roots = ["Developer", "Projects", "Projekte", "Code", "GitHub", "Xcode", "Documents", "Desktop"]
                .map { home.appending(path: $0, directoryHint: .isDirectory) }
                .filter { fm.fileExists(atPath: $0.path) }
            let skip: Set<String> = ["build", "DerivedData", ".build", "Pods", "node_modules", "Carthage", "fastlane"]
            var found: [String: DiscoveredProject] = [:]
            for root in roots {
                guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in walker {
                    if walker.level > 4 || skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                    guard url.pathExtension == "xcodeproj" else { continue }
                    let folder = url.deletingLastPathComponent().path(percentEncoded: false).trimmingSuffix("/")
                    guard !existing.contains(folder), found[folder] == nil else { continue }
                    found[folder] = DiscoveredProject(
                        id: folder, name: url.deletingPathExtension().lastPathComponent,
                        detail: folder.replacingOccurrences(of: home.path(percentEncoded: false).trimmingSuffix("/"), with: "~")
                    )
                    if found.count >= 150 { break }
                }
            }
            return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Chats

    private func sessions(_ projectID: String) async throws -> [CompanionSession] {
        guard let client = store?.client else { throw BridgeError.engineOffline }
        let busy = (try? await client.sessionStatus(directory: projectID)) ?? [:]
        return try await client.sessions(directory: projectID)
            .filter { $0.parentID == nil && !AppStore.isHelperSession($0) }
            .sorted { $0.time.updated > $1.time.updated }
            .prefix(60)
            .map { session in
                CompanionSession(
                    id: session.id, projectID: projectID, title: session.title,
                    updatedAt: Date(timeIntervalSince1970: session.time.updated / 1000),
                    busy: busy[session.id] != nil,
                    notify: watches.first { $0.target == .session(projectID: projectID, sessionID: session.id) }?.notify ?? false
                )
            }
    }

    private func sendChat(projectID: String, sessionID: String?, text: String, agent: String?) async throws -> (String, Bool) {
        guard let store, let client = store.client else { throw BridgeError.engineOffline }
        let session: String
        if let sessionID {
            session = sessionID
        } else {
            session = try await client.createSession(directory: projectID).id
        }
        // Ohne Angabe im bestehenden Chat mit demselben Agenten weitermachen (z. B. dem Projekt-Kenner).
        var agent = agent
        if agent == nil, let sessionID {
            agent = (try? await client.messages(sessionID: sessionID, directory: projectID))?
                .last { $0.info.isUser }?.info.agent
        }
        // „@motion-designer …“ usw. – erwähnte Agenten direkt beauftragen, wie am Mac.
        let helpers = Set(store.subagents.map(\.name))
        let mentions = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ":" }).compactMap { word -> String? in
            guard word.hasPrefix("@") else { return nil }
            let name = String(word.dropFirst())
            return helpers.contains(name) ? name : nil
        }
        let isMac = projectID == Self.macWorkspace
        let system = isMac ? Self.phoneHint : store.platform.systemHint + "\n\n" + Self.phoneHint
        try await client.prompt(
            sessionID: session, directory: projectID, text: text, mentions: mentions,
            model: store.selectedModel, agent: agent ?? "build", system: system
        )
        let target = LiveTarget.session(projectID: projectID, sessionID: session)
        let alreadyNotifying = watches.first { $0.target == target }?.notify ?? false
        let notify = alreadyNotifying || NotifyIntent.wants(text)
        arm(target, projectID: projectID, title: ActivityDigest.short(text.replacingOccurrences(of: "\n", with: " "), 60), notify: notify)
        return (session, notify)
    }

    private func pushChat(to clientID: UUID) async {
        guard let client = clients.first(where: { $0.id == clientID }), let open = client.openChat,
              let engine = store?.client else { return }
        let projectID = open.projectID
        let sessionID = open.sessionID
        guard let envelopes = try? await engine.messages(sessionID: sessionID, directory: projectID) else { return }
        let busy = ((try? await engine.sessionStatus(directory: projectID)) ?? [:])[sessionID] != nil
        let messages = envelopes.map { ChatMessage(info: $0.info, parts: $0.parts) }
        var title = client.chatTitle
        if title == nil || client.lastChat == nil {
            title = (try? await engine.sessions(directory: projectID))?.first { $0.id == sessionID }?.title
            updateClient(clientID) { $0.chatTitle = title }
        }
        let chat = CompanionChat(
            projectID: projectID, sessionID: sessionID, title: title ?? "Chat", busy: busy,
            notify: watches.first { $0.target == .session(projectID: projectID, sessionID: sessionID) }?.notify ?? false,
            activity: busy ? ActivityDigest.activity(of: messages) : nil,
            messages: Self.chatMessages(messages)
        )
        guard let data = try? CompanionCoding.encoder().encode(chat) else { return }
        // Die Verbindung könnte inzwischen zu einem anderen Chat gewechselt sein.
        guard let current = clients.first(where: { $0.id == clientID }), current.openChat?.sessionID == sessionID,
              current.lastChat != data else { return }
        updateClient(clientID) { $0.lastChat = data }
        current.channel.send(CompanionReply(requestID: nil, payload: .chat(chat)))
    }

    static func chatMessages(_ messages: [ChatMessage]) -> [CompanionChatMessage] {
        var imageBudget = 3
        let recent = messages.suffix(80)
        var result: [CompanionChatMessage] = []
        for message in recent.reversed() {
            var images: [Data] = []
            let parts = message.parts + message.parts.flatMap { $0.state?.attachments ?? [] }
            for part in parts.reversed() where imageBudget > 0 && part.isImage {
                if let url = part.url, let data = Self.imageData(fromDataURL: url), data.count < 1_500_000 {
                    images.append(data)
                    imageBudget -= 1
                }
            }
            let text = message.parts
                .filter { $0.type == "text" && $0.synthetic != true }
                .compactMap(\.text)
                .joined(separator: "\n")
            let steps = message.parts.filter { $0.type == "tool" }.map(ActivityDigest.describe)
            result.append(CompanionChatMessage(
                id: message.id, isUser: message.info.isUser,
                text: text.count > 12_000 ? String(text.prefix(12_000)) + " …" : text,
                steps: Array(steps.suffix(30)),
                completed: message.info.isUser || message.info.time.completed != nil,
                error: message.info.errorMessage, costUSD: message.info.cost,
                agent: message.info.agent, model: message.info.modelLabel,
                createdAt: Date(timeIntervalSince1970: message.info.time.created / 1000),
                images: images
            ))
        }
        return result.reversed()
    }

    private static func imageData(fromDataURL url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    // MARK: Zentrale

    private func launch(_ messageID: String) async throws -> CompanionReply.Payload {
        guard let dispatcher = store?.dispatcher,
              let message = dispatcher.messages.first(where: { $0.id == messageID }),
              let proposal = dispatcher.proposal(for: message), proposal.dispatch else { throw BridgeError.notFound("Vorschlag") }
        guard !dispatcher.isLaunched(messageID) else { throw BridgeError.failed("Dieser Vorschlag läuft schon.") }
        let before = Set(dispatcher.missions.map(\.id))
        await dispatcher.launch(proposal, from: messageID)
        let created = dispatcher.missions.filter { !before.contains($0.id) }
        guard let first = created.first, let groupID = first.groupID else {
            throw BridgeError.failed(dispatcher.error ?? "Der Vorschlag konnte nicht gestartet werden.")
        }
        let notify = zentraleNotifyPending
        zentraleNotifyPending = false
        let title = proposal.title ?? first.title
        arm(.missionGroup(groupID), projectID: first.directory, title: title, notify: notify)
        return .launched(groupID: groupID, title: title, projectName: projectName(first.directory), notify: notify)
    }

    // MARK: Freigaben

    private func replyPermission(_ requestID: String, directory: String, answer: PermissionAnswer) async throws {
        guard let store, let client = store.client else { throw BridgeError.engineOffline }
        let reply = PermissionReply(rawValue: answer.rawValue) ?? .once
        if directory == store.selectedProject, let request = store.permissions.first(where: { $0.id == requestID }) {
            await store.reply(to: request, reply)
        } else {
            try await client.replyPermission(requestID: requestID, directory: directory, reply: reply)
            otherPermissions[directory]?.removeAll { $0.id == requestID }
        }
    }

    /// Freigaben aus Projekten, die am Mac gerade nicht geöffnet sind (dort hört AppForge keine Events mit).
    /// Der Berechtigungsmodus gilt auch hier.
    private func pollOtherPermissions() async {
        guard let store, let client = store.client else { return }
        var directories = Set(watches.filter { !$0.finished }.map(\.projectID))
        directories.formUnion(store.dispatcher.runningMissions.map(\.directory))
        directories.formUnion(clients.compactMap { $0.openChat?.projectID })
        if let selected = store.selectedProject { directories.remove(selected) }
        var result: [String: [PermissionRequest]] = [:]
        for directory in directories {
            guard let pending = try? await client.pendingPermissions(directory: directory) else { continue }
            var open: [PermissionRequest] = []
            for request in pending {
                if store.knowledge.owns(request.sessionID) { continue }  // entscheidet der Wissensdienst
                if store.permissionMode.autoApproves(request) {
                    try? await client.replyPermission(requestID: request.id, directory: directory, reply: .once)
                } else {
                    open.append(request)
                }
            }
            if !open.isEmpty { result[directory] = open }
        }
        otherPermissions = result
    }

    private var allPermissions: [(request: PermissionRequest, directory: String)] {
        guard let store else { return [] }
        var list: [(request: PermissionRequest, directory: String)] = []
        if let selected = store.selectedProject {
            for request in store.permissions { list.append((request: request, directory: selected)) }
        }
        for (directory, requests) in otherPermissions {
            for request in requests { list.append((request: request, directory: directory)) }
        }
        return list
    }

    // MARK: Beobachten, Benachrichtigen, Live-Aktivität

    private func arm(_ target: LiveTarget, projectID: String, title: String, notify: Bool) {
        if let index = watches.firstIndex(where: { $0.target == target }) {
            watches[index].notify = notify
            watches[index].armedAt = .now
            watches[index].finished = false
            watches[index].finishedAt = nil
            watches[index].lastState = nil
            watches[index].title = title
        } else {
            watches.append(Watch(target: target, projectID: projectID, title: title, notify: notify))
        }
        save(watches, "companion.watches")
    }

    private func evaluateWatches() async {
        guard let store, let client = store.client, !watches.isEmpty else { return }
        var busyByDirectory: [String: [String: JSONValue]] = [:]
        let permissions = allPermissions

        for index in watches.indices where !watches[index].finished {
            let watch = watches[index]
            var state: LiveTaskState
            var openPermissions: [(request: PermissionRequest, directory: String)] = []
            var summary: String?

            switch watch.target {
            case .session(let projectID, let sessionID):
                if busyByDirectory[projectID] == nil {
                    busyByDirectory[projectID] = (try? await client.sessionStatus(directory: projectID)) ?? [:]
                }
                let busy = busyByDirectory[projectID]?[sessionID] != nil
                guard let envelopes = try? await client.messages(sessionID: sessionID, directory: projectID) else { continue }
                let messages = envelopes.map { ChatMessage(info: $0.info, parts: $0.parts) }
                let children = Set(((try? await client.children(sessionID: sessionID, directory: projectID)) ?? []).map(\.id))
                openPermissions = permissions.filter { $0.request.sessionID == sessionID || children.contains($0.request.sessionID) }
                let lastUser = messages.last { $0.info.isUser }
                let answer = messages.last { !$0.info.isUser && $0.info.parentID == lastUser?.id }
                let answered = !busy && answer?.info.time.completed != nil
                    && (lastUser.map { Date(timeIntervalSince1970: $0.info.time.created / 1000) >= watch.armedAt.addingTimeInterval(-5) } ?? false)
                let failed = answered && answer?.info.errorMessage != nil
                summary = answer.flatMap(Self.lastText)
                let kind: LiveTaskState.Kind = !openPermissions.isEmpty ? .needsYou : answered ? (failed ? .failed : .done) : .running
                state = LiveTaskState(
                    kind: kind, title: watch.title, status: Self.statusTitle(kind),
                    activity: kind == .running ? ActivityDigest.activity(of: messages) : (failed ? answer?.info.errorMessage : summary),
                    spentUSD: envelopes.compactMap(\.info.cost).reduce(0, +),
                    startedAt: watch.armedAt.timeIntervalSince1970,
                    endedAt: answered ? Date.now.timeIntervalSince1970 : nil,
                    partsDone: answered ? 1 : 0, partsTotal: 1
                )

            case .missionGroup(let groupID):
                let missions = store.dispatcher.missions.filter { $0.groupID == groupID }
                guard !missions.isEmpty else { continue }
                let sessionIDs = Set(missions.map(\.sessionID) + missions.flatMap { $0.subagents?.compactMap(\.childSessionID) ?? [] })
                openPermissions = permissions.filter { sessionIDs.contains($0.request.sessionID) }
                let finished = missions.allSatisfy(\.state.isFinished)
                let failed = finished && missions.contains { $0.state != .done }
                let running = missions.first { !$0.state.isFinished }
                summary = missions.compactMap(\.activity).last
                let kind: LiveTaskState.Kind = !openPermissions.isEmpty ? .needsYou : finished ? (failed ? .failed : .done) : .running
                state = LiveTaskState(
                    kind: kind, title: watch.title,
                    status: finished && failed ? (missions.first { $0.state != .done }?.state.title ?? "gestoppt") : Self.statusTitle(kind),
                    activity: running.map { "\($0.title): \($0.activity ?? "arbeitet")" } ?? summary,
                    spentUSD: missions.map(\.spentUSD).reduce(0, +),
                    startedAt: (missions.map(\.startedAt).min() ?? watch.armedAt).timeIntervalSince1970,
                    endedAt: finished ? (missions.compactMap(\.endedAt).max() ?? .now).timeIntervalSince1970 : nil,
                    partsDone: missions.filter(\.state.isFinished).count, partsTotal: missions.count
                )
            }

            let name = projectName(watch.projectID)

            // Nachfragen
            let fresh = openPermissions.filter { !watch.notifiedPermissions.contains($0.request.id) }
            if !fresh.isEmpty {
                watches[index].notifiedPermissions += fresh.map(\.request.id)
                if watch.notify {
                    for item in fresh {
                        await sendAlert(PushService.Alert(
                            title: "❓ \(name) braucht dich",
                            body: "\(watch.title)\n\(Self.describe(item.request))",
                            category: "PERMISSION", threadID: watch.projectID,
                            userInfo: ["permissionID": item.request.id, "directory": item.directory, "projectID": watch.projectID]
                        ))
                    }
                }
            }

            // Fertig
            let isDone = state.kind == .done || state.kind == .failed
            if isDone {
                watches[index].finished = true
                watches[index].finishedAt = .now
                if watch.notify {
                    var userInfo = ["projectID": watch.projectID]
                    if case .session(_, let sessionID) = watch.target { userInfo["sessionID"] = sessionID }
                    await sendAlert(PushService.Alert(
                        title: state.kind == .done ? "✅ \(name): fertig" : "⚠️ \(name): \(state.status)",
                        body: "\(watch.title)\n\(summary ?? state.activity ?? "")",
                        category: "DONE", threadID: watch.projectID, userInfo: userInfo
                    ))
                }
            }

            // Live-Aktivität
            if let token = watch.liveToken, let device = devices.first(where: { $0.pushToken != nil }) ?? devices.first {
                let changed = state != watch.lastState
                let kindChanged = state.kind != watch.lastState?.kind
                let due = watch.lastLivePush.map { Date.now.timeIntervalSince($0) > 12 } ?? true
                if changed && (kindChanged || due || isDone) {
                    try? await push.sendLiveActivity(
                        state: state, end: isDone, alert: nil, token: token,
                        environment: watch.liveEnvironment ?? device.environment, topic: device.bundleID
                    )
                    watches[index].lastState = state
                    watches[index].lastLivePush = .now
                }
            }
        }

        // Erledigte Beobachtungen nach einem Tag vergessen
        watches.removeAll { $0.finished && ($0.finishedAt ?? .distantPast) < Date.now.addingTimeInterval(-86_400) }
        save(watches, "companion.watches")
    }

    private func sendAlert(_ alert: PushService.Alert) async {
        for device in devices {
            guard let token = device.pushToken else { continue }
            try? await push.send(alert, to: token, environment: device.environment, topic: device.bundleID)
        }
    }

    private static func statusTitle(_ kind: LiveTaskState.Kind) -> String {
        switch kind {
        case .running: "arbeitet"
        case .needsYou: "braucht dich"
        case .done: "fertig"
        case .failed: "fehlgeschlagen"
        }
    }

    private static func lastText(_ message: ChatMessage) -> String? {
        let text = message.parts.filter { $0.type == "text" && $0.synthetic != true }.compactMap(\.text).joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : ActivityDigest.short(text, 180)
    }

    static func describe(_ request: PermissionRequest) -> String {
        let what: String = switch request.permission {
        case "bash": "Befehl"
        case "edit", "write": "Dateiänderung"
        case "external_directory": "Zugriff außerhalb des Projekts"
        default: request.permission
        }
        let detail = request.patterns.joined(separator: " ")
        return detail.isEmpty ? what : "\(what): \(ActivityDigest.short(detail, 120))"
    }

    // MARK: Schnappschuss

    private func makeSnapshot() -> CompanionSnapshot? {
        guard let store else { return nil }
        let dispatcher = store.dispatcher
        let engineError: String? = if case .failed(let message) = store.engineState { message } else { nil }

        let missions = dispatcher.missions.prefix(25).map { mission in
            CompanionMission(
                id: mission.id, title: mission.title, projectID: mission.directory, projectName: projectName(mission.directory),
                state: mission.state.rawValue, stateTitle: mission.state.title, isFinished: mission.state.isFinished,
                agent: mission.agent, model: mission.activeModel, activity: mission.activity,
                spentUSD: mission.spentUSD, budgetUSD: mission.budgetUSD, estimatedCostUSD: mission.estimatedCostUSD,
                startedAt: mission.startedAt, endedAt: mission.endedAt, timeLimitMinutes: mission.timeLimitMinutes,
                files: mission.insights?.files ?? [], additions: mission.insights?.additions ?? 0,
                deletions: mission.insights?.deletions ?? 0, buildOK: mission.insights?.build?.ok,
                buildErrors: mission.insights?.build?.errors, testsLabel: mission.insights?.testsLabel,
                testsOK: mission.insights?.tests?.ok, progress: mission.insights?.progress
            )
        }

        let permissions = allPermissions.map { item in
            let root = item.directory == store.selectedProject ? store.rootSession(of: item.request.sessionID) : item.request.sessionID
            let title = dispatcher.mission(forRootSession: root)?.title ?? projectName(item.directory)
            let diff = item.request.metadata?["diff"]?.stringValue ?? item.request.metadata?["command"]?.stringValue
            return CompanionPermission(
                id: item.request.id, sessionID: item.request.sessionID, directory: item.directory,
                permission: item.request.permission, title: title, patterns: item.request.patterns,
                detail: diff.map { String($0.prefix(4000)) }
            )
        }

        let zentrale = dispatcher.messages.suffix(30).map { message in
            let text = dispatcher.text(of: message)
            let proposal = message.info.isUser ? nil : dispatcher.proposal(for: message)
            return CompanionZentraleMessage(
                id: message.id, isUser: message.info.isUser,
                text: message.info.isUser
                    ? text.replacingOccurrences(of: "\n\n(Gesendet vom iPhone – ich sitze nicht am Mac.)", with: "")
                    : (proposal?.reply.isEmpty == false ? proposal!.reply : text),
                completed: message.info.isUser || message.info.time.completed != nil,
                proposal: proposal.flatMap { proposal in
                    guard proposal.dispatch else { return nil }
                    return CompanionProposal(
                        title: proposal.title, analysis: proposal.analysis, reason: proposal.reason,
                        estimatedCostUSD: proposal.estimatedCostUSD, estimatedMinutes: proposal.estimatedMinutes,
                        tasks: proposal.tasks.map { CompanionTask(title: $0.title, agent: $0.agent, model: $0.model, estimatedCostUSD: $0.estimatedCostUSD) }
                    )
                },
                launched: dispatcher.isLaunched(message.id)
            )
        }

        let events = dispatcher.events.prefix(20).map { event in
            CompanionEvent(id: event.id, date: event.date, source: event.source, text: event.text, tone: Self.tone(event.tone))
        }

        let booted = store.simulator.devices.first { $0.isBooted }
        return CompanionSnapshot(
            macName: CompanionPairing.macName, engineRunning: store.engineState == .running, engineError: engineError,
            selectedProjectID: store.selectedProject, permissionMode: store.permissionMode.title,
            spentToday: dispatcher.spentToday, eurPerUsd: Money.eurPerUsd, missions: Array(missions), permissions: permissions,
            zentrale: Array(zentrale), zentraleThinking: dispatcher.isThinking, zentraleError: dispatcher.error,
            events: Array(events), simulatorBooted: booted != nil, simulatorName: booted?.name
        )
    }

    private static func tone(_ tone: MissionEvent.Tone) -> CompanionEvent.Tone {
        switch tone {
        case .neutral: .neutral
        case .good: .good
        case .attention: .attention
        case .problem: .problem
        }
    }

    // MARK: Simulator

    private func screenshot() async -> Data? {
        let file = FileManager.default.temporaryDirectory.appending(path: "appforge-companion-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let result = await Shell.run(["xcrun", "simctl", "io", "booted", "screenshot", "--type=jpeg", file.path]),
              result.status == 0 else { return nil }
        return try? Data(contentsOf: file)
    }

    // MARK: Speichern

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Erkennt, ob im Text um eine Benachrichtigung gebeten wird („sag Bescheid, wenn …“).
enum NotifyIntent {
    private static let patterns = [
        #"benachrichtig"#, #"bescheid"#, #"meld\w*\s+(dich|mir|bei mir)"#, #"push[- ]?(nachricht|benachrichtigung|mitteilung)"#,
        #"notif"#, #"ping\s+mich"#, #"sag\s+mir,?\s+(wenn|sobald|falls)"#, #"informier\w*\s+mich"#,
        #"gib\s+mir\s+(eine\s+)?(info|nachricht|rückmeldung)"#, #"schreib\s+mir,?\s+(wenn|sobald)"#,
    ]

    static func wants(_ text: String) -> Bool {
        let lower = text.lowercased()
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        guard hasSuffix(suffix), count > suffix.count else { return self }
        return String(dropLast(suffix.count))
    }
}
