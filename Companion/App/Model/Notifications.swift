import Foundation
import UIKit
import UserNotifications

/// Push-Registrierung und Benachrichtigungs-Aktionen („Freigeben“, „Ablehnen“ direkt aus der Mitteilung).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Wird von der App gesetzt, sobald das Modell existiert.
    @MainActor static weak var model: CompanionModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Die Uhr kann die App im Hintergrund wecken – das Modell muss dann ohne Fenster bereitstehen.
        Self.model = CompanionModel.shared
        WatchBridge.shared.activate()
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Freigeben", options: [.authenticationRequired])
        let always = UNNotificationAction(identifier: "ALWAYS", title: "Immer erlauben", options: [.authenticationRequired])
        let reject = UNNotificationAction(identifier: "REJECT", title: "Ablehnen", options: [.authenticationRequired, .destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "PERMISSION", actions: [approve, always, reject], intentIdentifiers: []),
            UNNotificationCategory(identifier: "DONE", actions: [], intentIdentifiers: []),
        ])
        Task {
            if (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true {
                await MainActor.run { application.registerForRemoteNotifications() }
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in Self.model?.pushToken = token }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let permissionID = info["permissionID"] as? String
        let directory = info["directory"] as? String
        let projectID = info["projectID"] as? String
        let sessionID = info["sessionID"] as? String
        let action = response.actionIdentifier

        // Beim Kaltstart aus einer Mitteilung kurz warten, bis die App ihr Modell angelegt hat.
        for _ in 0..<20 {
            if await MainActor.run(body: { Self.model != nil }) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        await MainActor.run {
            guard let model = Self.model else { return }
            switch action {
            case "APPROVE", "ALWAYS", "REJECT":
                guard let permissionID, let directory else { return }
                let answer: PermissionAnswer = action == "APPROVE" ? .once : action == "ALWAYS" ? .always : .reject
                Task {
                    let ok = await model.replyFromNotification(permissionID: permissionID, directory: directory, answer: answer)
                    if !ok { await Self.remind("Freigabe konnte nicht gesendet werden – der Mac ist nicht erreichbar.") }
                }
            default:
                if let projectID, let sessionID {
                    model.handle(DeepLink.chat(projectID, sessionID: sessionID))
                } else if permissionID != nil {
                    model.selectedTab = .missions
                }
            }
        }
    }

    private static func remind(_ text: String) async {
        let content = UNMutableNotificationContent()
        content.title = "AppForge"
        content.body = text
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
