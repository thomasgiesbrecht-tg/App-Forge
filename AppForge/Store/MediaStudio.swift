import AppKit
import Foundation
import Observation

enum MediaKind: String, Codable, Sendable {
    case image, video

    var command: String { self == .image ? "/foto" : "/video" }
    var symbol: String { self == .image ? "photo" : "film" }
    var title: String { self == .image ? "Foto" : "Video" }
}

/// `/foto` und `/video`: Bild- und Videoerzeugung mit Qwen-Image bzw. Wan (Alibaba Model Studio).
/// Ergebnisse landen als Datei im Medienordner und als Nachricht im Chat.
@MainActor
@Observable
final class MediaStudio {
    struct Job: Identifiable, Sendable {
        let id = UUID()
        let kind: MediaKind
        let prompt: String
        let sessionID: String
        let started = Date()
        var status: String
        var error: String?
    }

    @ObservationIgnored weak var store: AppStore?
    private(set) var jobs: [Job] = []

    static var directory: URL { EngineConfig.supportDirectory.appending(path: "Medien", directoryHint: .isDirectory) }

    /// Marker, über den die App erzeugte Dateien in Chat-Nachrichten wiederfindet.
    static let fileMarker = "AppForge-Datei:"

    func jobs(for sessionID: String?) -> [Job] { jobs.filter { $0.sessionID == sessionID } }

    func dismiss(_ job: Job) { jobs.removeAll { $0.id == job.id } }

    /// Parst `/foto …` bzw. `/video …`. Gibt `nil` zurück, wenn es kein Medienbefehl ist.
    static func parse(_ text: String) -> (MediaKind, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for kind in [MediaKind.image, .video] where trimmed.lowercased().hasPrefix(kind.command) {
            let rest = trimmed.dropFirst(kind.command.count)
            guard rest.isEmpty || rest.first?.isWhitespace == true else { continue }
            return (kind, rest.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func run(_ kind: MediaKind, prompt: String, inputImage: Attachment?) async {
        guard let store, let client = store.client, let directory = store.selectedProject else { return }
        if store.selectedSessionID == nil { await store.newSession() }
        guard let sessionID = store.selectedSessionID else { return }

        let job = Job(kind: kind, prompt: prompt, sessionID: sessionID,
                      status: kind == .image ? (inputImage == nil ? "Bild wird erzeugt" : "Bild wird bearbeitet")
                                             : (inputImage == nil ? "Video wird erzeugt" : "Bild wird animiert"))
        jobs.append(job)
        let jobID = job.id

        do {
            let settings = MediaSettings.current
            let api = try DashScopeClient(settings: settings)
            let remote: URL
            switch kind {
            case .image:
                remote = try await api.image(prompt: prompt, input: inputImage?.url)
            case .video:
                remote = try await api.video(prompt: prompt, input: inputImage?.url) { [weak self] status in
                    Task { @MainActor in self?.update(jobID) { $0.status = status } }
                }
            }
            update(jobID) { $0.status = "wird gespeichert" }
            let file = try await download(remote, kind: kind, prompt: prompt)

            // Als Nachricht in den Chat – ohne dass eine KI antwortet.
            var attachments: [Attachment] = []
            if kind == .image, let data = try? Data(contentsOf: file),
               let attachment = AttachmentFactory.image(data: data, filename: file.lastPathComponent) {
                attachments = [attachment]
            }
            let text = "\(kind.command) \(prompt)\n\n\(Self.fileMarker) \(file.absoluteString)"
            try await client.prompt(sessionID: sessionID, directory: directory, text: text,
                                    attachments: attachments, model: nil, agent: nil, system: nil, noReply: true)
            jobs.removeAll { $0.id == jobID }
        } catch {
            update(jobID) { $0.error = error.localizedDescription }
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    /// Ergebnis-URLs sind nur begrenzt gültig – deshalb sofort lokal speichern.
    private func download(_ url: URL, kind: MediaKind, prompt: String) async throws -> URL {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let (temp, _) = try await URLSession.shared.download(from: url)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let slug = AgentDefinition.slug(String(prompt.prefix(40)))
        let ext = url.pathExtension.isEmpty ? (kind == .image ? "png" : "mp4") : url.pathExtension
        let target = Self.directory.appending(path: "\(stamp) \(slug.isEmpty ? kind.title : slug).\(ext)")
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    /// Findet die Datei-URL in einer Nachricht, die per `/foto` oder `/video` entstanden ist.
    static func fileURL(in text: String) -> URL? {
        guard let range = text.range(of: fileMarker) else { return nil }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: String(rest.split(separator: "\n").first ?? ""))
    }
}
