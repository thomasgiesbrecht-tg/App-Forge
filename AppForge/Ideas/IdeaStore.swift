import CryptoKit
import Foundation
import Observation

/// Ideen je App. Sie werden nicht umgesetzt, sondern nur gesammelt, damit nichts verloren geht.
/// Der Ideen-Agent kennt den Code der App und ordnet jede neue Idee ein (Titel, Kategorie,
/// Aufwand, betroffene Dateien, Dubletten) – ohne etwas zu ändern.
@MainActor
@Observable
final class IdeaStore {
    @ObservationIgnored weak var store: AppStore?
    /// Wird nach jeder Änderung mit der Projekt-ID aufgerufen (z. B. um das iPhone zu informieren).
    @ObservationIgnored var onChange: ((String) -> Void)?

    private(set) var ideasByProject: [String: [Idea]] = [:]
    private(set) var askingProjects: Set<String> = []

    /// Modell des Ideen-Agenten. `nil` = das günstigste verbundene Modell mit Werkzeugen.
    var model: ModelSelection? {
        didSet {
            if let model, let data = try? JSONEncoder().encode(model) {
                UserDefaults.standard.set(data, forKey: "ideas.model")
            } else {
                UserDefaults.standard.removeObject(forKey: "ideas.model")
            }
        }
    }

    /// Titel der Hilfs-Chats des Ideen-Agenten – sie werden in der Chat-Liste ausgeblendet.
    nonisolated static let sessionTitle = "💡 Ideen-Agent"
    nonisolated static let agentName = "ideen"

    nonisolated static var directory: URL { EngineConfig.supportDirectory.appending(path: "ideen", directoryHint: .isDirectory) }

    init() {
        if let data = UserDefaults.standard.data(forKey: "ideas.model") {
            model = try? JSONDecoder().decode(ModelSelection.self, from: data)
        }
        loadAll()
    }

    // MARK: Lesen

    func ideas(for projectID: String) -> [Idea] {
        ideasByProject[projectID] ?? []
    }

    func openCount(for projectID: String) -> Int {
        ideas(for: projectID).filter { $0.status == .open }.count
    }

    var effectiveModel: ModelSelection? {
        if let model { return model }
        return ModelCatalog.entries(from: store?.providers)
            .filter { $0.model.supportsTools && $0.blendedPrice > 0 }
            .min { $0.blendedPrice < $1.blendedPrice }?
            .selection
    }

    nonisolated static func isAgentSession(_ session: Session) -> Bool {
        session.title.hasPrefix(sessionTitle)
    }

    // MARK: Ändern

