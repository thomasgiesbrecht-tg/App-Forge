import AppIntents
import Foundation

/// „Hey Siri, neue Idee in AppForge“ – fragt nach App und Idee und speichert sie, ohne die App zu öffnen.
struct AddIdeaIntent: AppIntent {
    static let title: LocalizedStringResource = "Idee notieren"
    static let description = IntentDescription("Notiert eine Idee für eine App. Der Ideen-Agent auf dem Mac ordnet sie ein.")

    @Parameter(title: "App", requestValueDialog: "Für welche App?")
    var app: ProjectEntity

    @Parameter(title: "Idee", requestValueDialog: "Was ist deine Idee?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Idee für \(\.$app) notieren: \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SharedStore.addPendingIdea(Idea(projectID: app.id, text: text, source: .siri))
        NotificationCenter.default.post(name: .pendingIdeasChanged, object: nil)
        return .result(dialog: "Notiert für \(app.name).")
    }
}

struct CompanionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddIdeaIntent(),
            phrases: [
                "Neue Idee in \(.applicationName)",
                "Idee für \(\.$app) in \(.applicationName)",
                "\(.applicationName) Idee notieren",
            ],
            shortTitle: "Idee notieren",
            systemImageName: "lightbulb"
        )
    }
}
