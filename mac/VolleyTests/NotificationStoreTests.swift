import XCTest
@testable import Volley

func posted(_ key: String = "k1", pkg: String = "com.mail", app: String = "Mail", title: String = "Order",
            text: String = "shipped", at postedAt: Int64 = 1_000) -> NotificationPosted {
    NotificationPosted(key: key, pkg: pkg, appName: app, title: title, text: text, postedAt: postedAt)
}

final class NotificationStoreTests: XCTestCase {
    private var store: GRDBMessageStore!
    private let t0 = Date(timeIntervalSince1970: 5_000)

    override func setUp() { store = GRDBMessageStore.inMemory() }

    func testChangedTextAddsRow() {
        store.upsertNotification(posted(text: "Ana: hi"), deviceId: "d1", receivedAt: t0)
        store.upsertNotification(posted(text: "Ana: hi\nAna: deploy is green", at: 2_000), deviceId: "d1", receivedAt: t0)
        XCTAssertEqual(store.notifications(deviceId: "d1").map(\.text), ["Ana: hi\nAna: deploy is green", "Ana: hi"])
    }

    func testSameContentUpdatesInPlace() {
        store.upsertNotification(posted(at: 1_000), deviceId: "d1", receivedAt: t0)
        store.upsertNotification(posted(at: 3_000), deviceId: "d1", receivedAt: t0.addingTimeInterval(10))
        store.upsertNotification(posted(at: 2_000), deviceId: "d1", receivedAt: t0.addingTimeInterval(5))
        let rows = store.notifications(deviceId: "d1")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].postedAt, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(rows[0].receivedAt, t0.addingTimeInterval(10))
    }

    func testOrderedByPostedDesc() {
        store.upsertNotification(posted("a", at: 1_000), deviceId: "d1", receivedAt: t0)
        store.upsertNotification(posted("b", at: 3_000), deviceId: "d1", receivedAt: t0)
        store.upsertNotification(posted("c", at: 2_000), deviceId: "d1", receivedAt: t0)
        XCTAssertEqual(store.notifications(deviceId: "d1").map(\.key), ["b", "c", "a"])
    }

    func testMarkClearedAffectsAllRowsForKey() {
        store.upsertNotification(posted(text: "one"), deviceId: "d1", receivedAt: t0)
        store.upsertNotification(posted(text: "two"), deviceId: "d1", receivedAt: t0)
        store.upsertNotification(posted("other"), deviceId: "d1", receivedAt: t0)
        store.markNotificationCleared(deviceId: "d1", key: "k1")
        let rows = store.notifications(deviceId: "d1")
        XCTAssertEqual(rows.filter { $0.key == "k1" }.map(\.cleared), [true, true])
        XCTAssertEqual(rows.filter { $0.key == "other" }.map(\.cleared), [false])
    }

    func testClearNotInActiveKeys() {
        store.upsertNotification(posted("a"), deviceId: "d1", receivedAt: t0)
        store.upsertNotification(posted("b"), deviceId: "d1", receivedAt: t0)
        store.clearNotifications(deviceId: "d1", notIn: ["b"])
        XCTAssertEqual(store.notifications(deviceId: "d1").map { "\($0.key)=\($0.cleared)" }.sorted(), ["a=true", "b=false"])
    }

    func testLastViewedRoundTrip() {
        XCTAssertNil(store.lastViewedNotifications(deviceId: "d1"))
        store.setLastViewedNotifications(deviceId: "d1", at: t0)
        XCTAssertEqual(store.lastViewedNotifications(deviceId: "d1"), t0)
    }

    func testExcludedAppsHiddenAndRestorable() {
        store.upsertNotification(posted("s", pkg: "com.slack", app: "Slack"), deviceId: "d1", receivedAt: t0)
        store.upsertNotification(posted("m"), deviceId: "d1", receivedAt: t0)
        let slack = AppRef(pkg: "com.slack", name: "Slack")
        store.setExcluded(slack, true)
        XCTAssertEqual(store.notifications(deviceId: "d1").map(\.key), ["m"])
        XCTAssertEqual(store.excludedApps(), [slack])
        store.setExcluded(slack, false)
        XCTAssertEqual(store.notifications(deviceId: "d1").map(\.key).sorted(), ["m", "s"])
        XCTAssertEqual(store.excludedApps(), [])
    }

    func testSeenAppsIncludesExcluded() {
        store.upsertNotification(posted(pkg: "com.mail", app: "Mail"), deviceId: "d1", receivedAt: t0)
        store.setExcluded(AppRef(pkg: "org.telegram", name: "Telegram"), true)
        XCTAssertEqual(store.seenApps(deviceId: "d1").map(\.name), ["Mail", "Telegram"])
    }

    func testDeleteDeviceRemovesNotifications() {
        store.upsertNotification(posted(), deviceId: "d1", receivedAt: t0)
        store.upsertNotification(posted(), deviceId: "d2", receivedAt: t0)
        store.setLastViewedNotifications(deviceId: "d1", at: t0)
        store.deleteDevice("d1")
        XCTAssertTrue(store.notifications(deviceId: "d1").isEmpty)
        XCTAssertNil(store.lastViewedNotifications(deviceId: "d1"))
        XCTAssertEqual(store.notifications(deviceId: "d2").count, 1)
    }

    func testNewerRepostAfterClearShowsAgain() {
        store.upsertNotification(posted(at: 1_000), deviceId: "d1", receivedAt: t0)
        store.markNotificationCleared(deviceId: "d1", key: "k1")
        store.upsertNotification(posted(at: 1_000), deviceId: "d1", receivedAt: t0)
        XCTAssertEqual(store.notifications(deviceId: "d1").map(\.cleared), [true], "same post resent by sync stays cleared")
        store.upsertNotification(posted(at: 2_000), deviceId: "d1", receivedAt: t0)
        XCTAssertEqual(store.notifications(deviceId: "d1").map(\.cleared), [false])
    }
}
