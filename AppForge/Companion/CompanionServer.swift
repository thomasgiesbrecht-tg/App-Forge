import Foundation
import Network

/// Lauscht auf Verbindungen vom iPhone: im WLAN per Bonjour, unterwegs über den festen Port (z. B. via Tailscale).
final class CompanionServer: @unchecked Sendable {
    enum State: Sendable, Equatable {
        case stopped, starting, listening(UInt16), failed(String)
    }

    private let queue = DispatchQueue(label: "AppForge.CompanionServer")
    private var listener: NWListener?

    func start(
        secret: Data, port: UInt16, name: String,
        onState: @escaping @Sendable (State) -> Void,
        onConnection: @escaping @Sendable (CompanionChannel) -> Void
    ) {
        stop()
        onState(.starting)
        do {
            let listener = try NWListener(using: CompanionTransport.parameters(secret: secret), on: NWEndpoint.Port(rawValue: port) ?? .any)
            listener.service = NWListener.Service(name: name, type: CompanionProtocol.bonjourType)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: onState(.listening(listener.port?.rawValue ?? port))
                case .failed(let error): onState(.failed(error.localizedDescription))
                case .waiting(let error): onState(.failed(error.localizedDescription))
                case .cancelled: onState(.stopped)
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                onConnection(CompanionChannel(connection: connection))
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onState(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
