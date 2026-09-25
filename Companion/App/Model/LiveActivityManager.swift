import ActivityKit
import Foundation

/// Startet Live-Aktivitäten für Aufgaben vom iPhone. Aktualisiert werden sie vom Mac per Push.
@MainActor
final class LiveActivityManager {
    func start(
        target: LiveTarget, title: String, projectID: String, projectName: String, isMac: Bool,
        onToken: @escaping @Sendable (String) -> Void
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let key = Self.key(for: target)

        // Gleiches Ziel (z. B. weitere Nachricht im selben Chat): alte Aktivität beenden.
        for activity in Activity<TaskActivityAttributes>.activities where activity.attributes.targetKey == key {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }

        let link: URL = switch target {
        case .session(let projectID, let sessionID): DeepLink.chat(projectID, sessionID: sessionID)
        case .missionGroup: DeepLink.missions
        }
        let attributes = TaskActivityAttributes(projectID: projectID, projectName: projectName, isMac: isMac, targetKey: key, link: link)
        let state = LiveTaskState(
            kind: .running, title: String(title.replacingOccurrences(of: "\n", with: " ").prefix(60)),
            status: "startet", activity: "wird an den Mac übergeben", spentUSD: 0,
            startedAt: Date.now.timeIntervalSince1970, endedAt: nil, partsDone: 0, partsTotal: 1
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(60 * 30)),
                pushType: .token
            )
            Task {
                for await data in activity.pushTokenUpdates {
                    onToken(data.map { String(format: "%02x", $0) }.joined())
                }
            }
        } catch {
            // Live-Aktivitäten ausgeschaltet oder zu viele gleichzeitig – dann eben ohne.
        }
    }

    private static func key(for target: LiveTarget) -> String {
        switch target {
        case .session(_, let sessionID): "session-\(sessionID)"
        case .missionGroup(let id): "group-\(id.uuidString)"
        }
    }
}
