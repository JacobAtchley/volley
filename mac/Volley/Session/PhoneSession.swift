import Foundation
import Observation

struct MacIdentity {
    let id: String
    let name: String

    static func load(defaults: UserDefaults = .standard) -> MacIdentity {
        let id = defaults.string(forKey: "macId") ?? {
            let new = UUID().uuidString
            defaults.set(new, forKey: "macId")
            return new
        }()
        return MacIdentity(id: id, name: Host.current().localizedName ?? "Mac")
    }
}

struct SmsItem: Identifiable {
    let id: String
    let body: String
    let date: Date
    let outgoing: Bool
    var failed = false
}

struct Conversation: Identifiable {
    var id: String { address }
    let address: String
    var items: [SmsItem]
    var lastDate: Date { items.last?.date ?? .distantPast }
}

struct MirroredNotification: Identifiable {
    var id: String { key }
    let key: String
    let appName: String
    let title: String
    let text: String
    let date: Date
}

/// Authenticates the phone, routes its messages, and holds the UI state.
@MainActor
@Observable
final class PhoneSession {
    enum Status: Equatable {
        case starting
        case waiting
        case connected(String)
        case failed(String)
    }

    private(set) var status: Status = .starting
    private(set) var conversations: [Conversation] = []
    private(set) var notifications: [MirroredNotification] = []
    private(set) var pairedDevices: [PairedDevice] = []
    private(set) var pairingCode: String?

    private let identity: MacIdentity
    private let transport: PhoneTransport
    private let trust: TrustStore
    private let notifier: DesktopNotifier
    private let codes = PairingCodes()
    @ObservationIgnored private var unauthenticated = Set<ConnectionID>()
    @ObservationIgnored private var active: (conn: ConnectionID, deviceId: String)?

    private static let maxNotifications = 50
    private static let maxItemsPerConversation = 100

    init(identity: MacIdentity, transport: PhoneTransport, trust: TrustStore, notifier: DesktopNotifier) {
        self.identity = identity
        self.transport = transport
        self.trust = trust
        self.notifier = notifier
        pairedDevices = trust.all()

        transport.onEvent = { [weak self] in self?.handle($0) }
        notifier.onReply = { [weak self] address, text in self?.sendSms(to: address, body: text) }
        notifier.onDismiss = { [weak self] key in self?.dismiss(key: key) }
    }

    func start() {
        notifier.requestAuthorization()
        transport.start()
    }

    // MARK: - User actions

    func startPairing() {
        pairingCode = codes.generate()
    }

    func cancelPairing() {
        codes.clear()
        pairingCode = nil
    }

    func unpair(_ device: PairedDevice) {
        trust.remove(deviceId: device.id)
        pairedDevices = trust.all()
        if let active, active.deviceId == device.id { transport.close(active.conn) }
    }

    func sendSms(to address: String, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let requestId = UUID().uuidString
        let ok = send(MsgType.smsSend, SmsSend(requestId: requestId, address: address, body: text))
        append(SmsItem(id: requestId, body: text, date: Date(), outgoing: true, failed: !ok), to: address)
    }

    func dismiss(key: String) {
        _ = send(MsgType.notificationDismiss, NotificationKey(key: key))
        removeNotification(key)
    }

    // MARK: - Transport events

