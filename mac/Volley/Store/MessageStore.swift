import CryptoKit
import Foundation
import GRDB
import os

struct ConversationSummary: Identifiable, Equatable {
    let threadId: Int64
    let address: String
    let name: String?
    let lastBody: String
    let lastDate: Date
    /// Group members (names where known, numbers otherwise), from the thread's latest MMS.
    var participants: [String] = []
    var id: Int64 { threadId }
    var isGroup: Bool { participants.count > 1 }
    /// "Ana", or for a group "Ana, Bob" / "Ana, Bob +2".
    var title: String {
        guard isGroup else { return name ?? address }
        let shown = participants.prefix(2).joined(separator: ", ")
        return participants.count > 2 ? "\(shown) +\(participants.count - 2)" : shown
    }
}

struct StoredAttachment: Equatable, Hashable {
    let partId: Int64
    let mime: String
    let name: String?
    let size: Int64
    let width: Int?
    let height: Int?
    var isImage: Bool { mime.hasPrefix("image/") }
}

struct StoredMessage: Identifiable, Equatable {
    let phoneId: Int64
    let threadId: Int64
    let body: String
    let date: Date
    let outgoing: Bool
    let status: String
    var kind = "sms"
    /// Incoming MMS: who sent it.
    var sender: String?
    var senderName: String?
    var attachments: [StoredAttachment] = []
    /// SMS and MMS ids overlap.
    var id: String { "\(kind)\(phoneId)" }
}

struct StoredStatus: Equatable {
    let status: DeviceStatus?
    let lastSeen: Date
}

/// One version of a phone notification. A changed title or text is a new row; see `contentHash`.
struct StoredNotification: Identifiable, Equatable {
    let key: String
    let contentHash: String
    let pkg: String
    let appName: String
    let title: String
    let text: String
    let postedAt: Date
    let receivedAt: Date
    let cleared: Bool
    var id: String { key + ":" + contentHash }
}

struct AppRef: Hashable, Identifiable {
    let pkg: String
    let name: String
    var id: String { pkg }
}

/// Messages and phone status mirrored from each paired phone. Errors are logged, not thrown.
protocol MessageStore: AnyObject {
    func upsert(_ records: [SmsRecord], deviceId: String)
    /// Highest phone id stored per kind ("sms" or "mms"); the two id spaces overlap.
    func lastPhoneId(deviceId: String, kind: String) -> Int64
    /// Phone ids of outgoing messages still waiting to send, so a sync can learn how they settled.
    func pendingPhoneIds(deviceId: String, kind: String) -> [Int64]
    func conversations(deviceId: String) -> [ConversationSummary]
    func messages(deviceId: String, threadId: Int64) -> [StoredMessage]
    func threadId(deviceId: String, address: String) -> Int64?
    func saveStatus(_ status: DeviceStatus, deviceId: String, at: Date)
    func markSeen(deviceId: String, at: Date)
    func status(deviceId: String) -> StoredStatus?
    func deleteDevice(_ deviceId: String)

    func upsertNotification(_ n: NotificationPosted, deviceId: String, receivedAt: Date)
    /// Newest first; notifications from excluded apps are left out.
    func notifications(deviceId: String) -> [StoredNotification]
    func markNotificationCleared(deviceId: String, key: String)
    /// Marks every not-yet-cleared notification whose key isn't in `activeKeys` as cleared.
    func clearNotifications(deviceId: String, notIn activeKeys: Set<String>)
    func lastViewedNotifications(deviceId: String) -> Date?
    func setLastViewedNotifications(deviceId: String, at: Date)
    func excludedApps() -> [AppRef]
    func setExcluded(_ app: AppRef, _ excluded: Bool)
    /// Apps seen in this phone's notifications, plus excluded ones, by name.
    func seenApps(deviceId: String) -> [AppRef]
}

extension MessageStore {
    func lastPhoneId(deviceId: String) -> Int64 { lastPhoneId(deviceId: deviceId, kind: "sms") }
    func pendingPhoneIds(deviceId: String) -> [Int64] { pendingPhoneIds(deviceId: deviceId, kind: "sms") }
}

