import CryptoKit
import Foundation
import Observation

/// Projektwissen: Für jede App liegt in `.appforge/wissen/` alles, was man über sie wissen muss –
/// Aufbau, Funktionen, Zusammenhänge und *warum* etwas so gebaut wurde. Eine Kurzfassung steht in
/// `AGENTS.md`, damit jeder Agent sie automatisch kennt und nicht erst suchen muss.
///
/// Ändert sich das Projekt (Agenten, Commits, Arbeit in Xcode), aktualisiert der Chronist das Wissen,
/// sobald ein paar Minuten Ruhe ist – nur die betroffenen Stellen, mit einem günstigen Modell.
/// Das „Warum“ kommt aus Commits, Chats und Aufträgen, die AppForge kennt.
@MainActor
@Observable
final class KnowledgeService {
    @ObservationIgnored weak var store: AppStore?

    /// Stand des Wissens – liegt als `stand.json` im Wissensordner des Projekts.
    struct Stand: Codable, Equatable {
        var commit: String?
        var fingerprint: String
        var builtAt: Date
        var updatedAt: Date
        var updates: Int
        var model: String?
    }

    enum Phase: Equatable {
        case idle, building, updating
        case failed(String)
    }

    struct Status: Equatable {
        var phase: Phase = .idle
        var stand: Stand?
        /// Projekt hat sich seit dem letzten Stand geändert.
        var outdated = false
        /// Was der Chronist gerade tut.
        var activity: String?
        var costUSD: Double?
    }

    private(set) var statuses: [String: Status] = [:]

    var autoUpdate: Bool = UserDefaults.standard.object(forKey: "knowledge.autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "knowledge.autoUpdate") }
    }

    /// Modell für den ersten Aufbau (gründlich). `nil` = das im Chat gewählte Modell.
    var buildModel: ModelSelection? { didSet { save(buildModel, "knowledge.buildModel") } }
    /// Modell für Aktualisierungen (klein und günstig). `nil` = das günstigste Modell mit Werkzeugen.
    var updateModel: ModelSelection? { didSet { save(updateModel, "knowledge.updateModel") } }

    nonisolated static let sessionTitle = "📚 Projektwissen"
    nonisolated static let folder = ".appforge/wissen"
    nonisolated static let chronistAgent = "chronist"
    nonisolated static let expertAgent = "kenner"
    /// Wie lange ein Projekt ruhig sein muss, bevor das Wissen aktualisiert wird.
    private static let quietPeriod: TimeInterval = 180

    @ObservationIgnored private var ownedSessions: [String: String] = [:]
    @ObservationIgnored private var pendingChange: [String: (fingerprint: String, since: Date)] = [:]
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    init() {
        buildModel = load("knowledge.buildModel")
        updateModel = load("knowledge.updateModel")
    }

    nonisolated static func isAgentSession(_ session: Session) -> Bool {
        session.title.hasPrefix(sessionTitle)
    }

    func status(for projectID: String) -> Status { statuses[projectID] ?? Status() }

    var isRunning: Bool { statuses.values.contains { $0.phase == .building || $0.phase == .updating } }

    // MARK: Start & Überwachung

