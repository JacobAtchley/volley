import XCTest
@testable import Volley

@MainActor
final class MmsSessionTests: XCTestCase {
    private var transport: FakeTransport!
    private var notifier: FakeNotifier!
    private var store: GRDBMessageStore!
    private var session: PhoneSession!
    private var files: FileSession!
    private var trust: FakeTrust!
    private var sentDir: URL!
    private let conn = ConnectionID()
    private let ana = Participant(address: "+1555", contactName: "Ana")
    private let bob = Participant(address: "+1777", contactName: "Bob")

    override func setUp() async throws {
        transport = FakeTransport()
        notifier = FakeNotifier()
        trust = FakeTrust()
        trust.save(PairedDevice(id: "d1", name: "Pixel"), token: "t1")
        store = GRDBMessageStore.inMemory()
        sentDir = FileManager.default.temporaryDirectory.appendingPathComponent("volley-sent-\(UUID())")
        addTeardownBlock { [sentDir] in try? FileManager.default.removeItem(at: sentDir!) }
        makeSession()
    }

    private func makeSession() {
        session = PhoneSession(identity: MacIdentity(id: "mac", name: "Mac"), transport: transport, trust: trust,
                               notifier: notifier, store: store, defaults: scratchDefaults(), sentPhotosDir: sentDir)
        files = FileSession(link: session, defaults: scratchDefaults())
        session.files = files
        session.onFileMessage = { [files] in files?.handle(type: $0, data: $1) }
    }

    private func deliver<B: Encodable>(_ type: String, _ body: B) {
        transport.onEvent?(.text(conn, Codec.encode(type, body)!))
    }

    private func connect() {
        transport.onEvent?(.opened(conn))
        deliver(MsgType.hello, Hello(deviceId: "d1", deviceName: "Pixel", token: "t1"))
    }

    private func groupThread() {
        deliver(MsgType.smsBatch, SmsBatch(messages: [
            mms(1, thread: 4, address: "+1555", name: "Ana", body: "dinner?", participants: [ana, bob])
        ], done: true))
    }

