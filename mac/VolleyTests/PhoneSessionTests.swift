import XCTest
@testable import Volley

@MainActor
final class PhoneSessionTests: XCTestCase {
    private var transport: FakeTransport!
    private var trust: FakeTrust!
    private var store: GRDBMessageStore!
    private var defaults: UserDefaults!
    private var session: PhoneSession!
    private let conn = ConnectionID()

    override func setUp() async throws {
        transport = FakeTransport()
        trust = FakeTrust()
        trust.save(PairedDevice(id: "d1", name: "Pixel"), token: "t1")
        store = GRDBMessageStore.inMemory()
        defaults = UserDefaults(suiteName: UUID().uuidString)
        makeSession()
    }

    private func makeSession() {
        session = PhoneSession(identity: MacIdentity(id: "mac", name: "Mac"), transport: transport, trust: trust,
                               notifier: FakeNotifier(), store: store, defaults: defaults)
    }

    private func deliver<B: Encodable>(_ type: String, _ body: B) {
        transport.onEvent?(.text(conn, Codec.encode(type, body)!))
    }

    private func connect(_ deviceId: String = "d1", token: String = "t1") {
        transport.onEvent?(.opened(conn))
        deliver(MsgType.hello, Hello(deviceId: deviceId, deviceName: "Pixel", token: token))
    }

    func testHelloSendsSmsSyncWithLastIdAndStartOfDay() {
        store.upsert([sms(9)], deviceId: "d1")
        connect()
        let sync = transport.sentBodies(MsgType.smsSync, as: SmsSync.self)
        let midnight = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        XCTAssertEqual(sync.map(\.sinceId), [9])
        XCTAssertEqual(sync.map(\.sinceTime), [midnight])
    }

    func testBatchIsStoredAndConversationsReload() {
        connect()
        deliver(MsgType.smsBatch, SmsBatch(messages: [sms(1, name: "Ana")], done: true))
        XCTAssertEqual(session.conversations.map(\.title), ["Ana"])
        XCTAssertEqual(store.lastPhoneId(deviceId: "d1"), 1)
    }

    func testBatchReplacesMatchingPendingSend() {
        connect()
        deliver(MsgType.smsBatch, SmsBatch(messages: [sms(1)], done: true))
        session.open(threadId: 1)
        session.sendSms(to: "+1555", threadId: 1, body: "on my way")
        XCTAssertEqual(session.openThread.map(\.state), [.delivered, .sending])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        deliver(MsgType.smsBatch, SmsBatch(messages: [sms(2, body: "on my way", date: now, outgoing: true, status: "sent")],
                                           done: true))
        XCTAssertEqual(session.openThread.map(\.body), ["hi", "on my way"])
        XCTAssertEqual(session.openThread.map(\.state), [.delivered, .delivered])
    }

    func testSmsSentOkMarksPendingDelivered() throws {
        connect()
        session.open(threadId: 1)
        session.sendSms(to: "+1555", threadId: 1, body: "yo")
        let req = try XCTUnwrap(transport.sentBodies(MsgType.smsSend, as: SmsSend.self).last)
        XCTAssertEqual(req.threadId, 1)
        deliver(MsgType.smsSent, SmsSent(requestId: req.requestId, ok: true, error: nil))
        XCTAssertEqual(session.openThread.map(\.state), [.delivered])
    }

    func testFailedSmsSentMarksPendingFailed() throws {
        connect()
        session.open(threadId: 1)
        session.sendSms(to: "+1555", threadId: 1, body: "yo")
        let req = try XCTUnwrap(transport.sentBodies(MsgType.smsSend, as: SmsSend.self).last)
        deliver(MsgType.smsSent, SmsSent(requestId: req.requestId, ok: false, error: "no service"))
        XCTAssertEqual(session.openThread.map(\.state), [.failed])
    }

    func testSendWhileOfflineFails() {
        session.open(threadId: 1)
        session.sendSms(to: "+1555", threadId: 1, body: "yo")
        XCTAssertEqual(session.openThread.map(\.state), [.failed])
    }

    func testDeviceStatusIsStored() {
        connect()
        let s = DeviceStatus(battery: 42, charging: false, cellLevel: 4, wifiLevel: 3, wifiConnected: true)
        deliver(MsgType.deviceStatus, s)
        XCTAssertEqual(session.deviceStatus?.status, s)
        XCTAssertTrue(session.isConnected)
        transport.onEvent?(.closed(conn))
        XCTAssertFalse(session.isConnected)
        XCTAssertEqual(session.deviceStatus?.status, s)
    }

    func testCurrentDeviceFallsBackToLastConnected() {
        trust.save(PairedDevice(id: "d0", name: "Old"), token: "t0")
        makeSession()
        XCTAssertEqual(session.currentDevice?.id, "d0")
        connect()
        transport.onEvent?(.closed(conn))
        makeSession()
        XCTAssertEqual(session.currentDevice?.id, "d1")
    }

    func testUnpairDeletesStoredData() {
        connect()
        deliver(MsgType.smsBatch, SmsBatch(messages: [sms(1)], done: true))
        session.open(threadId: 1)
        session.unpair(PairedDevice(id: "d1", name: "Pixel"))
        XCTAssertTrue(store.conversations(deviceId: "d1").isEmpty)
        XCTAssertTrue(session.conversations.isEmpty)
        XCTAssertNil(session.openThreadId)
        XCTAssertNil(session.currentDevice)
    }

    func testHelloSyncIncludesStoredPendingIds() {
        store.upsert([sms(4, outgoing: true, status: "pending"), sms(9)], deviceId: "d1")
        connect()
        XCTAssertEqual(transport.sentBodies(MsgType.smsSync, as: SmsSync.self).map(\.pendingIds), [[4]])
    }

    func testUnpairWhileConnectedIgnoresLateFrames() {
        connect()
        session.unpair(PairedDevice(id: "d1", name: "Pixel"))
        // The socket closes asynchronously; frames already in flight must not resurrect the device.
        deliver(MsgType.smsBatch, SmsBatch(messages: [sms(1)], done: true))
        deliver(MsgType.deviceStatus, DeviceStatus(battery: 1, charging: false, cellLevel: nil, wifiLevel: nil,
                                                   wifiConnected: false))
        transport.onEvent?(.closed(conn))
        XCTAssertEqual(store.lastPhoneId(deviceId: "d1"), 0)
        XCTAssertNil(store.status(deviceId: "d1"))
    }
}
