import AppIntents
import Foundation
import WidgetKit

/// Eine App (bzw. der Bereich „Mac“) für Widgets, Kontrollzentrum und Siri.
struct ProjectEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "App")
    static let defaultQuery = ProjectQuery()

    var id: String
    var name: String
    var isMac: Bool
    var icon: Data?

    init(_ project: CompanionProject) {
        id = project.id
        name = project.name
        isMac = project.isMac
        icon = project.iconPNG
    }

    var displayRepresentation: DisplayRepresentation {
        if let icon {
            return DisplayRepresentation(title: "\(name)", image: .init(data: icon))
        }
        return DisplayRepresentation(title: "\(name)", image: .init(systemName: isMac ? "desktopcomputer" : "app"))
    }
}

struct ProjectQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        SharedStore.projects().filter { identifiers.contains($0.id) }.map(ProjectEntity.init)
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        SharedStore.projects().filter { $0.name.localizedCaseInsensitiveContains(string) }.map(ProjectEntity.init)
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        SharedStore.projectsByRecent().map(ProjectEntity.init)
    }
}

/// Auswahl der Apps im Ideen-Widget. Ohne Auswahl zeigt es die zuletzt benutzten.
struct SelectAppsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Apps wählen"
    static let description = IntentDescription("Welche Apps das Ideen-Widget zeigt. Leer lassen für die zuletzt benutzten.")

    @Parameter(title: "Apps")
    var apps: [ProjectEntity]?

    init() {}
}

/// App für den Ideen-Knopf im Kontrollzentrum bzw. auf der Aktionstaste.
struct SelectAppControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "App für Ideen"

    @Parameter(title: "App")
    var app: ProjectEntity?

    init() {}
}

/// Öffnet die Ideen-Erfassung für eine App.
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Idee erfassen"
    static let description = IntentDescription("Öffnet die Ideen-Erfassung für eine App.")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "App-ID", default: "")
    var projectID: String

    @Parameter(title: "Sprechen", default: false)
    var speak: Bool

    init() {}

    init(projectID: String, speak: Bool) {
        self.projectID = projectID
        self.speak = speak
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedStore.requestCapture(projectID: projectID, mode: speak ? .speak : .write)
        NotificationCenter.default.post(name: .captureRequested, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let captureRequested = Notification.Name("AppForgeCaptureRequested")
    static let pendingIdeasChanged = Notification.Name("AppForgePendingIdeasChanged")
}
