import AppIntents
import SwiftUI
import WidgetKit

/// Knopf fürs Kontrollzentrum, den Sperrbildschirm oder die Aktionstaste: öffnet die Ideen-Erfassung
/// für eine gewählte App und hört sofort zu.
struct IdeaControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "IdeaControl", intent: SelectAppControlIntent.self) { configuration in
            ControlWidgetButton(action: OpenCaptureIntent(projectID: configuration.app?.id ?? "", speak: true)) {
                Label(configuration.app?.name ?? "Idee", systemImage: "lightbulb.fill")
            }
        }
        .displayName("Idee notieren")
        .description("Idee für eine App einsprechen.")
        .promptsForUserConfiguration()
    }
}
