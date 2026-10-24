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
    /// Group chats: who sent an incoming message.
    var sender: String?
    var attachments: [StoredAttachment] = []
    /// Photos sent from this Mac, shown from its own copies.
    var localImages: [URL] = []
    /// Why a send failed, as the phone reported it.
    var error: String?
}

/// A message sent from the Mac that the phone hasn't reported back yet. Kept in memory only.
private struct PendingSend {
    let requestId: String
    let address: String
    let threadId: Int64?
    let body: String
    let date: Date
    var state: ChatItem.State
    var images: [URL] = []
    var error: String?
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
enum PhoneArea: Hashable { case sms, notifications, files }

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
    /// JPEG thumbnails of MMS photos by part id, fetched on demand.
    private(set) var mmsThumbs: [Int64: Data] = [:]

    private let identity: MacIdentity
    private let transport: PhoneTransport
    private let trust: TrustStore
    private let notifier: DesktopNotifier
    private let store: MessageStore
    private let defaults: UserDefaults
    private let now: () -> Date
    /// Copies of photos sent from this Mac (the phone doesn't keep them).
    private let sentPhotosDir: URL
    private let codes = PairingCodes()
    @ObservationIgnored private var unauthenticated = Set<ConnectionID>()
    @ObservationIgnored private var active: (conn: ConnectionID, deviceId: String)?
    @ObservationIgnored private var pendingSends: [PendingSend] = []
    /// Thumbnail request id → part id.
    @ObservationIgnored private var thumbRequests: [String: Int64] = [:]
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
         store: MessageStore, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         sentPhotosDir: URL? = nil) {
        self.sentPhotosDir = sentPhotosDir ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                       in: .userDomainMask)[0]
            .appendingPathComponent("Volley/Sent", isDirectory: true)
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
        notifier.onReply = { [weak self] address, threadId, text in
            guard let self else { return }
            if let threadId {
                self.sendMessage(threadId: threadId, text: text)
            } else {
                self.sendSms(to: address, threadId: self.threadId(forAddress: address), body: text)
            }
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

    /// Replies in a conversation: one-to-one text goes as SMS; a group, or anything with photos, as MMS to
    /// everyone in the thread. Photos are uploaded to the phone first.
    func sendMessage(threadId: Int64, text: String, attachments: [URL] = []) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !attachments.isEmpty, let deviceId = currentDevice?.id else { return }
        let group = store.participantAddresses(deviceId: deviceId, threadId: threadId)
        let address = conversations.first { $0.threadId == threadId }?.address ?? group.first
        if attachments.isEmpty, group.count <= 1, let address {
            return sendSms(to: address, threadId: threadId, body: body)
        }
        let recipients = group.isEmpty ? [address].compactMap { $0 } : group
        guard !recipients.isEmpty else { return }
        let requestId = UUID().uuidString
        pendingSends.append(PendingSend(requestId: requestId, address: recipients[0], threadId: threadId, body: body,
                                        date: Date(), state: .sending, images: attachments))
        reloadThread()
        let sendMms = { [weak self] (ids: [String]?) in
            guard let self else { return }
            guard let ids else { return self.markSend(requestId, ok: false, error: "A photo didn't upload") }
            guard self.send(MsgType.mmsSend, MmsSend(requestId: requestId, threadId: threadId, addresses: recipients,
                                                     text: body.isEmpty ? nil : body, attachments: ids)) else {
                return self.markSend(requestId, ok: false, error: "Phone offline")
            }
        }
        guard !attachments.isEmpty else { return sendMms([]) }
        guard isConnected, let files else { return sendMms(nil) }
        files.attachForMms(attachments, then: sendMms)
    }

    /// Asks the phone for a photo's thumbnail unless it's cached or already on its way.
    func requestMmsThumb(partId: Int64) {
        guard mmsThumbs[partId] == nil, !thumbRequests.values.contains(partId) else { return }
        let requestId = UUID().uuidString
        if send(MsgType.mmsThumb, MmsThumb(requestId: requestId, partId: partId, maxPx: 512)) {
            thumbRequests[requestId] = partId
        }
    }

    /// Downloads the full attachment and opens it in the Mac's default app.
    func openAttachment(_ a: StoredAttachment) {
        files?.openMmsPart(partId: a.partId, name: a.name ?? (a.isImage ? "photo.jpg" : "attachment"))
    }

    func dismiss(key: String) {
        _ = send(MsgType.notificationDismiss, NotificationKey(key: key))
        removeNotification(key)
    }

    /// Notifications still showing on the phone, counted once per notification (not per history row).
    var undismissedCount: Int { Set(notificationHistory.filter { !$0.cleared }.map(\.key)).count }

    /// Dismisses every mirrored notification still showing on the phone and marks it cleared here.
    /// History is kept. Does nothing offline: they'd show as uncleared again on the next sync.
    func dismissAll() {
        guard isConnected, let deviceId = currentDevice?.id else { return }
        for key in Set(notificationHistory.filter { !$0.cleared }.map(\.key)) {
            send(MsgType.notificationDismiss, NotificationKey(key: key))
            store.markNotificationCleared(deviceId: deviceId, key: key)
            notifier.removeNotification(key: key)
        }
        reloadNotifications()
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
            guard let r = Codec.body(SmsSent.self, from: data) else { return }
            markSend(r.requestId, ok: r.ok, error: r.error)

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
            routeOther(type, data)
        }
    }

    /// File transfers go to `FileSession`; MMS notifications and thumbnails are handled here.
    private func routeOther(_ type: String, _ data: Data) {
        if type.hasPrefix("fs.") || type == MsgType.fileAck { return onFileMessage?(type, data) ?? () }
        switch type {
        case MsgType.mmsReceived:
            // Stored via sms.batch; this only drives the desktop notification.
            guard let m = Codec.body(MmsReceived.self, from: data) else { return }
            notifier.showMms(m)
        case MsgType.mmsThumbData:
            guard let t = Codec.body(MmsThumbData.self, from: data),
                  let partId = thumbRequests.removeValue(forKey: t.requestId),
                  let jpeg = t.jpegBase64.flatMap({ Data(base64Encoded: $0) }) else { return }
            mmsThumbs[partId] = jpeg
        default:
            break
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
                                          pendingIds: store.pendingPhoneIds(deviceId: deviceId),
                                          sinceMmsId: store.lastPhoneId(deviceId: deviceId, kind: "mms"),
                                          pendingMmsIds: store.pendingPhoneIds(deviceId: deviceId, kind: "mms")))
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
        let isGroup = conversations.first { $0.threadId == threadId }?.isGroup == true
        let stored = store.messages(deviceId: deviceId, threadId: threadId).map { m in
            let local = m.kind == "local"
            return ChatItem(id: m.id, body: m.body, date: m.date, outgoing: m.outgoing,
                            state: m.status == "failed" ? .failed : m.status == "pending" ? .sending : .delivered,
                            sender: isGroup && !m.outgoing ? m.senderName ?? m.sender : nil,
                            attachments: local ? [] : m.attachments,
                            localImages: local ? m.attachments.compactMap { $0.name.map(URL.init(fileURLWithPath:)) }
                                               : [])
        }
        let pending = pendingSends.filter { $0.threadId == threadId }.map {
            ChatItem(id: $0.requestId, body: $0.body, date: $0.date, outgoing: true, state: $0.state,
                     localImages: $0.images, error: $0.error)
        }
        // Stable sort: sends that never echo back (photos) stay where they were sent.
        openThread = (stored + pending).enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
    }

    private func markSend(_ requestId: String, ok: Bool, error: String? = nil) {
        guard let i = pendingSends.firstIndex(where: { $0.requestId == requestId }) else { return }
        pendingSends[i].state = ok ? .delivered : .failed
        pendingSends[i].error = ok ? nil : error
        if ok, !pendingSends[i].images.isEmpty { keepSentPhotos(pendingSends.remove(at: i)) }
        reload()
    }

    /// Photo sends never come back from the phone, so they're stored here with copies of the photos.
    private func keepSentPhotos(_ p: PendingSend) {
        guard let deviceId = currentDevice?.id, let threadId = p.threadId else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: sentPhotosDir, withIntermediateDirectories: true)
        let copies = p.images.compactMap { url -> URL? in
            let copy = sentPhotosDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            return (try? fm.copyItem(at: url, to: copy)) != nil ? copy : nil
        }
        store.saveLocalSend(LocalSend(threadId: threadId, address: p.address, body: p.body, date: p.date,
                                      photos: copies), deviceId: deviceId)
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