    private func handle(_ event: TransportEvent) {
        switch event {
        case .ready:
            if active == nil { status = .waiting }
        case .opened(let id):
            unauthenticated.insert(id)
            // Drop connections that never authenticate.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.unauthenticated.contains(id) else { return }
                self.transport.close(id)
            }
        case .text(let id, let data):
            route(id, data)
        case .closed(let id):
            unauthenticated.remove(id)
            if active?.conn == id {
                active = nil
                status = .waiting
            }
        case .failed(let message):
            status = .failed(message)
        }
    }

    private func route(_ id: ConnectionID, _ data: Data) {
        guard let header = Codec.header(data) else { return }
        if active?.conn == id {
            routeAuthenticated(header.type, data)
            return
        }

        switch header.type {
        case MsgType.hello:
            guard let hello = Codec.body(Hello.self, from: data),
                  let device = trust.verify(deviceId: hello.deviceId, token: hello.token) else {
                transport.close(id)
                return
            }
            authenticate(id, device: device)
            sendRaw(MsgType.helloOk, HelloOk(macId: identity.id, macName: identity.name), to: id)

        case MsgType.pairRequest:
            guard let req = Codec.body(PairRequest.self, from: data), codes.consume(req.code) else {
                pairingCode = codes.current
                sendRaw(MsgType.pairResult, PairResult(ok: false, macId: identity.id, macName: identity.name, token: nil),
                        to: id, closeAfter: true)
                return
            }
            let device = PairedDevice(id: req.deviceId, name: req.deviceName)
            let token = Secure.token()
            trust.save(device, token: token)
            pairedDevices = trust.all()
            pairingCode = nil
            authenticate(id, device: device)
            sendRaw(MsgType.pairResult, PairResult(ok: true, macId: identity.id, macName: identity.name, token: token), to: id)

        default:
            transport.close(id)
        }
    }

    private func routeAuthenticated(_ type: String, _ data: Data) {
        switch type {
        case MsgType.notificationPosted:
            guard let p = Codec.body(NotificationPosted.self, from: data) else { return }
            let n = MirroredNotification(key: p.key, appName: p.appName, title: p.title, text: p.text,
                                         date: Date(timeIntervalSince1970: TimeInterval(p.postedAt) / 1000))
            notifications.removeAll { $0.key == n.key }
            notifications.insert(n, at: 0)
            if notifications.count > Self.maxNotifications { notifications.removeLast() }
            notifier.showNotification(n)

        case MsgType.notificationRemoved:
            guard let k = Codec.body(NotificationKey.self, from: data) else { return }
            removeNotification(k.key)

        case MsgType.smsReceived:
            guard let sms = Codec.body(SmsReceived.self, from: data) else { return }
            let date = Date(timeIntervalSince1970: TimeInterval(sms.receivedAt) / 1000)
            append(SmsItem(id: UUID().uuidString, body: sms.body, date: date, outgoing: false), to: sms.address)
            notifier.showSms(from: sms.address, body: sms.body)

        case MsgType.smsSent:
            guard let r = Codec.body(SmsSent.self, from: data), !r.ok else { return }
            markFailed(requestId: r.requestId)

        default:
            break
        }
    }

    // MARK: - Helpers

    private func authenticate(_ id: ConnectionID, device: PairedDevice) {
        unauthenticated.remove(id)
        if let old = active, old.conn != id { transport.close(old.conn) }
        active = (id, device.id)
        status = .connected(device.name)
    }

    @discardableResult
    private func send<B: Encodable>(_ type: String, _ body: B) -> Bool {
        guard let conn = active?.conn else { return false }
        sendRaw(type, body, to: conn)
        return true
    }

    private func sendRaw<B: Encodable>(_ type: String, _ body: B, to id: ConnectionID, closeAfter: Bool = false) {
        guard let data = Codec.encode(type, body) else { return }
        transport.send(data, to: id, closeAfter: closeAfter)
    }

    private func append(_ item: SmsItem, to address: String) {
        if let i = conversations.firstIndex(where: { $0.address == address }) {
            var convo = conversations.remove(at: i)
            convo.items.append(item)
            if convo.items.count > Self.maxItemsPerConversation { convo.items.removeFirst() }
            conversations.insert(convo, at: 0)
        } else {
            conversations.insert(Conversation(address: address, items: [item]), at: 0)
        }
    }

    private func markFailed(requestId: String) {
        for c in conversations.indices {
            if let i = conversations[c].items.lastIndex(where: { $0.id == requestId }) {
                conversations[c].items[i].failed = true
                return
            }
        }
    }

    private func removeNotification(_ key: String) {
        notifications.removeAll { $0.key == key }
        notifier.removeNotification(key: key)
    }
}
