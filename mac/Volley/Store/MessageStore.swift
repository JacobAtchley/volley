import Foundation
import GRDB
import os

struct ConversationSummary: Identifiable, Equatable {
    let threadId: Int64
    let address: String
    let name: String?
    let lastBody: String
    let lastDate: Date
    var id: Int64 { threadId }
    var title: String { name ?? address }
}

struct StoredMessage: Identifiable, Equatable {
    let phoneId: Int64
    let threadId: Int64
    let body: String
    let date: Date
    let outgoing: Bool
    let status: String
    var id: Int64 { phoneId }
}

struct StoredStatus: Equatable {
    let status: DeviceStatus?
    let lastSeen: Date
}

/// Messages and phone status mirrored from each paired phone. Errors are logged, not thrown.
protocol MessageStore: AnyObject {
    func upsert(_ records: [SmsRecord], deviceId: String)
    func lastPhoneId(deviceId: String) -> Int64
    func conversations(deviceId: String) -> [ConversationSummary]
    func messages(deviceId: String, threadId: Int64) -> [StoredMessage]
    func threadId(deviceId: String, address: String) -> Int64?
    func saveStatus(_ status: DeviceStatus, deviceId: String, at: Date)
    func markSeen(deviceId: String, at: Date)
    func status(deviceId: String) -> StoredStatus?
    func deleteDevice(_ deviceId: String)
}

/// SQLite via GRDB. Dates are stored as epoch milliseconds, matching the wire protocol.
final class GRDBMessageStore: MessageStore {
    private let db: DatabaseQueue
    private let log = Logger(subsystem: "app.volley.mac", category: "store")

    init(path: String) throws {
        db = try DatabaseQueue(path: path)
        try Self.migrator.migrate(db)
    }

    private init(queue: DatabaseQueue) throws {
        db = queue
        try Self.migrator.migrate(db)
    }

    static func inMemory() -> GRDBMessageStore {
        // An in-memory database can't fail to open or migrate.
        try! GRDBMessageStore(queue: DatabaseQueue())
    }

    private static var migrator: DatabaseMigrator {
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
        return m
    }

    func upsert(_ records: [SmsRecord], deviceId: String) {
        write { db in
            for r in records {
                try db.execute(sql: """
                    INSERT INTO messages (device_id, phone_id, thread_id, address, body, date, outgoing, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (device_id, phone_id) DO UPDATE SET
                        thread_id = excluded.thread_id, address = excluded.address, body = excluded.body,
                        date = excluded.date, outgoing = excluded.outgoing, status = excluded.status
                    """, arguments: [deviceId, r.id, r.threadId, r.address, r.body, r.date, r.outgoing, r.status])
                if let name = r.contactName {
                    try db.execute(sql: "INSERT OR REPLACE INTO contacts (device_id, address, name) VALUES (?, ?, ?)",
                                   arguments: [deviceId, r.address, name])
                }
            }
        }
    }

    func lastPhoneId(deviceId: String) -> Int64 {
        read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(phone_id) FROM messages WHERE device_id = ?", arguments: [deviceId])
        }.flatMap { $0 } ?? 0
    }

    func conversations(deviceId: String) -> [ConversationSummary] {
        read { db in
            // SQLite returns the bare columns from the row holding MAX(date) in each group.
            try Row.fetchAll(db, sql: """
                SELECT m.thread_id, m.address, c.name, m.body, MAX(m.date) AS date
                FROM messages m
                LEFT JOIN contacts c ON c.device_id = m.device_id AND c.address = m.address
                WHERE m.device_id = ?
                GROUP BY m.thread_id
                ORDER BY date DESC
                """, arguments: [deviceId]).map { row in
                ConversationSummary(threadId: row[0], address: row[1], name: row[2], lastBody: row[3],
                                    lastDate: Self.date(row[4]))
            }
        } ?? []
    }

    func messages(deviceId: String, threadId: Int64) -> [StoredMessage] {
        read { db in
            try Row.fetchAll(db, sql: """
                SELECT phone_id, thread_id, body, date, outgoing, status FROM messages
                WHERE device_id = ? AND thread_id = ? ORDER BY date, phone_id
                """, arguments: [deviceId, threadId]).map { row in
                StoredMessage(phoneId: row[0], threadId: row[1], body: row[2], date: Self.date(row[3]),
                              outgoing: row[4], status: row[5])
            }
        } ?? []
    }

    func threadId(deviceId: String, address: String) -> Int64? {
        read { db in
            try Int64.fetchOne(db, sql: """
                SELECT thread_id FROM messages WHERE device_id = ? AND address = ? ORDER BY date DESC LIMIT 1
                """, arguments: [deviceId, address])
        } ?? nil
    }

    func saveStatus(_ s: DeviceStatus, deviceId: String, at: Date) {
        write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO device_status
                    (device_id, battery, charging, cell_level, wifi_level, wifi_connected, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [deviceId, s.battery, s.charging, s.cellLevel, s.wifiLevel, s.wifiConnected, Self.millis(at)])
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
            try Row.fetchOne(db, sql: "SELECT * FROM device_status WHERE device_id = ?", arguments: [deviceId]).map { row in
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
            for table in ["messages", "contacts", "device_status"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE device_id = ?", arguments: [deviceId])
            }
        }
    }

    // MARK: - Helpers

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
