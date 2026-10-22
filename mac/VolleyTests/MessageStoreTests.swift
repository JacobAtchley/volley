import XCTest
@testable import Volley

final class MessageStoreTests: XCTestCase {
    private var store: GRDBMessageStore!

    override func setUp() { store = GRDBMessageStore.inMemory() }

    func testUpsertIsIdempotent() {
        store.upsert([sms(1, outgoing: true, status: "pending")], deviceId: "d1")
        store.upsert([sms(1, outgoing: true, status: "pending")], deviceId: "d1")
        XCTAssertEqual(store.messages(deviceId: "d1", threadId: 1).count, 1)
        store.upsert([sms(1, outgoing: true, status: "sent")], deviceId: "d1")
        XCTAssertEqual(store.messages(deviceId: "d1", threadId: 1).map(\.status), ["sent"])
    }

    func testLastPhoneIdPerDevice() {
        XCTAssertEqual(store.lastPhoneId(deviceId: "d1"), 0)
        store.upsert([sms(5), sms(9)], deviceId: "d1")
        store.upsert([sms(20)], deviceId: "d2")
        XCTAssertEqual(store.lastPhoneId(deviceId: "d1"), 9)
    }

    func testConversationsGroupByThreadNewestFirst() {
        store.upsert([
            sms(1, thread: 1, address: "+1555", name: "Ana", body: "old", date: 1_000),
            sms(2, thread: 2, address: "+1999", body: "newest", date: 3_000),
            sms(3, thread: 1, address: "+1555", body: "latest ana", date: 2_000),
        ], deviceId: "d1")
        let convos = store.conversations(deviceId: "d1")
        XCTAssertEqual(convos.map(\.threadId), [2, 1])
        XCTAssertEqual(convos.map(\.title), ["+1999", "Ana"])
        XCTAssertEqual(convos[1].lastBody, "latest ana")
        XCTAssertEqual(store.messages(deviceId: "d1", threadId: 1).map(\.body), ["old", "latest ana"])
        XCTAssertEqual(store.threadId(deviceId: "d1", address: "+1999"), 2)
    }

    func testStatusAndLastSeen() {
        XCTAssertNil(store.status(deviceId: "d1"))
        let s = DeviceStatus(battery: 50, charging: true, cellLevel: 2, wifiLevel: nil, wifiConnected: false)
        store.saveStatus(s, deviceId: "d1", at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.status(deviceId: "d1"), StoredStatus(status: s, lastSeen: Date(timeIntervalSince1970: 100)))
        store.markSeen(deviceId: "d1", at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.status(deviceId: "d1")?.lastSeen, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.status(deviceId: "d1")?.status, s)
    }

    func testDeleteDeviceRemovesOnlyThatDevice() {
        store.upsert([sms(1)], deviceId: "d1")
        store.upsert([sms(1)], deviceId: "d2")
        store.markSeen(deviceId: "d1", at: Date())
        store.deleteDevice("d1")
        XCTAssertTrue(store.conversations(deviceId: "d1").isEmpty)
        XCTAssertNil(store.status(deviceId: "d1"))
        XCTAssertEqual(store.conversations(deviceId: "d2").count, 1)
    }

    func testPendingPhoneIds() {
        store.upsert([sms(1, outgoing: true, status: "pending"), sms(2, outgoing: true, status: "sent"),
                      sms(3, outgoing: true, status: "pending")], deviceId: "d1")
        store.upsert([sms(4, outgoing: true, status: "pending")], deviceId: "d2")
        XCTAssertEqual(store.pendingPhoneIds(deviceId: "d1"), [1, 3])
    }
}
