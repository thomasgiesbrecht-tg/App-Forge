import CryptoKit
import Foundation
import Network

/// Verschlüsselte Verbindung zwischen Mac und iPhone: TLS mit vorab geteiltem Schlüssel (PSK)
/// aus dem QR-Code, darüber WebSocket-Nachrichten mit JSON.
/// Vorbild: Apples Beispiel „Building a custom peer-to-peer protocol“.
enum CompanionTransport {
    static func parameters(secret: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions

        // Schlüssel aus dem geteilten Geheimnis ableiten, damit das Geheimnis selbst nie direkt benutzt wird.
        let key = SymmetricKey(data: secret)
        let code = HMAC<SHA256>.authenticationCode(for: Data("AppForge Companion PSK v1".utf8), using: key)
        let psk = code.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("appforge".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        // PSK-Cipher-Suites gibt es nur mit TLS 1.2.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.connectionTimeout = 8

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 32 * 1024 * 1024
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }

    static func newSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Zufallszahlen nicht verfügbar")
        return Data(bytes)
    }
}

/// Eine einzelne Verbindung. Kapselt `NWConnection` samt Warteschlange, damit die App-Logik
/// nur noch mit ganzen Nachrichten (`Data`) zu tun hat.
final class CompanionChannel: @unchecked Sendable, Identifiable {
    enum State: Sendable, Equatable {
        case connecting, ready, failed(String), closed
    }

    let id = UUID()
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "AppForge.CompanionChannel")
    private var onMessage: (@Sendable (Data) -> Void)?
    private var onState: (@Sendable (State) -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    convenience init(endpoint: NWEndpoint, secret: Data) {
        self.init(connection: NWConnection(to: endpoint, using: CompanionTransport.parameters(secret: secret)))
    }

    var endpointDescription: String { "\(connection.endpoint)" }

    func start(onState: @escaping @Sendable (State) -> Void, onMessage: @escaping @Sendable (Data) -> Void) {
        self.onState = onState
        self.onMessage = onMessage
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onState(.ready)
                self.receive()
            case .waiting(let error):
                // z. B. Mac nicht erreichbar – als Fehler melden, damit der Aufrufer es anders versuchen kann.
                onState(.failed(error.localizedDescription))
                self.connection.cancel()
            case .failed(let error):
                onState(.failed(error.localizedDescription))
            case .cancelled:
                onState(.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func send<T: Encodable>(_ value: T) {
        guard let data = try? CompanionCoding.encoder().encode(value) else { return }
        send(data)
    }

    func close() {
        connection.cancel()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                self.onState?(.failed(error.localizedDescription))
                self.connection.cancel()
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                self.connection.cancel()
                return
            }
            if let data, !data.isEmpty { self.onMessage?(data) }
            self.receive()
        }
    }
}
