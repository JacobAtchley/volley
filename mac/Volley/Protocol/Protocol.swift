import Foundation

/// Wire protocol v1. See docs/PROTOCOL.md.
enum MsgType {
    static let pairRequest = "pair.request"
    static let pairResult = "pair.result"
    static let hello = "hello"
    static let helloOk = "hello.ok"
    static let notificationPosted = "notification.posted"
    static let notificationRemoved = "notification.removed"
    static let notificationDismiss = "notification.dismiss"
    static let smsReceived = "sms.received"
    static let smsSend = "sms.send"
    static let smsSent = "sms.sent"
    static let smsSync = "sms.sync"
    static let smsBatch = "sms.batch"
    static let deviceStatus = "device.status"
    static let notificationFilter = "notification.filter"
    static let notificationSync = "notification.sync"
    static let notificationBatch = "notification.batch"
    static let fsList = "fs.list"
    static let fsListing = "fs.listing"
    static let fsThumb = "fs.thumb"
    static let fsThumbData = "fs.thumbData"
    static let fsDownload = "fs.download"
    static let fsUpload = "fs.upload"
    static let fsUploadReady = "fs.uploadReady"
    static let fsBegin = "fs.begin"
    static let fileAck = "file.ack"
    static let fsEnd = "fs.end"
    static let fsDone = "fs.done"
    static let fsCancel = "fs.cancel"
    static let fsDelete = "fs.delete"
    static let fsDeleted = "fs.deleted"
    static let fsStatus = "fs.status"
}

struct EnvelopeHeader: Decodable {
    let type: String
    let id: String
    let ts: Int64
}

private struct Inbound<Body: Decodable>: Decodable { let body: Body }

private struct Outbound<Body: Encodable>: Encodable {
    let type: String
    let id: String
    let ts: Int64
    let body: Body
}

struct PairRequest: Codable { let deviceId: String; let deviceName: String; let code: String }
struct PairResult: Codable { let ok: Bool; let macId: String; let macName: String; let token: String? }
struct Hello: Codable { let deviceId: String; let deviceName: String; let token: String }
struct HelloOk: Codable { let macId: String; let macName: String }
struct NotificationPosted: Codable, Equatable {
    let key: String
    let pkg: String
    let appName: String
    let title: String
    let text: String
    let postedAt: Int64
}
struct NotificationKey: Codable { let key: String }
struct NotificationFilter: Codable { let excludedPackages: [String] }
struct NotificationSync: Codable { let sinceTime: Int64 }
struct NotificationBatch: Codable { let notifications: [NotificationPosted]; let activeKeys: [String]; let done: Bool }
struct SmsReceived: Codable { let address: String; let body: String; let receivedAt: Int64 }
struct SmsSend: Codable { let requestId: String; let address: String; let body: String; var threadId: Int64? }
struct SmsSent: Codable { let requestId: String; let ok: Bool; let error: String? }
struct SmsSync: Codable { let sinceId: Int64; let sinceTime: Int64; var pendingIds: [Int64] = [] }
struct SmsBatch: Codable { let messages: [SmsRecord]; let done: Bool }
struct SmsRecord: Codable, Equatable {
    let id: Int64
    let threadId: Int64
    let address: String
    let contactName: String?
    let body: String
    let date: Int64
    let outgoing: Bool
    let status: String
}
struct DeviceStatus: Codable, Equatable {
    let battery: Int
    let charging: Bool
    let cellLevel: Int?
    let wifiLevel: Int?
    let wifiConnected: Bool
}

struct FsList: Codable { let requestId: String; let path: String; let showHidden: Bool }
struct FsEntry: Codable, Equatable, Hashable {
    let name: String
    let isDir: Bool
    let size: Int64
    let modified: Int64
    let mime: String?
}
struct FsListing: Codable { let requestId: String; let path: String; let entries: [FsEntry]?; let error: String? }
struct FsThumb: Codable { let requestId: String; let path: String; let maxPx: Int }
struct FsThumbData: Codable { let requestId: String; let jpegBase64: String?; let error: String? }
struct FsDownload: Codable { let transferId: String; let path: String }
struct FsUpload: Codable { let transferId: String; let dir: String; let name: String; let size: Int64 }
struct FsUploadReady: Codable { let transferId: String; let finalName: String }
struct FsBegin: Codable { let transferId: String; let size: Int64; let name: String }
struct FileAck: Codable { let transferId: String; let received: Int }
struct FsEnd: Codable { let transferId: String; let sha256: String }
struct FsDone: Codable { let transferId: String; let ok: Bool; let error: String? }
struct FsCancel: Codable { let transferId: String }
struct FsDelete: Codable { let requestId: String; let paths: [String] }
struct FsDeleteFailure: Codable, Equatable { let path: String; let error: String }
struct FsDeleted: Codable { let requestId: String; let failed: [FsDeleteFailure]? }
struct FsStatus: Codable { let allFilesAccess: Bool }

enum Codec {
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    static func header(_ data: Data) -> EnvelopeHeader? {
        try? decoder.decode(EnvelopeHeader.self, from: data)
    }

    static func body<B: Decodable>(_: B.Type, from data: Data) -> B? {
        try? decoder.decode(Inbound<B>.self, from: data).body
    }

    static func encode<B: Encodable>(_ type: String, _ body: B) -> Data? {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let env = Outbound(type: type, id: UUID().uuidString, ts: now, body: body)
        return try? encoder.encode(env)
    }
}