    @discardableResult
    func add(text: String, projectID: String, source: Idea.Source) -> Idea? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let idea = Idea(projectID: projectID, text: trimmed, source: source)
        add([idea])
        return idea
    }

    /// Übernimmt Ideen (auch offline auf dem iPhone gesammelte). Bekannte IDs werden übersprungen.
    func add(_ incoming: [Idea]) {
        var touched: Set<String> = []
        var fresh: [Idea] = []
        for var idea in incoming {
            var list = ideasByProject[idea.projectID] ?? []
            guard !list.contains(where: { $0.id == idea.id }) else { continue }
            idea.analysis = .pending
            list.insert(idea, at: 0)
            list.sort { $0.createdAt > $1.createdAt }
            ideasByProject[idea.projectID] = list
            touched.insert(idea.projectID)
            fresh.append(idea)
        }
        touched.forEach(persist)
        touched.forEach { onChange?($0) }
        // Jede Idee wird sofort eingeordnet. Läuft die Engine gerade nicht, holt `analyzeOutstanding()` das nach.
        for idea in fresh { Task { await analyze(idea.id, projectID: idea.projectID) } }
    }

    /// Ordnet alle Ideen ein, die noch nicht (erfolgreich) eingeordnet wurden – z. B. nach dem Start der Engine.
    func analyzeOutstanding() async {
        guard store?.client != nil, effectiveModel != nil else { return }
        let waiting: Set<Idea.Analysis> = [.pending, .failed, .off]
        let all: [Idea] = ideasByProject.values.flatMap { $0 }
        let outstanding = all.filter { idea in idea.status == .open && waiting.contains(idea.analysis) }
        for idea in outstanding {
            await analyze(idea.id, projectID: idea.projectID)
        }
    }

    func setStatus(_ status: Idea.Status, id: UUID, projectID: String) {
        update(id, projectID: projectID) { $0.status = status }
    }

    func edit(text: String, id: UUID, projectID: String) {
        update(id, projectID: projectID) { $0.text = text }
    }

    func delete(id: UUID, projectID: String) {
        ideasByProject[projectID]?.removeAll { $0.id == id }
        persist(projectID)
        onChange?(projectID)
    }

    private func update(_ id: UUID, projectID: String, _ change: (inout Idea) -> Void) {
        guard let index = ideasByProject[projectID]?.firstIndex(where: { $0.id == id }) else { return }
        change(&ideasByProject[projectID]![index])
        ideasByProject[projectID]![index].updatedAt = .now
        persist(projectID)
        onChange?(projectID)
    }

    // MARK: Ideen-Agent

    enum AgentError: LocalizedError {
        case engineOffline, noModel, timeout, empty

        var errorDescription: String? {
            switch self {
            case .engineOffline: "Die Engine läuft nicht."
            case .noModel: "Kein Modell mit Werkzeugen verbunden – verbinde in den Einstellungen unter „Modelle“ einen Anbieter."
            case .timeout: "Der Ideen-Agent hat nicht rechtzeitig geantwortet."
            case .empty: "Der Ideen-Agent hat keine Antwort geliefert."
            }
        }
    }

    /// Lässt den Ideen-Agenten eine Idee einordnen. Er liest den Code, ändert aber nichts.
    func analyze(_ id: UUID, projectID: String) async {
        guard let idea = ideas(for: projectID).first(where: { $0.id == id }), idea.analysis != .running else { return }
        guard store?.client != nil else { return }  // bleibt „pending“ und wird nach dem Engine-Start eingeordnet
        update(id, projectID: projectID) { $0.analysis = .running; $0.note = nil }

        let others = ideas(for: projectID)
            .filter { $0.id != id && $0.status == .open }
            .prefix(80)
            .map { "- \($0.id.uuidString): \($0.displayTitle)" }
            .joined(separator: "\n")
        let prompt = """
        NEUE IDEE – nicht umsetzen, nur einordnen:

        \(idea.text)

        Bisherige offene Ideen dieser App (ID: Titel):
        \(others.isEmpty ? "- keine" : others)
        """

        do {
            let answer = try await runAgent(prompt: prompt, projectID: projectID)
            guard let json = Self.json(in: answer) else { throw AgentError.empty }
            update(id, projectID: projectID) { idea in
                idea.title = json["title"]?.stringValue.flatMap(Self.nonEmpty)
                idea.summary = json["summary"]?.stringValue.flatMap(Self.nonEmpty)
                idea.category = json["category"]?.stringValue.flatMap(Self.nonEmpty)
                idea.effort = json["effort"]?.stringValue.flatMap(Self.nonEmpty)
                idea.note = json["note"]?.stringValue.flatMap(Self.nonEmpty)
                if case .array(let files) = json["relatedFiles"] {
                    idea.relatedFiles = files.compactMap(\.stringValue).prefix(8).map { $0 }
                }
                idea.duplicateOf = json["duplicateOf"]?.stringValue.flatMap(UUID.init(uuidString:))
                idea.analysis = .done
            }
        } catch {
            update(id, projectID: projectID) {
                $0.analysis = .failed
                $0.note = error.localizedDescription
            }
        }
    }

    /// Beantwortet eine Frage zu den Ideen einer App (z. B. „Was habe ich zum Export notiert?“).
    func ask(_ question: String, projectID: String) async throws -> String {
        askingProjects.insert(projectID)
        defer { askingProjects.remove(projectID) }
        let list = ideas(for: projectID)
            .map { idea in
                var line = "- [\(idea.status.title)] \(idea.displayTitle)"
                if let summary = idea.summary { line += " – \(summary)" }
                if idea.summary == nil, idea.title != nil { line += " – \(idea.text.prefix(200))" }
                return line
            }
            .joined(separator: "\n")
        let prompt = """
        FRAGE zu den Ideen dieser App. Antworte als kurzer, gut lesbarer Text auf Deutsch – kein JSON. Ändere nichts.

        \(question)

        Alle gesammelten Ideen:
        \(list.isEmpty ? "- noch keine" : list)
        """
        let answer = try await runAgent(prompt: prompt, projectID: projectID)
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentError.empty }
        return trimmed
    }

    /// Startet einen kurzen Hilfs-Chat im Projektordner, wartet auf die Antwort und räumt danach auf.
    private func runAgent(prompt: String, projectID: String) async throws -> String {
        guard let client = store?.client else { throw AgentError.engineOffline }
        guard let model = effectiveModel else { throw AgentError.noModel }
        let session = try await client.createSession(directory: projectID, title: Self.sessionTitle)
        defer { Task { try? await client.deleteSession(session.id, directory: projectID) } }

        try await client.prompt(sessionID: session.id, directory: projectID, text: prompt, model: model, agent: Self.agentName, system: nil)

        let deadline = Date.now.addingTimeInterval(300)
        try await Task.sleep(for: .seconds(2))
        while Date.now < deadline {
            let busy = (try? await client.sessionStatus(directory: projectID)) ?? [:]
            if busy[session.id] == nil {
                let envelopes = try await client.messages(sessionID: session.id, directory: projectID)
                if let last = envelopes.last(where: { !$0.info.isUser }), last.info.time.completed != nil {
                    if let message = last.info.errorMessage { throw ClientMessageError(message: message) }
                    return last.parts
                        .filter { $0.type == "text" && $0.synthetic != true }
                        .compactMap(\.text)
                        .joined(separator: "\n")
                }
            }
            try await Task.sleep(for: .seconds(2))
        }
        try? await client.abort(sessionID: session.id, directory: projectID)
        throw AgentError.timeout
    }

    private struct ClientMessageError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private static func json(in text: String) -> JSONValue? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(text[start...end].utf8))
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "null" ? nil : trimmed
    }

    // MARK: Speichern

    private struct ProjectFile: Codable {
        var projectID: String
        var ideas: [Idea]
    }

    private static func file(for projectID: String) -> URL {
        let hash = SHA256.hash(data: Data(projectID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let name = URL(filePath: projectID).lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appending(path: "\(name)-\(hash).json")
    }

    private func loadAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = CompanionCoding.decoder()
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  var file = try? decoder.decode(ProjectFile.self, from: data) else { continue }
            // Nach einem Neustart hängengebliebene Analysen wieder freigeben.
            for index in file.ideas.indices where file.ideas[index].analysis == .running {
                file.ideas[index].analysis = .failed
            }
            ideasByProject[file.projectID] = file.ideas.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func persist(_ projectID: String) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let file = ProjectFile(projectID: projectID, ideas: ideas(for: projectID))
        let encoder = CompanionCoding.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: Self.file(for: projectID), options: .atomic)
    }
}