    func start() {
        refreshStands()
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.checkAll()
            }
        }
    }

    /// Liest den Stand aller Projekte neu (z. B. nach dem Hinzufügen eines Projekts).
    func refreshStands() {
        guard let store else { return }
        for project in store.projects {
            var status = statuses[project] ?? Status()
            status.stand = Self.loadStand(project)
            statuses[project] = status
        }
    }

    /// Prüft alle Projekte mit Wissen auf Änderungen und aktualisiert, wenn es ruhig ist.
    private func checkAll() async {
        guard let store, store.client != nil else { return }
        for project in store.projects {
            guard let stand = statuses[project]?.stand ?? Self.loadStand(project) else { continue }
            let fingerprint = await Self.fingerprint(project)
            if fingerprint == stand.fingerprint {
                pendingChange[project] = nil
                setStatus(project) { $0.outdated = false }
                continue
            }
            setStatus(project) { $0.outdated = true }
            guard autoUpdate, !isRunning else { continue }
            // Erst warten, bis sich eine Weile nichts mehr ändert.
            if pendingChange[project]?.fingerprint != fingerprint {
                pendingChange[project] = (fingerprint, .now)
                continue
            }
            guard let since = pendingChange[project]?.since, Date.now.timeIntervalSince(since) >= Self.quietPeriod,
                  await isQuiet(project) else { continue }
            await update(project)
        }
    }

    /// Arbeitet gerade ein Agent in diesem Projekt? Dann nicht dazwischenfunken.
    private func isQuiet(_ project: String) async -> Bool {
        guard let store, let client = store.client else { return false }
        if store.dispatcher.runningMissions.contains(where: { $0.directory == project }) { return false }
        let busy = (try? await client.sessionStatus(directory: project)) ?? [:]
        return busy.isEmpty
    }

    // MARK: Aufbauen & Aktualisieren

    enum KnowledgeError: LocalizedError {
        case engineOffline, noModel, timeout, incomplete

        var errorDescription: String? {
            switch self {
            case .engineOffline: "Die Engine läuft nicht."
            case .noModel: "Kein passendes Modell verbunden."
            case .timeout: "Der Chronist ist nicht rechtzeitig fertig geworden."
            case .incomplete: "Das Wissen wurde nicht vollständig geschrieben."
            }
        }
    }

    /// Erster, gründlicher Aufbau des Projektwissens.
    func build(_ project: String) async {
        guard !isRunning else { return }
        let context = await history(project, since: nil)
        let prompt = """
        AUFBAU des Projektwissens für diese App. Lies das Projekt gründlich – jede relevante Datei – und schreibe das Wissen \
        nach deinen Anweisungen in den Ordner `\(Self.folder)/`. Nichts anderes ändern.

        Quellen für das „Warum“ (Commits, Chats, Aufträge):

        \(context)
        """
        await run(project, phase: .building, prompt: prompt, model: buildModel ?? store?.selectedModel)
    }

    /// Aktualisiert das Wissen nach Änderungen – nur, was betroffen ist.
    func update(_ project: String) async {
        guard !isRunning, let stand = statuses[project]?.stand ?? Self.loadStand(project) else { return }
        guard let changes = await changeReport(project, since: stand) else {
            // Nur das Wissen selbst hat sich geändert (z. B. committet) – Stand nachziehen, kein Agent nötig.
            await markDocumented(project, model: stand.model, isBuild: false)
            return
        }
        let context = await history(project, since: stand.updatedAt)
        let prompt = """
        AKTUALISIERUNG des Projektwissens. Seit dem letzten Stand (\(stand.updatedAt.formatted(date: .abbreviated, time: .shortened))) \
        hat sich Folgendes geändert. Lies zuerst `\(Self.folder)/kurzfassung.md` und die betroffenen Wissensdateien, prüfe die \
        Änderungen im Code und passe das Wissen gezielt an. Trage die Änderung in `chronik.md` ein und – wenn eine Entscheidung \
        dahintersteht – in `entscheidungen.md`. Schreibe nur in `\(Self.folder)/`.

        # Änderungen
        \(changes)

        # Warum (Chats und Aufträge seit dem letzten Stand)
        \(context)
        """
        await run(project, phase: .updating, prompt: prompt, model: updateModel ?? cheapestToolModel)
    }

    private var cheapestToolModel: ModelSelection? {
        ModelCatalog.entries(from: store?.providers)
            .filter { $0.model.supportsTools && $0.blendedPrice > 0 }
            .min { $0.blendedPrice < $1.blendedPrice }?
            .selection
    }

    private func run(_ project: String, phase: Phase, prompt: String, model: ModelSelection?) async {
        guard let store, let client = store.client else { return fail(project, KnowledgeError.engineOffline) }
        guard let model else { return fail(project, KnowledgeError.noModel) }
        let isBuild = phase == .building
        // Stand zu Beginn merken: Was währenddessen passiert, wird beim nächsten Mal dokumentiert.
        let startFingerprint = await Self.fingerprint(project)
        let startCommit = await Self.git(project, ["rev-parse", "HEAD"])
        setStatus(project) { $0.phase = phase; $0.activity = "liest sich ein"; $0.costUSD = nil }

        do {
            try FileManager.default.createDirectory(at: Self.folderURL(project), withIntermediateDirectories: true)
            let session = try await client.createSession(directory: project, title: "\(Self.sessionTitle) · \(isBuild ? "Aufbau" : "Update")")
            ownedSessions[session.id] = project
            defer {
                ownedSessions[session.id] = nil
                Task { try? await client.deleteSession(session.id, directory: project) }
            }
            try await client.prompt(sessionID: session.id, directory: project, text: prompt, model: model, agent: Self.chronistAgent, system: nil)

            let deadline = Date.now.addingTimeInterval(isBuild ? 60 * 60 : 20 * 60)
            try await Task.sleep(for: .seconds(3))
            var cost = 0.0
            while true {
                guard Date.now < deadline else {
                    try? await client.abort(sessionID: session.id, directory: project)
                    throw KnowledgeError.timeout
                }
                // Freigaben des Chronisten: nur Schreiben im Wissensordner.
                for request in (try? await client.pendingPermissions(directory: project)) ?? [] where request.sessionID == session.id {
                    await handlePermission(request, directory: project)
                }
                let envelopes = (try? await client.messages(sessionID: session.id, directory: project)) ?? []
                cost = envelopes.compactMap(\.info.cost).reduce(0, +)
                let messages = envelopes.map { ChatMessage(info: $0.info, parts: $0.parts) }
                setStatus(project) { $0.activity = ActivityDigest.activity(of: messages); $0.costUSD = cost }
                let busy = ((try? await client.sessionStatus(directory: project)) ?? [:])[session.id] != nil
                if !busy, let last = envelopes.last(where: { !$0.info.isUser }), last.info.time.completed != nil {
                    if let message = last.info.errorMessage { throw AgentFailure(message: message) }
                    break
                }
                try await Task.sleep(for: .seconds(4))
            }

            store.ledger.record(project: project, id: "wissen-\(session.id)", costUSD: cost)
            guard FileManager.default.fileExists(atPath: Self.folderURL(project).appending(path: "kurzfassung.md").path) else {
                throw KnowledgeError.incomplete
            }
            Self.syncAgentsFile(project)
            await markDocumented(project, model: model.label, isBuild: isBuild, fingerprint: startFingerprint, commit: startCommit)
            setStatus(project) { $0.phase = .idle; $0.activity = nil; $0.outdated = false }
            pendingChange[project] = nil
        } catch {
            fail(project, error)
        }
    }

    private struct AgentFailure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private func fail(_ project: String, _ error: Error) {
        setStatus(project) { $0.phase = .failed(error.localizedDescription); $0.activity = nil }
    }

    private func markDocumented(_ project: String, model: String?, isBuild: Bool, fingerprint: String? = nil, commit: String? = nil) async {
        let previous = Self.loadStand(project)
        let fingerprint = if let fingerprint { fingerprint } else { await Self.fingerprint(project) }
        let commit = if let commit { commit } else { await Self.git(project, ["rev-parse", "HEAD"]) }
        let stand = Stand(
            commit: commit?.trimmingCharacters(in: .whitespacesAndNewlines),
            fingerprint: fingerprint,
            builtAt: isBuild ? .now : (previous?.builtAt ?? .now),
            updatedAt: .now,
            updates: isBuild ? 0 : (previous?.updates ?? 0) + 1,
            model: model
        )
        Self.saveStand(stand, project)
        setStatus(project) { $0.stand = stand }
    }

    // MARK: Freigaben

    func owns(_ sessionID: String) -> Bool { ownedSessions[sessionID] != nil }

    /// Der Chronist darf nur im Wissensordner schreiben – alles andere wird abgelehnt.
    func handlePermission(_ request: PermissionRequest, directory: String) async {
        guard let client = store?.client else { return }
        let allowed = ["edit", "write", "read", "glob", "grep", "list"].contains(request.permission)
            && request.patterns.allSatisfy { Self.isInsideKnowledge($0, project: directory) || ["read", "glob", "grep", "list"].contains(request.permission) }
        try? await client.replyPermission(requestID: request.id, directory: directory, reply: allowed ? .once : .reject)
    }

    nonisolated static func isInsideKnowledge(_ path: String, project: String) -> Bool {
        var relative = path
        let root = project.hasSuffix("/") ? project : project + "/"
        if relative.hasPrefix(root) { relative = String(relative.dropFirst(root.count)) }
        if relative.hasPrefix("./") { relative = String(relative.dropFirst(2)) }
        return relative.hasPrefix(folder + "/") && !relative.contains("..")
    }

    // MARK: Quellen

    private static let excludes = ["--", ".", ":(exclude).appforge", ":(exclude)AGENTS.md", ":(exclude)CLAUDE.md"]

    /// Was sich seit dem Stand geändert hat. `nil`, wenn sich außer dem Wissen selbst nichts geändert hat.
    private func changeReport(_ project: String, since stand: Stand) async -> String? {
        if let commit = stand.commit, await Self.git(project, ["cat-file", "-e", commit + "^{commit}"]) != nil {
            let log = await Self.git(project, ["log", "--date=short", "--format=- %h %ad %s%n%b", "\(commit)..HEAD"] + Self.excludes) ?? ""
            let stat = await Self.git(project, ["diff", "--stat", commit] + Self.excludes) ?? ""
            let untracked = await Self.git(project, ["ls-files", "--others", "--exclude-standard"] + Self.excludes) ?? ""
            let clean = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if clean(log).isEmpty, clean(stat).isEmpty, clean(untracked).isEmpty { return nil }
            let diff = await Self.git(project, ["diff", "--unified=2", commit] + Self.excludes) ?? ""
            var report = ""
            if !clean(log).isEmpty { report += "## Commits\n\(Self.limit(log, 8_000))\n\n" }
            if !clean(stat).isEmpty { report += "## Geänderte Dateien\n\(Self.limit(stat, 6_000))\n\n" }
            if !clean(untracked).isEmpty { report += "## Neue Dateien (noch nicht im Git)\n\(Self.limit(untracked, 3_000))\n\n" }
            if !clean(diff).isEmpty {
                report += "## Diff (gekürzt – lies bei Bedarf die Dateien selbst)\n```diff\n\(Self.limit(diff, 40_000))\n```\n"
            }
            return report
        }
        if await Self.git(project, ["rev-parse", "HEAD"]) != nil {
            let log = await Self.git(project, ["log", "-30", "--date=short", "--format=- %h %ad %s"]) ?? ""
            return "Der letzte dokumentierte Stand ist im Git nicht mehr vorhanden. Prüfe das Wissen gegen den aktuellen Code.\n\n## Letzte Commits\n\(log)"
        }
        let files = Self.changedFiles(project, since: stand.updatedAt)
        guard !files.isEmpty else { return nil }
        return "## Geänderte Dateien (seit \(stand.updatedAt.formatted()))\n" + files.prefix(200).map { "- \($0)" }.joined(separator: "\n")
    }

    /// Chats und Aufträge in diesem Projekt – daraus ergibt sich, *warum* etwas gebaut wurde.
    private func history(_ project: String, since: Date?) async -> String {
        guard let store, let client = store.client else { return "- keine" }
        var sections: [String] = []

        if since == nil, let log = await Self.git(project, ["log", "-200", "--date=short", "--format=- %ad %s"]), !log.isEmpty {
            sections.append("## Commit-Verlauf (neueste zuerst)\n\(Self.limit(log, 12_000))")
        }

        let threshold = (since?.timeIntervalSince1970 ?? 0) * 1000
        let sessions = ((try? await client.sessions(directory: project)) ?? [])
            .filter { $0.parentID == nil && $0.time.updated > threshold && !Self.isAgentSession($0) && !IdeaStore.isAgentSession($0) }
            .sorted { $0.time.updated > $1.time.updated }
            .prefix(since == nil ? 40 : 15)
        var chats: [String] = []
        for session in sessions {
            guard let envelopes = try? await client.messages(sessionID: session.id, directory: project) else { continue }
            let wishes = envelopes
                .filter { $0.info.isUser && $0.info.time.created > threshold }
                .map { $0.parts.filter { $0.type == "text" && $0.synthetic != true }.compactMap(\.text).joined(separator: " ") }
                .filter { !$0.isEmpty }
                .map { "  - " + Self.limit($0.replacingOccurrences(of: "\n", with: " "), 700) }
            guard !wishes.isEmpty else { continue }
            let answer = envelopes.last { !$0.info.isUser }
                .map { $0.parts.filter { $0.type == "text" }.compactMap(\.text).joined(separator: " ") } ?? ""
            let date = Date(timeIntervalSince1970: session.time.updated / 1000).formatted(date: .numeric, time: .omitted)
            var entry = "- **\(session.title)** (\(date))\n" + wishes.prefix(12).joined(separator: "\n")
            if !answer.isEmpty { entry += "\n  - Ergebnis: " + Self.limit(answer.replacingOccurrences(of: "\n", with: " "), 500) }
            chats.append(entry)
        }
        if !chats.isEmpty { sections.append("## Chats (Wünsche des Nutzers und Ergebnis)\n" + Self.limit(chats.joined(separator: "\n"), since == nil ? 30_000 : 15_000)) }

        let missions = store.dispatcher.missions
            .filter { $0.directory == project && (since == nil || $0.startedAt > since!) }
            .prefix(20)
            .map { "- **\($0.title)** (\($0.state.title)): \(Self.limit($0.prompt.replacingOccurrences(of: "\n", with: " "), 800))" + ($0.activity.map { "\n  - Ergebnis: \(Self.limit($0, 300))" } ?? "") }
        if !missions.isEmpty { sections.append("## Aufträge der Zentrale\n" + missions.joined(separator: "\n")) }

        let done = store.ideas.ideas(for: project).filter { $0.status == .done }.prefix(20)
            .map { "- \($0.displayTitle)" + ($0.summary.map { ": \($0)" } ?? "") }
        if !done.isEmpty { sections.append("## Umgesetzte Ideen\n" + done.joined(separator: "\n")) }

        return sections.isEmpty ? "- keine weiteren Quellen" : sections.joined(separator: "\n\n")
    }

    // MARK: Hilfen

    nonisolated static func folderURL(_ project: String) -> URL {
        URL(filePath: project).appending(path: folder, directoryHint: .isDirectory)
    }

    nonisolated static func loadStand(_ project: String) -> Stand? {
        guard let data = try? Data(contentsOf: folderURL(project).appending(path: "stand.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Stand.self, from: data)
    }

    nonisolated static func saveStand(_ stand: Stand, _ project: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: folderURL(project), withIntermediateDirectories: true)
        try? encoder.encode(stand).write(to: folderURL(project).appending(path: "stand.json"), options: .atomic)
    }

    /// Fingerabdruck des Projekts ohne das Wissen selbst: Git-Stand plus ungespeicherte Änderungen,
    /// ohne Git die neueste Änderungszeit aller Quelldateien.
    nonisolated static func fingerprint(_ project: String) async -> String {
        if let head = await git(project, ["rev-parse", "HEAD"]) {
            let dirty = await git(project, ["status", "--porcelain"] + excludes) ?? ""
            let hash = SHA256.hash(data: Data(dirty.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
            return head.trimmingCharacters(in: .whitespacesAndNewlines) + ":" + hash
        }
        let (count, newest) = scan(project)
        return "dateien:\(count):\(Int(newest.timeIntervalSince1970))"
    }

    nonisolated static func git(_ project: String, _ arguments: [String]) async -> String? {
        guard let result = await Shell.run(["git", "-C", project] + arguments), result.status == 0 else { return nil }
        return String(decoding: result.output, as: UTF8.self)
    }

    private nonisolated static let skipped: Set<String> = ["build", "DerivedData", ".build", "Pods", "node_modules", ".git", "Carthage", ".appforge", ".swiftpm"]

    private nonisolated static func scan(_ project: String) -> (Int, Date) {
        var count = 0
        var newest = Date.distantPast
        guard let walker = FileManager.default.enumerator(at: URL(filePath: project), includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { return (0, newest) }
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            count += 1
            if date > newest { newest = date }
        }
        return (count, newest)
    }

    private nonisolated static func changedFiles(_ project: String, since: Date) -> [String] {
        var files: [String] = []
        let root = URL(filePath: project)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let date = values.contentModificationDate, date > since else { continue }
            files.append(url.path(percentEncoded: false).replacingOccurrences(of: root.path(percentEncoded: false), with: ""))
        }
        return files
    }

    nonisolated static func limit(_ text: String, _ count: Int) -> String {
        text.count <= count ? text : String(text.prefix(count)) + "\n… (gekürzt)"
    }

    /// Bindet die Kurzfassung in `AGENTS.md` ein (eigener Block – der Rest der Datei bleibt unangetastet)
    /// und sorgt dafür, dass auch Claude Code sie über `CLAUDE.md` liest.
    nonisolated static func syncAgentsFile(_ project: String) {
        let root = URL(filePath: project)
        guard let summary = try? String(contentsOf: folderURL(project).appending(path: "kurzfassung.md"), encoding: .utf8) else { return }
        let start = "<!-- appforge:wissen:start – wird von AppForge automatisch aktualisiert -->"
        let end = "<!-- appforge:wissen:end -->"
        let block = "\(start)\n\(summary.trimmingCharacters(in: .whitespacesAndNewlines))\n\(end)"

        let agentsURL = root.appending(path: "AGENTS.md")
        var agents = (try? String(contentsOf: agentsURL, encoding: .utf8)) ?? ""
        if let lower = agents.range(of: "<!-- appforge:wissen:start"), let upper = agents.range(of: end, range: lower.upperBound..<agents.endIndex) {
            agents.replaceSubrange(lower.lowerBound..<upper.upperBound, with: block)
        } else {
            agents = agents.isEmpty ? block + "\n" : agents.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n"
        }
        try? agents.write(to: agentsURL, atomically: true, encoding: .utf8)

        let claudeURL = root.appending(path: "CLAUDE.md")
        let claude = (try? String(contentsOf: claudeURL, encoding: .utf8)) ?? ""
        if !claude.contains("@AGENTS.md") {
            let text = claude.isEmpty ? "@AGENTS.md\n" : claude.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n@AGENTS.md\n"
            try? text.write(to: claudeURL, atomically: true, encoding: .utf8)
        }
    }

    private func setStatus(_ project: String, _ change: (inout Status) -> Void) {
        var status = statuses[project] ?? Status(stand: Self.loadStand(project))
        change(&status)
        statuses[project] = status
    }

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