/// SQLite via GRDB. Dates are stored as epoch milliseconds, matching the wire protocol.
final class GRDBMessageStore: MessageStore {
    private let db: DatabaseQueue
    private let log = Logger(subsystem: "app.volley.mac", category: "store")

    init(path: String) throws {
        db = try DatabaseQueue(path: path)
        try Self.migrator.migrate(db)
    }

    init(queue: DatabaseQueue) throws {
        db = queue
        try Self.migrator.migrate(db)
    }

    static func inMemory() -> GRDBMessageStore {
        // An in-memory database can't fail to open or migrate.
        try! GRDBMessageStore(queue: DatabaseQueue()) // swiftlint:disable:this force_try
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE messages (
                    device_id TEXT NOT NULL,
                    phone_id INTEGER NOT NULL,
                    thread_id INTEGER NOT NULL,
                    address TEXT NOT NULL,
                    body TEXT NOT NULL,
                    date INTEGER NOT NULL,
                    outgoing INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    PRIMARY KEY (device_id, phone_id)
                );
                CREATE INDEX messages_thread ON messages (device_id, thread_id, date);
                CREATE TABLE contacts (
                    device_id TEXT NOT NULL,
                    address TEXT NOT NULL,
                    name TEXT NOT NULL,
                    PRIMARY KEY (device_id, address)
                );
                CREATE TABLE device_status (
                    device_id TEXT PRIMARY KEY,
                    battery INTEGER,
                    charging INTEGER,
                    cell_level INTEGER,
                    wifi_level INTEGER,
                    wifi_connected INTEGER,
                    last_seen INTEGER NOT NULL
                );
                """)
        }
        m.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE notifications (
                    device_id TEXT NOT NULL,
                    key TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    posted_at INTEGER NOT NULL,
                    pkg TEXT NOT NULL,
                    app_name TEXT NOT NULL,
                    title TEXT NOT NULL,
                    text TEXT NOT NULL,
                    received_at INTEGER NOT NULL,
                    cleared INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (device_id, key, content_hash)
                );
                CREATE INDEX notifications_posted ON notifications (device_id, posted_at);
                CREATE TABLE excluded_apps (pkg TEXT PRIMARY KEY, app_name TEXT NOT NULL);
                CREATE TABLE notification_views (device_id TEXT PRIMARY KEY, last_viewed INTEGER NOT NULL);
                """)
        }
        // MMS: SMS and MMS ids overlap, so the key gains `kind`; groups and photos get their own tables.
        m.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE messages_v3 (
                    device_id TEXT NOT NULL,
                    kind TEXT NOT NULL DEFAULT 'sms',
                    phone_id INTEGER NOT NULL,
                    thread_id INTEGER NOT NULL,
                    address TEXT NOT NULL,
                    body TEXT NOT NULL,
                    date INTEGER NOT NULL,
                    outgoing INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    sender TEXT,
                    PRIMARY KEY (device_id, kind, phone_id)
                );
                INSERT INTO messages_v3 (device_id, kind, phone_id, thread_id, address, body, date, outgoing, status)
                    SELECT device_id, 'sms', phone_id, thread_id, address, body, date, outgoing, status FROM messages;
                DROP TABLE messages;
                ALTER TABLE messages_v3 RENAME TO messages;
                CREATE INDEX messages_thread ON messages (device_id, thread_id, date);
                CREATE TABLE message_participants (
                    device_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    phone_id INTEGER NOT NULL,
                    position INTEGER NOT NULL,
                    address TEXT NOT NULL,
                    name TEXT,
                    PRIMARY KEY (device_id, kind, phone_id, position)
                );
                CREATE TABLE attachments (
                    device_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    phone_id INTEGER NOT NULL,
                    position INTEGER NOT NULL,
                    part_id INTEGER NOT NULL,
                    mime TEXT NOT NULL,
                    name TEXT,
                    size INTEGER NOT NULL,
                    width INTEGER,
                    height INTEGER,
                    PRIMARY KEY (device_id, kind, phone_id, position)
                );
                """)
        }
        return m
    }

    func upsert(_ records: [SmsRecord], deviceId: String) {
        write { db in
            for r in records {
                try db.execute(sql: """
                    INSERT INTO messages
                        (device_id, kind, phone_id, thread_id, address, body, date, outgoing, status, sender)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (device_id, kind, phone_id) DO UPDATE SET
                        thread_id = excluded.thread_id, address = excluded.address, body = excluded.body,
                        date = excluded.date, outgoing = excluded.outgoing, status = excluded.status,
                        sender = excluded.sender
                    """, arguments: [deviceId, r.kind, r.id, r.threadId, r.address, r.body, r.date, r.outgoing,
                                     r.status, r.sender])
                if let name = r.contactName { try saveContact(db, deviceId: deviceId, address: r.address, name: name) }
                if r.kind != "sms" { try saveMmsDetails(db, r, deviceId: deviceId) }
            }
        }
    }

    private func saveContact(_ db: Database, deviceId: String, address: String, name: String) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO contacts (device_id, address, name) VALUES (?, ?, ?)",
                       arguments: [deviceId, address, name])
    }

    /// Participants and attachments are replaced wholesale, so a resent MMS never duplicates them.
    private func saveMmsDetails(_ db: Database, _ r: SmsRecord, deviceId: String) throws {
        let key: StatementArguments = [deviceId, r.kind, r.id]
        for table in ["message_participants", "attachments"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE device_id = ? AND kind = ? AND phone_id = ?",
                           arguments: key)
        }
        for (i, p) in r.participants.enumerated() {
            try db.execute(sql: """
                INSERT INTO message_participants (device_id, kind, phone_id, position, address, name)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: key + [i, p.address, p.contactName])
            if let name = p.contactName { try saveContact(db, deviceId: deviceId, address: p.address, name: name) }
        }
        for (i, a) in r.attachments.enumerated() {
            try db.execute(sql: """
                INSERT INTO attachments (device_id, kind, phone_id, position, part_id, mime, name, size, width, height)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: key + [i, a.partId, a.mime, a.name, a.size, a.width, a.height])
        }
    }

    func lastPhoneId(deviceId: String, kind: String) -> Int64 {
        read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(phone_id) FROM messages WHERE device_id = ? AND kind = ?",
                               arguments: [deviceId, kind])
        }.flatMap { $0 } ?? 0
    }

    func pendingPhoneIds(deviceId: String, kind: String) -> [Int64] {
        read { db in
            try Int64.fetchAll(db, sql: """
                SELECT phone_id FROM messages WHERE device_id = ? AND kind = ? AND status = 'pending' ORDER BY phone_id
                """, arguments: [deviceId, kind])
        } ?? []
    }

    func conversations(deviceId: String) -> [ConversationSummary] {
        read { db in
            // SQLite returns the bare columns from the row holding MAX(date) in each group.
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.thread_id, m.address, c.name, m.body, MAX(m.date) AS date, m.kind, m.phone_id
                FROM messages m
                LEFT JOIN contacts c ON c.device_id = m.device_id AND c.address = m.address
                WHERE m.device_id = ?
                GROUP BY m.thread_id
                ORDER BY date DESC
                """, arguments: [deviceId])
            return try rows.map { row in
                let threadId: Int64 = row[0]
                var body: String = row[3]
                if body.isEmpty {
                    let mimes = try String.fetchAll(db, sql: """
                        SELECT mime FROM attachments WHERE device_id = ? AND kind = ? AND phone_id = ?
                        """, arguments: [deviceId, row[5] as String, row[6] as Int64])
                    if !mimes.isEmpty { body = mimes.contains { $0.hasPrefix("image/") } ? "📷 Photo" : "📎 Attachment" }
                }
                return ConversationSummary(threadId: threadId, address: row[1], name: row[2], lastBody: body,
                                           lastDate: Self.date(row[4]),
                                           participants: try participants(db, deviceId: deviceId, threadId: threadId))
            }
        } ?? []
    }

    /// Labels for the members of the thread's latest MMS; empty for SMS-only threads.
    private func participants(_ db: Database, deviceId: String, threadId: Int64) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT COALESCE(p.name, c.name, p.address) FROM message_participants p
            LEFT JOIN contacts c ON c.device_id = p.device_id AND c.address = p.address
            WHERE p.device_id = ? AND p.kind = 'mms' AND p.phone_id = (
                SELECT phone_id FROM messages WHERE device_id = ? AND thread_id = ? AND kind = 'mms'
                ORDER BY date DESC LIMIT 1)
            ORDER BY p.position
            """, arguments: [deviceId, deviceId, threadId])
    }

    func messages(deviceId: String, threadId: Int64) -> [StoredMessage] {
        read { db in
            var attachments: [String: [StoredAttachment]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT a.kind, a.phone_id, a.part_id, a.mime, a.name, a.size, a.width, a.height FROM attachments a
                JOIN messages m ON m.device_id = a.device_id AND m.kind = a.kind AND m.phone_id = a.phone_id
                WHERE m.device_id = ? AND m.thread_id = ? ORDER BY a.position
                """, arguments: [deviceId, threadId]) {
                let kind: String = row[0], phoneId: Int64 = row[1]
                attachments["\(kind)\(phoneId)", default: []].append(
                    StoredAttachment(partId: row[2], mime: row[3], name: row[4], size: row[5], width: row[6],
                                     height: row[7]))
            }
            return try Row.fetchAll(db, sql: """
                SELECT m.phone_id, m.thread_id, m.body, m.date, m.outgoing, m.status, m.kind, m.sender, c.name
                FROM messages m
                LEFT JOIN contacts c ON c.device_id = m.device_id AND c.address = m.sender
                WHERE m.device_id = ? AND m.thread_id = ? ORDER BY m.date, m.phone_id
                """, arguments: [deviceId, threadId]).map { row in
                var m = StoredMessage(phoneId: row[0], threadId: row[1], body: row[2], date: Self.date(row[3]),
                                      outgoing: row[4], status: row[5], kind: row[6], sender: row[7],
                                      senderName: row[8])
                m.attachments = attachments[m.id] ?? []
                return m
            }
        } ?? []
    }

    /// The one-to-one SMS thread with `address` (group MMS threads also contain the sender's address).
    func threadId(deviceId: String, address: String) -> Int64? {
        read { db in
            try Int64.fetchOne(db, sql: """
                SELECT thread_id FROM messages WHERE device_id = ? AND address = ? AND kind = 'sms'
                ORDER BY date DESC LIMIT 1
                """, arguments: [deviceId, address])
        } ?? nil
    }

    func saveStatus(_ s: DeviceStatus, deviceId: String, at: Date) {
        write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO device_status
                    (device_id, battery, charging, cell_level, wifi_level, wifi_connected, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [deviceId, s.battery, s.charging, s.cellLevel, s.wifiLevel, s.wifiConnected,
                                 Self.millis(at)])
        }
    }

    func markSeen(deviceId: String, at: Date) {
        write { db in
            try db.execute(sql: """
                INSERT INTO device_status (device_id, last_seen) VALUES (?, ?)
                ON CONFLICT (device_id) DO UPDATE SET last_seen = excluded.last_seen
                """, arguments: [deviceId, Self.millis(at)])
        }
    }

    func status(deviceId: String) -> StoredStatus? {
        read { db in
            let sql = "SELECT * FROM device_status WHERE device_id = ?"
            let row = try Row.fetchOne(db, sql: sql, arguments: [deviceId])
            return row.map { row in
                let battery: Int? = row["battery"]
                let status = battery.map {
                    DeviceStatus(battery: $0, charging: row["charging"], cellLevel: row["cell_level"],
                                 wifiLevel: row["wifi_level"], wifiConnected: row["wifi_connected"])
                }
                return StoredStatus(status: status, lastSeen: Self.date(row["last_seen"]))
            }
        } ?? nil
    }

    func deleteDevice(_ deviceId: String) {
        write { db in
            for table in ["messages", "message_participants", "attachments", "contacts", "device_status",
                          "notifications", "notification_views"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE device_id = ?", arguments: [deviceId])
            }
        }
    }

    // MARK: - Notifications

    func upsertNotification(_ n: NotificationPosted, deviceId: String, receivedAt: Date) {
        write { db in
            try db.execute(sql: """
                INSERT INTO notifications
                    (device_id, key, content_hash, posted_at, pkg, app_name, title, text, received_at, cleared)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT (device_id, key, content_hash) DO UPDATE SET
                    -- A newer post of the same text means it's showing on the phone again.
                    cleared = CASE WHEN excluded.posted_at > posted_at THEN 0 ELSE cleared END,
                    -- Only a genuinely newer post is "received" again; a reconnect resend is not new.
                    received_at = CASE WHEN excluded.posted_at > posted_at
                                       THEN excluded.received_at ELSE received_at END,
                    posted_at = MAX(posted_at, excluded.posted_at)
                """, arguments: [deviceId, n.key, Self.contentHash(n), n.postedAt, n.pkg, n.appName, n.title, n.text,
                                 Self.millis(receivedAt)])
        }
    }

    func notifications(deviceId: String) -> [StoredNotification] {
        read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM notifications
                WHERE device_id = ? AND pkg NOT IN (SELECT pkg FROM excluded_apps)
                ORDER BY posted_at DESC, received_at DESC
                """, arguments: [deviceId]).map { row in
                StoredNotification(key: row["key"], contentHash: row["content_hash"], pkg: row["pkg"],
                                   appName: row["app_name"], title: row["title"], text: row["text"],
                                   postedAt: Self.date(row["posted_at"]), receivedAt: Self.date(row["received_at"]),
                                   cleared: row["cleared"])
            }
        } ?? []
    }

    func markNotificationCleared(deviceId: String, key: String) {
        write { db in
            try db.execute(sql: "UPDATE notifications SET cleared = 1 WHERE device_id = ? AND key = ?",
                           arguments: [deviceId, key])
        }
    }

    func clearNotifications(deviceId: String, notIn activeKeys: Set<String>) {
        write { db in
            let keys = try String.fetchAll(db, sql: """
                SELECT DISTINCT key FROM notifications WHERE device_id = ? AND cleared = 0
                """, arguments: [deviceId])
            for key in keys where !activeKeys.contains(key) {
                try db.execute(sql: "UPDATE notifications SET cleared = 1 WHERE device_id = ? AND key = ?",
                               arguments: [deviceId, key])
            }
        }
    }

    func lastViewedNotifications(deviceId: String) -> Date? {
        read { db in
            try Int64.fetchOne(db, sql: "SELECT last_viewed FROM notification_views WHERE device_id = ?",
                               arguments: [deviceId])
        }.flatMap { $0 }.map(Self.date)
    }

    func setLastViewedNotifications(deviceId: String, at: Date) {
        write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO notification_views (device_id, last_viewed) VALUES (?, ?)",
                           arguments: [deviceId, Self.millis(at)])
        }
    }

    func excludedApps() -> [AppRef] {
        read { db in
            try Row.fetchAll(db, sql: "SELECT pkg, app_name FROM excluded_apps ORDER BY app_name COLLATE NOCASE")
                .map { AppRef(pkg: $0[0], name: $0[1]) }
        } ?? []
    }

    func setExcluded(_ app: AppRef, _ excluded: Bool) {
        write { db in
            if excluded {
                try db.execute(sql: "INSERT OR REPLACE INTO excluded_apps (pkg, app_name) VALUES (?, ?)",
                               arguments: [app.pkg, app.name])
            } else {
                try db.execute(sql: "DELETE FROM excluded_apps WHERE pkg = ?", arguments: [app.pkg])
            }
        }
    }

    func seenApps(deviceId: String) -> [AppRef] {
        read { db in
            try Row.fetchAll(db, sql: """
                SELECT pkg, MAX(app_name) AS name FROM (
                    SELECT pkg, app_name FROM notifications WHERE device_id = ?
                    UNION SELECT pkg, app_name FROM excluded_apps
                ) GROUP BY pkg ORDER BY name COLLATE NOCASE
                """, arguments: [deviceId]).map { AppRef(pkg: $0[0], name: $0[1]) }
        } ?? []
    }

    // MARK: - Helpers

    /// Stable across launches (unlike `hashValue`), so the same notification text maps to the same row.
    private static func contentHash(_ n: NotificationPosted) -> String {
        SHA256.hash(data: Data((n.title + "\u{1F}" + n.text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func read<T>(_ body: (Database) throws -> T) -> T? {
        do { return try db.read(body) } catch {
            log.error("read failed: \(error)")
            return nil
        }
    }

    private func write(_ body: (Database) throws -> Void) {
        do { try db.write(body) } catch {
            log.error("write failed: \(error)")
        }
    }

    private static func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    private static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(millis) / 1000) }
}
