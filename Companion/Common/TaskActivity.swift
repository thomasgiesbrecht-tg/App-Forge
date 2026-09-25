import ActivityKit
import Foundation

/// Live-Aktivität für eine Aufgabe vom iPhone (Chat oder Auftrag der Zentrale).
/// Der Mac aktualisiert sie per Push; der Inhalt ist `LiveTaskState` aus dem gemeinsamen Protokoll.
struct TaskActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveTaskState

    var projectID: String
    var projectName: String
    var isMac: Bool
    /// Schlüssel des Ziels (Chat oder Auftragsgruppe) – um doppelte Aktivitäten zu vermeiden.
    var targetKey: String
    /// Link, der beim Antippen geöffnet wird.
    var link: URL
}
