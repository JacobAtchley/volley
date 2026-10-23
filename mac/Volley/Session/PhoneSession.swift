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

/// One bubble in the chat view: a stored message or a send still in flight.
struct ChatItem: Identifiable, Equatable {
    enum State { case delivered, sending, failed }
    let id: String
    let body: String
    let date: Date
    let outgoing: Bool
    var state: State
}

/// A message sent from the Mac that the phone hasn't reported back yet. Kept in memory only.
private struct PendingSend {
    let requestId: String
    let address: String
    let threadId: Int64?
    let body: String
    let date: Date
    var state: ChatItem.State
}

struct MirroredNotification: Identifiable {
    var id: String { key }
    let key: String
    let appName: String
    let title: String
    let text: String
    let date: Date
}

/// A section of the window under the phone card.
enum PhoneArea: Hashable { case sms, notifications }

/// Authenticates the phone, routes its messages, and holds the UI state.
@MainActor
@Observable
final class PhoneSession: FileLink {
    enum Status: Equatable {
        case starting
        case waiting
        case connected(String)
        case failed(String)
    }

    private(set) var status: Status = .starting
    /// The connected phone, else the last one that connected, else the first paired.
    private(set) var currentDevice: PairedDevice?
    private(set) var deviceStatus: StoredStatus?
    private(set) var conversations: [ConversationSummary] = []
    private(set) var openThreadId: Int64?
    private(set) var openThread: [ChatItem] = []
    private(set) var area: PhoneArea = .sms
    /// Newest first, excluded apps left out.
    private(set) var notificationHistory: [StoredNotification] = []
    /// While the Notifications area is open: anything received after this is shown as New.
    private(set) var newSince: Date?
    private(set) var newNotificationCount = 0
    private(set) var excludedApps: [AppRef] = []
    private(set) var pairedDevices: [PairedDevice] = []
    private(set) var pairingCode: String?

    private let identity: MacIdentity
    private let transport: PhoneTransport
    private let trust: TrustStore
    private let notifier: DesktopNotifier
    private let store: MessageStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private let codes = PairingCodes()
    @ObservationIgnored private var unauthenticated = Set<ConnectionID>()
    @ObservationIgnored private var active: (conn: ConnectionID, deviceId: String)?
    @ObservationIgnored private var pendingSends: [PendingSend] = []
    /// Binary frames from the authenticated phone (file chunks).
    @ObservationIgnored var onBinary: ((Data) -> Void)?
    /// The authenticated phone's connection closed (or it was unpaired).
    @ObservationIgnored var onDisconnect: (() -> Void)?
    /// `fs.*` and `file.ack` messages from the authenticated phone.
    @ObservationIgnored var onFileMessage: ((String, Data) -> Void)?
    /// The phone's file browser; set by the composition root.
    @ObservationIgnored var files: FileSession?

    private static let lastDeviceKey = "lastDeviceId"
    /// How far apart a Mac send and the phone's stored copy may be timestamped and still match.
    private static let echoWindow: TimeInterval = 60

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    init(identity: MacIdentity, transport: PhoneTransport, trust: TrustStore, notifier: DesktopNotifier,
         store: MessageStore, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.identity = identity
        self.transport = transport
        self.trust = trust
        self.notifier = notifier
        self.store = store
        self.defaults = defaults
        self.now = now
        pairedDevices = trust.all()
        excludedApps = store.excludedApps()
        refreshDevice()

        transport.onEvent = { [weak self] in self?.handle($0) }
        notifier.onReply = { [weak self] address, text in
            guard let self else { return }
            self.sendSms(to: address, threadId: self.threadId(forAddress: address), body: text)
        }
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
        store.deleteDevice(device.id)
        if defaults.string(forKey: Self.lastDeviceKey) == device.id {
            defaults.removeObject(forKey: Self.lastDeviceKey)
        }
        pairedDevices = trust.all()
        if let current = active, current.deviceId == device.id {
            // Forget it now: the socket closes asynchronously and frames still in flight must be ignored.
            onDisconnect?()
            active = nil
            status = .waiting
            transport.close(current.conn)
        }
        if currentDevice?.id == device.id {
            pendingSends.removeAll()
            openThreadId = nil
        }
        refreshDevice()
    }

    func open(threadId: Int64?) {
        openThreadId = threadId
        reloadThread()
    }

    func threadId(forAddress address: String) -> Int64? {
        currentDevice.flatMap { store.threadId(deviceId: $0.id, address: address) }
    }

    func sendSms(to address: String, threadId: Int64?, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let requestId = UUID().uuidString
        let ok = send(MsgType.smsSend, SmsSend(requestId: requestId, address: address, body: text, threadId: threadId))
        pendingSends.append(PendingSend(requestId: requestId, address: address, threadId: threadId, body: text,
                                        date: Date(), state: ok ? .sending : .failed))
        reloadThread()
    }

