import Foundation
import WatchConnectivity

/// Verbindung zur Apple Watch. Die Uhr darf keine eigene Verbindung zum Mac aufbauen –
/// deshalb schickt das iPhone ihr den Stand und gibt ihre Aktionen (Freigaben, Ideen) an den Mac weiter.
/// Die Uhr kann die iPhone-App dafür im Hintergrund wecken.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private var lastSent: WatchState?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Aktuellen Stand an die Uhr schicken (nur wenn sich etwas geändert hat).
    func publish(from model: CompanionModel) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        var state = Self.state(from: model)
        if var previous = lastSent {
            previous.updatedAt = state.updatedAt
            if previous == state { return }
        }
        lastSent = state
        state.updatedAt = .now
        guard let data = WatchCoding.encode(state) else { return }
        try? WCSession.default.updateApplicationContext([WatchCoding.stateKey: data])
        if WCSession.default.isReachable {
            WCSession.default.sendMessage([WatchCoding.stateKey: data], replyHandler: nil)
        }
    }

    static func state(from model: CompanionModel) -> WatchState {
        let snapshot = model.snapshot
        let missions = (snapshot?.missions ?? []).prefix(12).map { mission in
            WatchState.Mission(
                id: mission.id, title: mission.title, projectName: mission.projectName,
                stateTitle: mission.stateTitle, isFinished: mission.isFinished, activity: mission.activity,
                progress: mission.progress, spentUSD: mission.spentUSD, buildOK: mission.buildOK
            )
        }
        let permissions = model.permissions.map { permission in
            WatchState.Permission(
                id: permission.id, directory: permission.directory, title: permission.title, kind: permission.permission,
                detail: (permission.detail ?? permission.patterns.first).map { String($0.prefix(160)) }
            )
        }
        return WatchState(
            macName: model.macName, connected: model.isConnected, updatedAt: .now,
            eurPerUsd: snapshot?.eurPerUsd ?? SharedStore.eurPerUsd,
            spentTodayUSD: snapshot?.spentToday ?? 0,
            missions: Array(missions), permissions: permissions,
            projects: model.projects.map { WatchState.Project(id: $0.id, name: $0.name) }
        )
    }

    /// Aktion von der Uhr ausführen – notfalls erst die Verbindung zum Mac aufbauen.
    private func perform(_ action: WatchAction) async -> Bool {
        let model = CompanionModel.shared
        switch action {
        case .refresh:
            if !model.isConnected {
                model.connect()
                for _ in 0..<32 where !model.isConnected { try? await Task.sleep(for: .milliseconds(250)) }
                try? await Task.sleep(for: .milliseconds(600))   // erster Stand vom Mac
            }
            lastSent = nil
            publish(from: model)
            return model.isConnected
        case .reply(let id, let directory, let answer):
            let ok = await model.replyFromNotification(permissionID: id, directory: directory,
                                                       answer: PermissionAnswer(rawValue: answer) ?? .reject)
            lastSent = nil
            publish(from: model)
            return ok
        case .idea(let projectID, let text):
            // Landet im Postausgang und wird gesendet, sobald der Mac erreichbar ist.
            model.addIdea(text, projectID: projectID, source: .iphone)
            if !model.isConnected { model.connect() }
            await model.flush()
            return true
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publish(from: CompanionModel.shared) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastSent = nil
            self.publish(from: CompanionModel.shared)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let data = message[WatchCoding.actionKey] as? Data
        let reply = UncheckedSendable(replyHandler)
        Task { @MainActor in
            guard let action = WatchCoding.decode(WatchAction.self, from: data) else { reply.value(["ok": false]); return }
            let ok = await self.perform(action)
            reply.value(["ok": ok])
        }
    }

    /// Ideen kommen zusätzlich als „userInfo“ – das kommt auch an, wenn das iPhone gerade nicht erreichbar war.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let data = userInfo[WatchCoding.actionKey] as? Data
        Task { @MainActor in
            guard let action = WatchCoding.decode(WatchAction.self, from: data) else { return }
            _ = await self.perform(action)
        }
    }
}

/// Antwort-Blöcke von WatchConnectivity sind nicht als Sendable markiert.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
