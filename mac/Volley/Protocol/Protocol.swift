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
struct NotificationPosted: Codable {
    let key: String
    let pkg: String
    let appName: String
    let title: String
    let text: String
    let postedAt: Int64
}
struct NotificationKey: Codable { let key: String }
struct SmsReceived: Codable { let address: String; let body: String; let receivedAt: Int64 }
struct SmsSend: Codable { let requestId: String; let address: String; let body: String }
struct SmsSent: Codable { let requestId: String; let ok: Bool; let error: String? }

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
        let env = Outbound(type: type, id: UUID().uuidString, ts: Int64(Date().timeIntervalSince1970 * 1000), body: body)
        return try? encoder.encode(env)
    }
}
