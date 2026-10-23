import XCTest
@testable import Volley

@MainActor
final class NotificationSessionTests: XCTestCase {
    private var transport: FakeTransport!
    private var notifier: FakeNotifier!
    private var store: GRDBMessageStore!
    private var session: PhoneSession!
    private let conn = ConnectionID()
    /// Advances 1 s per read so "before" and "after" are always distinguishable.
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        transport = FakeTransport()
        notifier = FakeNotifier()
        let trust = FakeTrust()
        trust.save(PairedDevice(id: "d1", name: "Pixel"), token: "t1")
        store = GRDBMessageStore.inMemory()
        session = PhoneSession(identity: MacIdentity(id: "mac", name: "Mac"), transport: transport, trust: trust,
                               notifier: notifier, store: store, defaults: scratchDefaults(),
                               now: { [unowned self] in clock = clock.addingTimeInterval(1); return clock })
    }

    private func deliver<B: Encodable>(_ type: String, _ body: B) {
        transport.onEvent?(.text(conn, Codec.encode(type, body)!))
    }

    private func connect() {
        transport.onEvent?(.opened(conn))
        deliver(MsgType.hello, Hello(deviceId: "d1", deviceName: "Pixel", token: "t1"))
    }

    func testAuthSendsFilterThenSyncs() {
        session.setExcluded(AppRef(pkg: "com.slack", name: "Slack"), true)
        connect()
        let types = transport.sent.compactMap { Codec.header($0)?.type }
        XCTAssertEqual(types, [MsgType.helloOk, MsgType.notificationFilter, MsgType.smsSync, MsgType.notificationSync])
        let filters = transport.sentBodies(MsgType.notificationFilter, as: NotificationFilter.self)
        XCTAssertEqual(filters.map(\.excludedPackages), [["com.slack"]])
        let midnight = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let syncs = transport.sentBodies(MsgType.notificationSync, as: NotificationSync.self)
        XCTAssertEqual(syncs.map(\.sinceTime), [midnight])
    }

    func testLivePostStoresAndBanners() {
        connect()
        deliver(MsgType.notificationPosted, posted())
        XCTAssertEqual(session.notificationHistory.map(\.key), ["k1"])
        XCTAssertEqual(notifier.shown.map(\.key), ["k1"])
    }

    func testBatchStoresWithoutBannersAndClearsMissing() {
        connect()
        deliver(MsgType.notificationPosted, posted("gone"))
        deliver(MsgType.notificationBatch, NotificationBatch(notifications: [posted("a"), posted("b")],
                                                             activeKeys: ["a", "b"], done: true))
        XCTAssertEqual(notifier.shown.map(\.key), ["gone"])
        let states = session.notificationHistory.map { "\($0.key)=\($0.cleared)" }.sorted()
        XCTAssertEqual(states, ["a=false", "b=false", "gone=true"])
    }

    func testRemovedMarksCleared() {
        connect()
        deliver(MsgType.notificationPosted, posted())
        deliver(MsgType.notificationRemoved, NotificationKey(key: "k1"))
        XCTAssertEqual(session.notificationHistory.map(\.cleared), [true])
    }

    func testDismissMarksClearedAndTellsPhone() {
        connect()
        deliver(MsgType.notificationPosted, posted())
        session.dismiss(key: "k1")
        XCTAssertEqual(session.notificationHistory.map(\.cleared), [true])
        XCTAssertEqual(transport.sentBodies(MsgType.notificationDismiss, as: NotificationKey.self).map(\.key), ["k1"])
    }

    func testExcludedLivePostIgnored() {
        session.setExcluded(AppRef(pkg: "com.slack", name: "Slack"), true)
        connect()
        deliver(MsgType.notificationPosted, posted(pkg: "com.slack", app: "Slack"))
        XCTAssertTrue(session.notificationHistory.isEmpty)
        XCTAssertTrue(notifier.shown.isEmpty)
        XCTAssertEqual(session.newNotificationCount, 0)
    }

    func testNewCountAndLeaveResets() {
        connect()
        deliver(MsgType.notificationPosted, posted("a"))
        deliver(MsgType.notificationPosted, posted("b"))
        XCTAssertEqual(session.newNotificationCount, 2)
        session.select(area: .notifications)
        XCTAssertEqual(session.newNotificationCount, 0)
        XCTAssertEqual(session.newSince, .distantPast)
        session.select(area: .sms)
        XCTAssertNil(session.newSince)
        XCTAssertEqual(session.newNotificationCount, 0)
        XCTAssertNotNil(store.lastViewedNotifications(deviceId: "d1"))
        deliver(MsgType.notificationPosted, posted("c"))
        XCTAssertEqual(session.newNotificationCount, 1)
    }

    func testWindowClosedCountsAsLeaving() {
        connect()
        session.select(area: .notifications)
        session.windowClosed()
        XCTAssertNotNil(store.lastViewedNotifications(deviceId: "d1"))
        XCTAssertNil(session.newSince)
        XCTAssertEqual(session.area, .sms)
        deliver(MsgType.notificationPosted, posted())
        XCTAssertEqual(session.newNotificationCount, 1, "a closed window must not swallow the badge")
    }

    func testArrivalWhileViewingDoesNotBadge() throws {
        connect()
        session.select(area: .notifications)
        deliver(MsgType.notificationPosted, posted())
        XCTAssertEqual(session.newNotificationCount, 0)
        let row = try XCTUnwrap(session.notificationHistory.first)
        XCTAssertGreaterThan(row.receivedAt, try XCTUnwrap(session.newSince))
    }

    func testSetExcludedSendsFilterAndHides() {
        connect()
        deliver(MsgType.notificationPosted, posted(pkg: "com.slack", app: "Slack"))
        let slack = AppRef(pkg: "com.slack", name: "Slack")
        XCTAssertEqual(session.seenApps(), [slack])
        session.setExcluded(slack, true)
        XCTAssertTrue(session.notificationHistory.isEmpty)
        XCTAssertEqual(session.excludedApps, [slack])
        let filter = transport.sentBodies(MsgType.notificationFilter, as: NotificationFilter.self).last
        XCTAssertEqual(filter?.excludedPackages, ["com.slack"])
        session.setExcluded(slack, false)
        XCTAssertEqual(session.notificationHistory.count, 1)
    }
}
