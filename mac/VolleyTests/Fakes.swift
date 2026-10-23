import Foundation
@testable import Volley

final class FakeTransport: PhoneTransport {
    var onEvent: (@MainActor (TransportEvent) -> Void)?
    private(set) var sent: [Data] = []
    private(set) var closed: [ConnectionID] = []

    func start() {}
    func stop() {}
    func send(_ data: Data, to id: ConnectionID, closeAfter: Bool) { sent.append(data) }
    func close(_ id: ConnectionID) { closed.append(id) }

    /// Bodies of sent frames of `type`, decoded as `B`.
    func sentBodies<B: Decodable>(_ type: String, as: B.Type) -> [B] {
        sent.filter { Codec.header($0)?.type == type }.compactMap { Codec.body(B.self, from: $0) }
    }
}

final class FakeTrust: TrustStore {
    var devices: [String: (PairedDevice, String)] = [:]
    func all() -> [PairedDevice] { devices.values.map(\.0).sorted { $0.id < $1.id } }
    func verify(deviceId: String, token: String) -> PairedDevice? {
        devices[deviceId].flatMap { $0.1 == token ? $0.0 : nil }
    }
    func save(_ device: PairedDevice, token: String) { devices[device.id] = (device, token) }
    func remove(deviceId: String) { devices[deviceId] = nil }
}

final class FakeNotifier: DesktopNotifier {
    var onReply: (@MainActor (String, String) -> Void)?
    var onDismiss: (@MainActor (String) -> Void)?
    var onOpen: (@MainActor (String) -> Void)?
    func requestAuthorization() {}
    func showSms(from address: String, body: String) {}
    private(set) var shown: [MirroredNotification] = []
    func showNotification(_ n: MirroredNotification) { shown.append(n) }
    func removeNotification(key: String) {}
}

func sms(_ id: Int64, thread: Int64 = 1, address: String = "+1555", name: String? = nil, body: String = "hi",
         date: Int64 = 1_000, outgoing: Bool = false, status: String = "received") -> SmsRecord {
    SmsRecord(id: id, threadId: thread, address: address, contactName: name, body: body, date: date,
              outgoing: outgoing, status: status)
}
