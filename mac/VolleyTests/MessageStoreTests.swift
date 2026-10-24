import GRDB
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
            sms(3, thread: 1, address: "+1555", body: "latest ana", date: 2_000)
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
        let expected = StoredStatus(status: s, lastSeen: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.status(deviceId: "d1"), expected)
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

    func testSmsAndMmsWithSameIdBothStored() {
        store.upsert([sms(7, body: "text"), mms(7, body: "group", date: 2_000)], deviceId: "d1")
        XCTAssertEqual(store.messages(deviceId: "d1", threadId: 1).map(\.body), ["text", "group"])
        XCTAssertEqual(store.lastPhoneId(deviceId: "d1", kind: "sms"), 7)
        XCTAssertEqual(store.lastPhoneId(deviceId: "d1", kind: "mms"), 7)
        store.upsert([mms(7, body: "group edited", date: 2_000)], deviceId: "d1")
        XCTAssertEqual(store.messages(deviceId: "d1", threadId: 1).map(\.body), ["text", "group edited"])
    }

    func testGroupTitleFromParticipants() {
        let people = [Participant(address: "+1555", contactName: "Ana"),
                      Participant(address: "+1777", contactName: "Bob"),
                      Participant(address: "+1888"), Participant(address: "+1999", contactName: "Cy")]
        store.upsert([mms(1, thread: 4, address: "+1555", name: "Ana", body: "yo", participants: people)],
                     deviceId: "d1")
        let convo = store.conversations(deviceId: "d1").first
        XCTAssertEqual(convo?.participants, ["Ana", "Bob", "+1888", "Cy"])
        XCTAssertEqual(convo?.title, "Ana, Bob +2")
        XCTAssertTrue(convo?.isGroup == true)
        let message = store.messages(deviceId: "d1", threadId: 4).first
        XCTAssertEqual(message?.sender, "+1555")
        XCTAssertEqual(message?.senderName, "Ana")
    }

    func testOneToOneSmsAndMmsShareThread() {
        store.upsert([sms(1, thread: 2, address: "+1555", name: "Ana", body: "text", date: 1_000),
                      mms(1, thread: 2, address: "+1555", body: "pic", date: 2_000,
                          participants: [Participant(address: "+1555", contactName: "Ana")])], deviceId: "d1")
        let convos = store.conversations(deviceId: "d1")
        XCTAssertEqual(convos.map(\.threadId), [2])
        XCTAssertEqual(convos.first?.title, "Ana")
        XCTAssertFalse(convos.first?.isGroup == true)
        XCTAssertEqual(store.messages(deviceId: "d1", threadId: 2).map(\.kind), ["sms", "mms"])
    }

    func testAttachmentsRoundTrip() {
        let photo = Attachment(partId: 70, mime: "image/jpeg", name: "IMG.jpg", size: 50_000, width: 800, height: 600)
        let card = Attachment(partId: 71, mime: "text/x-vcard", name: "Ana.vcf", size: 300)
        store.upsert([mms(3, attachments: [photo, card])], deviceId: "d1")
        store.upsert([mms(3, attachments: [photo, card])], deviceId: "d1") // resend doesn't duplicate
        let stored = store.messages(deviceId: "d1", threadId: 1).first?.attachments
        XCTAssertEqual(stored, [StoredAttachment(partId: 70, mime: "image/jpeg", name: "IMG.jpg", size: 50_000,
                                                 width: 800, height: 600),
                                StoredAttachment(partId: 71, mime: "text/x-vcard", name: "Ana.vcf", size: 300,
                                                 width: nil, height: nil)])
    }

    func testPhotoOnlySnippet() {
        let photo = Attachment(partId: 70, mime: "image/jpeg", name: nil, size: 1)
        store.upsert([sms(1, body: "earlier", date: 1_000), mms(2, body: "", date: 2_000, attachments: [photo])],
                     deviceId: "d1")
        XCTAssertEqual(store.conversations(deviceId: "d1").first?.lastBody, "📷 Photo")
    }

    func testPendingIdsPerKind() {
        store.upsert([sms(1, outgoing: true, status: "pending"), mms(2, outgoing: true, status: "pending")],
                     deviceId: "d1")
        XCTAssertEqual(store.pendingPhoneIds(deviceId: "d1", kind: "sms"), [1])
        XCTAssertEqual(store.pendingPhoneIds(deviceId: "d1", kind: "mms"), [2])
    }

    func testMigrationKeepsExistingSms() throws {
        let queue = try DatabaseQueue()
        try GRDBMessageStore.migrator.migrate(queue, upTo: "v2")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO messages (device_id, phone_id, thread_id, address, body, date, outgoing, status)
                VALUES ('d1', 5, 1, '+1555', 'before', 1000, 0, 'received')
                """)
        }
        let migrated = try GRDBMessageStore(queue: queue)
        XCTAssertEqual(migrated.messages(deviceId: "d1", threadId: 1).map(\.body), ["before"])
        XCTAssertEqual(migrated.messages(deviceId: "d1", threadId: 1).map(\.kind), ["sms"])
        XCTAssertEqual(migrated.lastPhoneId(deviceId: "d1", kind: "sms"), 5)
        XCTAssertEqual(migrated.lastPhoneId(deviceId: "d1", kind: "mms"), 0)
    }
}