    func dismiss(key: String) {
        _ = send(MsgType.notificationDismiss, NotificationKey(key: key))
        removeNotification(key)
    }

    func select(area newArea: PhoneArea) {
        guard newArea != area else { return }
        if area == .notifications { leaveNotifications() }
        area = newArea
        if newArea == .notifications, let deviceId = currentDevice?.id {
            newSince = store.lastViewedNotifications(deviceId: deviceId) ?? .distantPast
        }
        reloadNotifications()
    }

    /// Closing the window counts as leaving the Notifications area; it reopens on SMS.
    func windowClosed() {
        select(area: .sms)
    }

    func seenApps() -> [AppRef] {
        currentDevice.map { store.seenApps(deviceId: $0.id) } ?? excludedApps
    }

    func setExcluded(_ app: AppRef, _ excluded: Bool) {
        store.setExcluded(app, excluded)
        excludedApps = store.excludedApps()
        _ = send(MsgType.notificationFilter, NotificationFilter(excludedPackages: excludedApps.map(\.pkg)))
        reloadNotifications()
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
        case .binary(let id, let data):
            if active?.conn == id { onBinary?(data) }
        case .text(let id, let data):
            route(id, data)
        case .closed(let id):
            unauthenticated.remove(id)
            if let current = active, current.conn == id {
                onDisconnect?()
                store.markSeen(deviceId: current.deviceId, at: Date())
                active = nil
                status = .waiting
                refreshDevice()
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
            requestSync(device.id)

        case MsgType.pairRequest:
            guard let req = Codec.body(PairRequest.self, from: data), codes.consume(req.code) else {
                pairingCode = codes.current
                let rejected = PairResult(ok: false, macId: identity.id, macName: identity.name, token: nil)
                sendRaw(MsgType.pairResult, rejected,
                        to: id, closeAfter: true)
                return
            }
            let device = PairedDevice(id: req.deviceId, name: req.deviceName)
            let token = Secure.token()
            trust.save(device, token: token)
            pairedDevices = trust.all()
            pairingCode = nil
            authenticate(id, device: device)
            let accepted = PairResult(ok: true, macId: identity.id, macName: identity.name, token: token)
            sendRaw(MsgType.pairResult, accepted, to: id)
            requestSync(device.id)

        default:
            transport.close(id)
        }
    }

    private func routeAuthenticated(_ type: String, _ data: Data) {
        switch type {
        case MsgType.notificationPosted:
            guard let p = Codec.body(NotificationPosted.self, from: data), let deviceId = active?.deviceId,
                  !isExcluded(p.pkg) else { return }
            store.upsertNotification(p, deviceId: deviceId, receivedAt: now())
            reloadNotifications()
            let posted = Date(timeIntervalSince1970: TimeInterval(p.postedAt) / 1000)
            notifier.showNotification(MirroredNotification(key: p.key, appName: p.appName, title: p.title, text: p.text,
                                                           date: posted))

        case MsgType.notificationBatch:
            // Catch-up after reconnecting: store quietly, no banners.
            guard let batch = Codec.body(NotificationBatch.self, from: data),
                  let deviceId = active?.deviceId else { return }
            let receivedAt = now()
            for p in batch.notifications where !isExcluded(p.pkg) {
                store.upsertNotification(p, deviceId: deviceId, receivedAt: receivedAt)
            }
            store.clearNotifications(deviceId: deviceId, notIn: Set(batch.activeKeys))
            reloadNotifications()

        case MsgType.notificationRemoved:
            guard let k = Codec.body(NotificationKey.self, from: data) else { return }
            removeNotification(k.key)

        case MsgType.smsReceived:
            // Stored via sms.batch; this only drives the desktop notification.
            guard let sms = Codec.body(SmsReceived.self, from: data) else { return }
            notifier.showSms(from: sms.address, body: sms.body)

        case MsgType.smsSent:
            guard let r = Codec.body(SmsSent.self, from: data),
                  let i = pendingSends.firstIndex(where: { $0.requestId == r.requestId }) else { return }
            pendingSends[i].state = r.ok ? .delivered : .failed
            reloadThread()

        case MsgType.smsBatch:
            guard let batch = Codec.body(SmsBatch.self, from: data), let deviceId = active?.deviceId else { return }
            store.upsert(batch.messages, deviceId: deviceId)
            for r in batch.messages where r.outgoing { dropEchoedSend(of: r) }
            reload()

        case MsgType.deviceStatus:
            guard let s = Codec.body(DeviceStatus.self, from: data), let deviceId = active?.deviceId else { return }
            store.saveStatus(s, deviceId: deviceId, at: Date())
            reload()

        default:
            if type.hasPrefix("fs.") || type == MsgType.fileAck { onFileMessage?(type, data) }
        }
    }

