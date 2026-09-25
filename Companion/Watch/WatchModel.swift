import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit

/// Stand und Aktionen auf der Uhr. Alles läuft über das iPhone – die Uhr selbst spricht nie direkt mit dem Mac.
@MainActor
@Observable
final class WatchModel: NSObject {
    private(set) var state = WatchStore.load()
    private(set) var busy = false
    var message: String?

    var iPhoneReachable: Bool { WCSession.isSupported() && WCSession.default.isReachable }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Frischen Stand anfordern – weckt bei Bedarf die iPhone-App, die dann den Mac fragt.
    func refresh() {
        send(.refresh, fallback: false, silent: true)
    }

    func reply(_ permission: WatchState.Permission, allow: Bool) {
        WKInterfaceDevice.current().play(allow ? .success : .click)
        // Sofort aus der Liste nehmen; der nächste Stand vom iPhone bestätigt es.
        var updated = state
        updated.permissions.removeAll { $0.id == permission.id }
        apply(updated, haptic: false)
        send(.reply(permissionID: permission.id, directory: permission.directory, answer: allow ? "once" : "reject"), fallback: false)
    }

    func addIdea(_ text: String, projectID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        WKInterfaceDevice.current().play(.success)
        // Ideen gehen nie verloren: Ist das iPhone nicht erreichbar, stellt watchOS sie später zu.
        send(.idea(projectID: projectID, text: trimmed), fallback: true)
    }

    private func send(_ action: WatchAction, fallback: Bool, silent: Bool = false) {
        guard WCSession.isSupported(), let data = WatchCoding.encode(action) else { return }
        let session = WCSession.default
        if session.isReachable {
            busy = true
            session.sendMessage([WatchCoding.actionKey: data], replyHandler: { reply in
                let ok = reply["ok"] as? Bool ?? false
                Task { @MainActor in
                    self.busy = false
                    if !ok, case .reply = action { self.message = "Der Mac war nicht erreichbar." }
                }
            }, errorHandler: { _ in
                Task { @MainActor in
                    self.busy = false
                    if fallback { WCSession.default.transferUserInfo([WatchCoding.actionKey: data]) }
                    else if !silent { self.message = "iPhone nicht erreichbar." }
                }
            })
        } else if fallback {
            session.transferUserInfo([WatchCoding.actionKey: data])
            message = "Wird gesendet, sobald das iPhone erreichbar ist."
        } else if !silent {
            message = "iPhone nicht erreichbar."
        }
    }

    fileprivate func apply(_ new: WatchState, haptic: Bool = true) {
        // Neue Freigabe → kurz am Handgelenk tippen
        if haptic, new.permissions.contains(where: { p in !state.permissions.contains { $0.id == p.id } }) {
            WKInterfaceDevice.current().play(.notification)
        }
        state = new
        WatchStore.save(new)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext[WatchCoding.stateKey] as? Data
        Task { @MainActor in
            if let state = WatchCoding.decode(WatchState.self, from: context), state.updatedAt > self.state.updatedAt { self.apply(state, haptic: false) }
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[WatchCoding.stateKey] as? Data
        Task { @MainActor in
            if let state = WatchCoding.decode(WatchState.self, from: data) { self.apply(state) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let data = message[WatchCoding.stateKey] as? Data
        Task { @MainActor in
            if let state = WatchCoding.decode(WatchState.self, from: data) { self.apply(state) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in if reachable { self.refresh() } }
    }
}
