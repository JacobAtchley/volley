import XCTest
@testable import Volley

final class ProtocolTests: XCTestCase {
    func testDecodesSmsBatch() throws {
        let json = """
        {"type":"sms.batch","id":"x","ts":1,"body":{"done":true,"messages":[
          {"id":7,"threadId":3,"address":"+15551234567","body":"hi","date":1000,"outgoing":false,"status":"received"}
        ]}}
        """
        let batch = try XCTUnwrap(Codec.body(SmsBatch.self, from: Data(json.utf8)))
        XCTAssertTrue(batch.done)
        XCTAssertEqual(batch.messages, [SmsRecord(id: 7, threadId: 3, address: "+15551234567", contactName: nil,
                                                  body: "hi", date: 1000, outgoing: false, status: "received")])
    }

    func testEncodesSmsSyncBody() throws {
        let data = try XCTUnwrap(Codec.encode(MsgType.smsSync, SmsSync(sinceId: 42, sinceTime: 1000)))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "sms.sync")
        let body = try XCTUnwrap(obj["body"] as? [String: Any])
        XCTAssertEqual(body["sinceId"] as? Int, 42)
        XCTAssertEqual(body["sinceTime"] as? Int, 1000)
    }

    func testDecodesNotificationBatch() throws {
        let json = """
        {"type":"notification.batch","id":"x","ts":1,"body":{"done":true,"activeKeys":["k1","k2"],"notifications":[
          {"key":"k1","pkg":"com.slack","appName":"Slack","title":"Ana","text":"deploy is green","postedAt":1000}
        ]}}
        """
        let batch = try XCTUnwrap(Codec.body(NotificationBatch.self, from: Data(json.utf8)))
        XCTAssertEqual(batch.activeKeys, ["k1", "k2"])
        XCTAssertEqual(batch.notifications, [NotificationPosted(key: "k1", pkg: "com.slack", appName: "Slack",
                                                                title: "Ana", text: "deploy is green", postedAt: 1000)])
    }

    func testEncodesNotificationFilter() throws {
        let filter = NotificationFilter(excludedPackages: ["com.slack"])
        let data = try XCTUnwrap(Codec.encode(MsgType.notificationFilter, filter))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "notification.filter")
        XCTAssertEqual((obj["body"] as? [String: Any])?["excludedPackages"] as? [String], ["com.slack"])
    }
}