    // MARK: - Helpers

    private func authenticate(_ id: ConnectionID, device: PairedDevice) {
        unauthenticated.remove(id)
        if let old = active, old.conn != id { transport.close(old.conn) }
        if currentDevice?.id != device.id {
            pendingSends.removeAll()
            openThreadId = nil
        }
        active = (id, device.id)
        defaults.set(device.id, forKey: Self.lastDeviceKey)
        store.markSeen(deviceId: device.id, at: Date())
        status = .connected(device.name)
        refreshDevice()
    }

    /// Tells the phone what to skip, then asks for messages and notifications we don't have yet,
    /// never older than local midnight.
    private func requestSync(_ deviceId: String) {
        _ = send(MsgType.notificationFilter, NotificationFilter(excludedPackages: excludedApps.map(\.pkg)))
        let midnight = Calendar.current.startOfDay(for: Date())
        _ = send(MsgType.smsSync, SmsSync(sinceId: store.lastPhoneId(deviceId: deviceId),
                                          sinceTime: Int64(midnight.timeIntervalSince1970 * 1000),
                                          pendingIds: store.pendingPhoneIds(deviceId: deviceId)))
        _ = send(MsgType.notificationSync, NotificationSync(sinceTime: Int64(midnight.timeIntervalSince1970 * 1000)))
    }

    @discardableResult
    func sendMessage<B: Encodable>(_ type: String, _ body: B) -> Bool { send(type, body) }

    /// Sends a binary frame to the authenticated phone. False when no phone is connected.
    @discardableResult
    func sendBinary(_ data: Data) -> Bool {
        guard let conn = active?.conn else { return false }
        transport.sendBinary(data, to: conn)
        return true
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

    private func refreshDevice() {
        let paired = pairedDevices
        let preferred = active?.deviceId ?? defaults.string(forKey: Self.lastDeviceKey)
        currentDevice = paired.first { $0.id == preferred } ?? paired.first
        reload()
    }

    private func reload() {
        guard let deviceId = currentDevice?.id else {
            conversations = []
            deviceStatus = nil
            openThread = []
            return
        }
        conversations = store.conversations(deviceId: deviceId)
        deviceStatus = store.status(deviceId: deviceId)
        reloadThread()
        reloadNotifications()
    }

    private func reloadNotifications() {
        guard let deviceId = currentDevice?.id else {
            notificationHistory = []
            newNotificationCount = 0
            return
        }
        notificationHistory = store.notifications(deviceId: deviceId)
        if area == .notifications {
            newNotificationCount = 0
        } else {
            let lastViewed = store.lastViewedNotifications(deviceId: deviceId) ?? .distantPast
            newNotificationCount = notificationHistory.count { $0.receivedAt > lastViewed }
        }
    }

    private func leaveNotifications() {
        if let deviceId = currentDevice?.id { store.setLastViewedNotifications(deviceId: deviceId, at: now()) }
        newSince = nil
    }

    private func isExcluded(_ pkg: String) -> Bool {
        excludedApps.contains { $0.pkg == pkg }
    }

    private func reloadThread() {
        guard let deviceId = currentDevice?.id, let threadId = openThreadId else {
            openThread = []
            return
        }
        let stored = store.messages(deviceId: deviceId, threadId: threadId).map { m in
            ChatItem(id: "p\(m.phoneId)", body: m.body, date: m.date, outgoing: m.outgoing,
                     state: m.status == "failed" ? .failed : m.status == "pending" ? .sending : .delivered)
        }
        let pending = pendingSends.filter { $0.threadId == threadId }.map {
            ChatItem(id: $0.requestId, body: $0.body, date: $0.date, outgoing: true, state: $0.state)
        }
        openThread = stored + pending
    }

    /// The phone stores what we sent and syncs it back; drop our in-memory copy once it arrives.
    private func dropEchoedSend(of r: SmsRecord) {
        let date = Date(timeIntervalSince1970: TimeInterval(r.date) / 1000)
        pendingSends.removeAll { p in
            (p.threadId == r.threadId || (p.threadId == nil && p.address == r.address))
                && p.body == r.body && abs(p.date.timeIntervalSince(date)) <= Self.echoWindow
        }
    }

    private func removeNotification(_ key: String) {
        if let deviceId = currentDevice?.id { store.markNotificationCleared(deviceId: deviceId, key: key) }
        reloadNotifications()
        notifier.removeNotification(key: key)
    }
}
