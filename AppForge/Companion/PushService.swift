import CryptoKit
import Foundation

/// Schickt Benachrichtigungen und Live-Aktivitäts-Updates direkt vom Mac an Apple (APNs) – ohne eigenen Server.
/// Braucht einmalig einen Push-Schlüssel (.p8) aus dem Apple-Developer-Account.
@MainActor
final class PushService {
    struct Credentials: Codable, Equatable {
        var keyID: String
        var teamID: String
        var privateKeyPEM: String
    }

    enum PushError: LocalizedError {
        case notConfigured
        case invalidKey
        case apns(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Kein Push-Schlüssel hinterlegt."
            case .invalidKey: "Der Push-Schlüssel (.p8) konnte nicht gelesen werden."
            case .apns(let code, let reason): "Apple-Push antwortete mit \(code): \(reason)"
            }
        }
    }

    private static var keyFile: URL { EngineConfig.supportDirectory.appending(path: "apns-key.json") }

    private(set) var credentials: Credentials?
    private var cachedToken: (value: String, created: Date)?
    private(set) var lastError: String?

    init() {
        if let data = try? Data(contentsOf: Self.keyFile) {
            credentials = try? JSONDecoder().decode(Credentials.self, from: data)
        }
    }

    var isConfigured: Bool { credentials != nil }

    /// Übernimmt eine `AuthKey_XXXXXXXXXX.p8`-Datei. Die Key-ID steckt im Dateinamen.
    func importKey(from url: URL, teamID: String) throws {
        let pem = try String(contentsOf: url, encoding: .utf8)
        guard (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil else { throw PushError.invalidKey }
        let name = url.deletingPathExtension().lastPathComponent
        let keyID = name.hasPrefix("AuthKey_") ? String(name.dropFirst("AuthKey_".count)) : name
        let credentials = Credentials(keyID: keyID, teamID: teamID, privateKeyPEM: pem)
        try FileManager.default.createDirectory(at: EngineConfig.supportDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(credentials).write(to: Self.keyFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.keyFile.path)
        self.credentials = credentials
        cachedToken = nil
    }

    func updateKeyID(_ keyID: String, teamID: String) {
        guard var credentials else { return }
        credentials.keyID = keyID
        credentials.teamID = teamID
        try? JSONEncoder().encode(credentials).write(to: Self.keyFile, options: .atomic)
        self.credentials = credentials
        cachedToken = nil
    }

    func removeKey() {
        try? FileManager.default.removeItem(at: Self.keyFile)
        credentials = nil
        cachedToken = nil
    }

    // MARK: Senden

    struct Alert {
        var title: String
        var body: String
        var category: String?
        var threadID: String?
        var userInfo: [String: String] = [:]
    }

    /// Normale Benachrichtigung.
    func send(_ alert: Alert, to device: String, environment: String, topic: String) async throws {
        var aps: [String: Any] = [
            "alert": ["title": alert.title, "body": alert.body],
            "sound": "default",
            "interruption-level": "time-sensitive",
        ]
        if let category = alert.category { aps["category"] = category }
        if let threadID = alert.threadID { aps["thread-id"] = threadID }
        var payload: [String: Any] = ["aps": aps]
        for (key, value) in alert.userInfo { payload[key] = value }
        try await post(payload, token: device, environment: environment, topic: topic, pushType: "alert", priority: 10)
    }

    /// Update oder Ende einer Live-Aktivität.
    func sendLiveActivity(
        state: LiveTaskState, end: Bool, alert: Alert?, token: String, environment: String, topic: String
    ) async throws {
        let stateData = try JSONEncoder().encode(state)
        let contentState = try JSONSerialization.jsonObject(with: stateData)
        let now = Date.now.timeIntervalSince1970
        var aps: [String: Any] = [
            "timestamp": Int(now),
            "event": end ? "end" : "update",
            "content-state": contentState,
            "stale-date": Int(now + 60 * 30),
        ]
        if end { aps["dismissal-date"] = Int(now + 60 * 60) }
        if let alert { aps["alert"] = ["title": alert.title, "body": alert.body] }
        let priority = (end || alert != nil || state.kind != .running) ? 10 : 5
        try await post(["aps": aps], token: token, environment: environment,
                       topic: topic + ".push-type.liveactivity", pushType: "liveactivity", priority: priority)
    }

    private func post(_ payload: [String: Any], token: String, environment: String, topic: String, pushType: String, priority: Int) async throws {
        do {
            try await postOnce(payload, token: token, environment: environment, topic: topic, pushType: pushType, priority: priority)
        } catch PushError.apns(400, let reason) where reason.contains("BadDeviceToken") {
            // Umgebung (Entwicklung/Produktion) passt nicht zum Build – die andere versuchen.
            let other = environment == "production" ? "development" : "production"
            try await postOnce(payload, token: token, environment: other, topic: topic, pushType: pushType, priority: priority)
        }
    }

    private func postOnce(_ payload: [String: Any], token: String, environment: String, topic: String, pushType: String, priority: Int) async throws {
        let host = environment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        var request = URLRequest(url: URL(string: "https://\(host)/3/device/\(token)")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("bearer \(try authToken())", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue(pushType, forHTTPHeaderField: "apns-push-type")
        request.setValue(String(priority), forHTTPHeaderField: "apns-priority")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let reason = String(decoding: data, as: UTF8.self)
            lastError = "\(status): \(reason)"
            if status == 403 { cachedToken = nil }
            throw PushError.apns(status, reason)
        }
        lastError = nil
    }

    /// JWT für APNs (ES256), wird ca. alle 40 Minuten erneuert.
    private func authToken() throws -> String {
        guard let credentials else { throw PushError.notConfigured }
        if let cachedToken, Date.now.timeIntervalSince(cachedToken.created) < 40 * 60 { return cachedToken.value }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM) else { throw PushError.invalidKey }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": credentials.keyID])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": credentials.teamID, "iat": Int(Date.now.timeIntervalSince1970)])
        let signingInput = header.base64URLEncoded + "." + claims.base64URLEncoded
        let signature = try key.signature(for: Data(signingInput.utf8))
        let token = signingInput + "." + signature.rawRepresentation.base64URLEncoded
        cachedToken = (token, .now)
        return token
    }
}
