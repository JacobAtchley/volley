import Foundation
import Network

typealias ConnectionID = UUID

enum TransportEvent {
    case ready(port: UInt16)
    case opened(ConnectionID)
    case text(ConnectionID, Data)
    case closed(ConnectionID)
    case failed(String)
}

/// Accepts phone connections. Implementations: `LanServer`; a relay client later.
/// Events are delivered on the main actor, in order.
protocol PhoneTransport: AnyObject {
    var onEvent: (@MainActor (TransportEvent) -> Void)? { get set }
    func start()
    func stop()
    func send(_ data: Data, to id: ConnectionID, closeAfter: Bool)
    func close(_ id: ConnectionID)
}

/// WebSocket server advertised over Bonjour as `_volley._tcp`.
final class LanServer: PhoneTransport {
    var onEvent: (@MainActor (TransportEvent) -> Void)?

    private let serviceName: String
    private let txt: [String: String]
    /// Listen here when free. Phones cache the advertised port, and a Mac app that quits without
    /// withdrawing its Bonjour record would otherwise come back on a new port they can't find.
    private let preferredPort: UInt16?
    private let queue = DispatchQueue(label: "app.volley.lan")
    // Accessed only on `queue`.
    private var listener: NWListener?
    private var connections: [ConnectionID: NWConnection] = [:]
    private var usePreferredPort = true

    init(serviceName: String, txt: [String: String], port: UInt16? = nil) {
        self.preferredPort = port
        self.serviceName = serviceName
        self.txt = txt
    }

    func start() {
        queue.async { self.startListener() }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    func send(_ data: Data, to id: ConnectionID, closeAfter: Bool = false) {
        queue.async {
            guard let conn = self.connections[id] else { return }
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
            conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { [weak self] _ in
                if closeAfter { self?.drop(id) }
            })
        }
    }

    func close(_ id: ConnectionID) {
        queue.async { self.drop(id) }
    }

    // MARK: - Private (on `queue`)

    private func startListener() {
        guard listener == nil else { return }
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            let params = NWParameters(tls: nil, tcp: tcp)
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

            let fixed = usePreferredPort ? preferredPort.flatMap(NWEndpoint.Port.init(rawValue:)) : nil
            let l = try fixed.map { try NWListener(using: params, on: $0) } ?? NWListener(using: params)
            l.service = NWListener.Service(name: serviceName, type: "_volley._tcp", domain: nil, txtRecord: NWTXTRecord(txt))
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self else { return }
                switch state {
                case .ready:
                    // A fallback is for this start only; try the preferred port again next time.
                    self.usePreferredPort = true
                    if let port = l?.port?.rawValue { self.emit(.ready(port: port)) }
                case .failed(let error):
                    self.listener?.cancel()
                    self.listener = nil
                    if self.usePreferredPort, self.preferredPort != nil {
                        // Preferred port is taken; take any free one.
                        self.usePreferredPort = false
                        self.startListener()
                        return
                    }
                    self.emit(.failed(error.localizedDescription))
                    self.queue.asyncAfter(deadline: .now() + 3) { self.startListener() }
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
            listener = l
        } catch {
            if usePreferredPort, preferredPort != nil {
                usePreferredPort = false
                startListener()
                return
            }
            emit(.failed(error.localizedDescription))
        }
    }

    private func accept(_ conn: NWConnection) {
        let id = ConnectionID()
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.emit(.opened(id))
                self?.receive(id, conn)
            case .failed, .cancelled:
                self?.drop(id)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(_ id: ConnectionID, _ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { self.drop(id); return }

            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch meta?.opcode {
            case .text?:
                if let data { self.emit(.text(id, data)) }
            case .close?:
                self.drop(id)
                return
            case .none where data?.isEmpty ?? true:
                self.drop(id) // EOF
                return
            default:
                break
            }
            self.receive(id, conn)
        }
    }

    private func drop(_ id: ConnectionID) {
        guard let conn = connections.removeValue(forKey: id) else { return }
        conn.cancel()
        emit(.closed(id))
    }

    private func emit(_ event: TransportEvent) {
        let handler = onEvent
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler?(event) }
        }
    }
}
