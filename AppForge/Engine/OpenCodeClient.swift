import Foundation

/// HTTP-Client für den lokalen `opencode serve`-Prozess.
/// Jede projektbezogene Anfrage trägt `?directory=`, damit ein Server mehrere Projekte bedienen kann.
struct OpenCodeClient: Sendable {
    let baseURL: URL
    let password: String

    enum ClientError: LocalizedError {
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): "OpenCode-Server antwortete mit \(code): \(body.prefix(300))"
            }
        }
    }

    // MARK: Server

    func health() async throws -> Bool {
        struct Health: Decodable { var healthy: Bool }
        let result: Health = try await get("/global/health")
        return result.healthy
    }

    // MARK: Sessions

    func sessions(directory: String) async throws -> [Session] {
        try await get("/session", directory: directory)
    }

    func createSession(directory: String, title: String? = nil) async throws -> Session {
        struct Body: Encodable { var title: String? }
        return try await send("POST", "/session", directory: directory, body: Body(title: title))
    }

    func deleteSession(_ id: String, directory: String) async throws {
        let _: Bool = try await send("DELETE", "/session/\(id)", directory: directory, body: Optional<String>.none)
    }

    func messages(sessionID: String, directory: String) async throws -> [MessageEnvelope] {
        try await get("/session/\(sessionID)/message", directory: directory)
    }

    /// Sendet einen Prompt, ohne auf die Antwort zu warten – der Fortschritt kommt über den Event-Stream.
    func prompt(
        sessionID: String, directory: String, text: String, attachments: [Attachment] = [],
        mentions: [String] = [], model: ModelSelection?, agent: String?, system: String?, variant: String? = nil, noReply: Bool = false
    ) async throws {
        struct PartInput: Encodable {
            var type: String
            var text: String?
            var mime: String?
            var filename: String?
            var url: String?
            var name: String?
        }
        struct Body: Encodable {
            var model: ModelSelection?
            var agent: String?
            var system: String?
            var variant: String?
            var noReply: Bool?
            var parts: [PartInput]
        }
        var parts = [PartInput(type: "text", text: text)]
        parts += attachments.map { PartInput(type: "file", mime: $0.mime, filename: $0.filename, url: $0.url) }
        parts += mentions.map { PartInput(type: "agent", name: $0) }
        let body = Body(model: model, agent: agent, system: system, variant: variant, noReply: noReply ? true : nil, parts: parts)
        try await sendNoContent("POST", "/session/\(sessionID)/prompt_async", directory: directory, body: body)
    }

    /// Setzt den Chat (inkl. Dateien) auf den Stand vor dieser Nachricht zurück.
    func revert(sessionID: String, messageID: String, directory: String) async throws -> Session {
        struct Body: Encodable { var messageID: String }
        return try await send("POST", "/session/\(sessionID)/revert", directory: directory, body: Body(messageID: messageID))
    }

    func unrevert(sessionID: String, directory: String) async throws -> Session {
        try await send("POST", "/session/\(sessionID)/unrevert", directory: directory, body: Optional<String>.none)
    }

    func children(sessionID: String, directory: String) async throws -> [Session] {
        try await get("/session/\(sessionID)/children", directory: directory)
    }

    /// Nur arbeitende Chats sind enthalten; fehlt ein Chat, ist er untätig.
    func sessionStatus(directory: String) async throws -> [String: JSONValue] {
        try await get("/session/status", directory: directory)
    }

    func agents(directory: String) async throws -> [AgentInfo] {
        try await get("/agent", directory: directory)
    }

    func abort(sessionID: String, directory: String) async throws {
        let _: Bool = try await send("POST", "/session/\(sessionID)/abort", directory: directory, body: Optional<String>.none)
    }

    // MARK: Berechtigungen

    func replyPermission(requestID: String, directory: String, reply: PermissionReply) async throws {
        struct Body: Encodable { var reply: PermissionReply }
        let _: Bool = try await send("POST", "/permission/\(requestID)/reply", directory: directory, body: Body(reply: reply))
    }

    func pendingPermissions(directory: String) async throws -> [PermissionRequest] {
        try await get("/permission", directory: directory)
    }

    // MARK: Anbieter, Skills, MCP

    func providers(directory: String) async throws -> ProviderList {
        try await get("/provider", directory: directory)
    }

    func setAPIKey(providerID: String, key: String) async throws {
        struct Body: Encodable { var type = "api"; var key: String }
        let _: Bool = try await send("PUT", "/auth/\(providerID)", directory: nil, body: Body(key: key))
    }

    func removeAPIKey(providerID: String) async throws {
        let _: Bool = try await send("DELETE", "/auth/\(providerID)", directory: nil, body: Optional<String>.none)
    }

    func skills(directory: String) async throws -> [SkillInfo] {
        try await get("/skill", directory: directory)
    }

    func mcpStatus(directory: String) async throws -> [String: MCPStatus] {
        try await get("/mcp", directory: directory)
    }

    func disposeInstance(directory: String) async throws {
        let _: Bool = try await send("POST", "/instance/dispose", directory: directory, body: Optional<String>.none)
    }

    // MARK: Events

    /// Server-Sent Events für ein Projekt. Jede `data:`-Zeile ist ein JSON-Event.
    func events(directory: String) -> AsyncThrowingStream<Data, Error> {
        let request = makeRequest("GET", "/event", directory: directory, timeout: .infinity)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try Self.check(response, body: Data())
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        continuation.yield(Data(payload.utf8))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, directory: String? = nil) async throws -> T {
        let request = makeRequest("GET", path, directory: directory)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, body: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, directory: String?, body: B?) async throws -> T {
        var request = makeRequest(method, path, directory: directory)
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, body: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendNoContent<B: Encodable>(_ method: String, _ path: String, directory: String?, body: B) async throws {
        var request = makeRequest(method, path, directory: directory)
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, body: data)
    }

    private func makeRequest(_ method: String, _ path: String, directory: String?, timeout: TimeInterval = 60) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if let directory {
            components.queryItems = [URLQueryItem(name: "directory", value: directory)]
        }
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        let credentials = Data("opencode:\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(decoding: body, as: UTF8.self))
        }
    }
}