    private func photo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("volley-test-\(UUID()).jpg")
        try Data("jpeg".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Plays the phone's side of an `mms.attach` upload; returns its transfer id.
    private func acceptUpload(ok: Bool = true) throws -> String {
        let attach = try XCTUnwrap(transport.sentBodies(MsgType.mmsAttach, as: MmsAttach.self).last)
        deliver(MsgType.fsUploadReady, FsUploadReady(transferId: attach.transferId, finalName: attach.name))
        deliver(MsgType.fileAck, FileAck(transferId: attach.transferId, received: transport.sentBinary.count))
        XCTAssertEqual(transport.sentBodies(MsgType.fsEnd, as: FsEnd.self).last?.transferId, attach.transferId)
        deliver(MsgType.fsDone, FsDone(transferId: attach.transferId, ok: ok, error: ok ? nil : "Checksum mismatch"))
        return attach.transferId
    }

    func testSyncSendsBothCursors() {
        store.upsert([sms(9), mms(4, outgoing: true, status: "pending"), mms(6)], deviceId: "d1")
        connect()
        let sync = transport.sentBodies(MsgType.smsSync, as: SmsSync.self)
        XCTAssertEqual(sync.map(\.sinceId), [9])
        XCTAssertEqual(sync.map(\.pendingIds), [[]])
        XCTAssertEqual(sync.map(\.sinceMmsId), [6])
        XCTAssertEqual(sync.map(\.pendingMmsIds), [[4]])
    }

    func testMmsReceivedShowsNotification() {
        connect()
        let m = MmsReceived(threadId: 4, sender: "+1555", senderName: "Ana", title: "Ana, Bob", text: "dinner?",
                            hasPhoto: false)
        deliver(MsgType.mmsReceived, m)
        XCTAssertEqual(notifier.mms, [m])
    }

    func testNotificationReplyToGroupSendsMms() throws {
        connect()
        groupThread()
        notifier.onReply?("+1555", 4, "on it")
        let req = try XCTUnwrap(transport.sentBodies(MsgType.mmsSend, as: MmsSend.self).single)
        XCTAssertEqual(req.threadId, 4)
        XCTAssertEqual(req.addresses, ["+1555", "+1777"])
        XCTAssertEqual(req.text, "on it")
        XCTAssertEqual(req.attachments, [])
        XCTAssertTrue(transport.sentBodies(MsgType.smsSend, as: SmsSend.self).isEmpty)
    }

    func testOneToOneTextStillUsesSmsSend() throws {
        connect()
        deliver(MsgType.smsBatch, SmsBatch(messages: [
            sms(1, thread: 2, address: "+1555"),
            mms(2, thread: 3, address: "+1999", participants: [Participant(address: "+1999")])
        ], done: true))
        session.sendMessage(threadId: 2, text: "hey")
        session.sendMessage(threadId: 3, text: "nice pic")
        XCTAssertEqual(transport.sentBodies(MsgType.smsSend, as: SmsSend.self).map(\.address), ["+1555", "+1999"])
        XCTAssertTrue(transport.sentBodies(MsgType.mmsSend, as: MmsSend.self).isEmpty)
    }

    func testPhotoSendUploadsThenSendsMms() throws {
        connect()
        deliver(MsgType.smsBatch, SmsBatch(messages: [sms(1, thread: 2, address: "+1555")], done: true))
        session.open(threadId: 2)
        let url = try photo()
        session.sendMessage(threadId: 2, text: "look", attachments: [url])
        XCTAssertEqual(session.openThread.last?.localImages, [url])
        XCTAssertEqual(session.openThread.last?.state, .sending)
        XCTAssertTrue(transport.sentBodies(MsgType.mmsSend, as: MmsSend.self).isEmpty)

        let transferId = try acceptUpload()
        let req = try XCTUnwrap(transport.sentBodies(MsgType.mmsSend, as: MmsSend.self).single)
        XCTAssertEqual(req.addresses, ["+1555"])
        XCTAssertEqual(req.text, "look")
        XCTAssertEqual(req.attachments, [transferId])

        deliver(MsgType.smsSent, SmsSent(requestId: req.requestId, ok: true, error: nil))
        XCTAssertEqual(session.openThread.last?.state, .delivered)
    }

    func testMmsSendFailureMarksBubble() throws {
        connect()
        groupThread()
        session.open(threadId: 4)
        session.sendMessage(threadId: 4, text: "", attachments: [try photo()])
        _ = try acceptUpload(ok: false)
        XCTAssertTrue(transport.sentBodies(MsgType.mmsSend, as: MmsSend.self).isEmpty)
        XCTAssertEqual(session.openThread.last?.state, .failed)

        session.sendMessage(threadId: 4, text: "text only")
        let req = try XCTUnwrap(transport.sentBodies(MsgType.mmsSend, as: MmsSend.self).single)
        deliver(MsgType.smsSent, SmsSent(requestId: req.requestId, ok: false, error: "Carrier rejected the MMS"))
        XCTAssertEqual(session.openThread.last?.state, .failed)
    }

    func testGroupBubblesCarrySenderAndAttachments() {
        connect()
        let pic = Attachment(partId: 70, mime: "image/jpeg", size: 9)
        deliver(MsgType.smsBatch, SmsBatch(messages: [
            mms(1, thread: 4, address: "+1555", name: "Ana", body: "", participants: [ana, bob], attachments: [pic]),
            mms(2, thread: 4, body: "me", outgoing: true, status: "sent", participants: [ana, bob])
        ], done: true))
        session.open(threadId: 4)
        XCTAssertEqual(session.openThread.map(\.sender), ["Ana", nil])
        XCTAssertEqual(session.openThread.first?.attachments.map(\.partId), [70])
    }

    func testThumbnailRequestedOnceAndCached() throws {
        connect()
        session.requestMmsThumb(partId: 70)
        session.requestMmsThumb(partId: 70)
        let req = try XCTUnwrap(transport.sentBodies(MsgType.mmsThumb, as: MmsThumb.self).single)
        XCTAssertEqual(req.partId, 70)
        let jpeg = Data([1, 2]).base64EncodedString()
        deliver(MsgType.mmsThumbData, MmsThumbData(requestId: req.requestId, jpegBase64: jpeg, error: nil))
        XCTAssertEqual(session.mmsThumbs[70], Data([1, 2]))
        session.requestMmsThumb(partId: 70)
        XCTAssertEqual(transport.sentBodies(MsgType.mmsThumb, as: MmsThumb.self).count, 1)
    }
}

extension MmsSessionTests {
    func testNotSentShowsTheReason() throws {
        connect()
        groupThread()
        session.open(threadId: 4)
        session.sendMessage(threadId: 4, text: "hi all")
        let req = try XCTUnwrap(transport.sentBodies(MsgType.mmsSend, as: MmsSend.self).single)
        deliver(MsgType.smsSent, SmsSent(requestId: req.requestId, ok: false, error: "Photo too large to send by MMS"))
        XCTAssertEqual(session.openThread.last?.error, "Photo too large to send by MMS")
    }

    func testSentPhotoKeepsItsPlaceAndSurvivesRestart() throws {
        connect()
        deliver(MsgType.smsBatch, SmsBatch(messages: [sms(1, thread: 2, address: "+1555", date: 1_000)], done: true))
        session.open(threadId: 2)
        let url = try photo()
        session.sendMessage(threadId: 2, text: "look", attachments: [url])
        _ = try acceptUpload()
        let req = try XCTUnwrap(transport.sentBodies(MsgType.mmsSend, as: MmsSend.self).single)
        deliver(MsgType.smsSent, SmsSent(requestId: req.requestId, ok: true, error: nil))

        // A reply that arrives later is shown after the photo, not above it.
        let later = Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        deliver(MsgType.smsBatch, SmsBatch(messages: [sms(2, thread: 2, address: "+1555", body: "nice", date: later)],
                                           done: true))
        XCTAssertEqual(session.openThread.map(\.body), ["hi", "look", "nice"])

        transport.onEvent?(.closed(conn))
        makeSession()
        session.open(threadId: 2)
        let photoItem = try XCTUnwrap(session.openThread.first { $0.body == "look" })
        XCTAssertEqual(photoItem.state, .delivered)
        let saved = try XCTUnwrap(photoItem.localImages.single)
        XCTAssertTrue(saved.path.hasPrefix(sentDir.path))
        XCTAssertEqual(try Data(contentsOf: saved), Data("jpeg".utf8))
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
