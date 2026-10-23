import XCTest
@testable import Volley

/// The phone caches the advertised port; a restart must come back on the same one.
@MainActor
final class LanServerTests: XCTestCase {
    private func readyPort(_ server: LanServer) async -> UInt16? {
        await withCheckedContinuation { cont in
            var done = false
            server.onEvent = { event in
                guard !done else { return }
                switch event {
                case .ready(let port): done = true; cont.resume(returning: port)
                case .failed: done = true; cont.resume(returning: nil)
                default: break
                }
            }
            server.start()
        }
    }

    // Below the ephemeral range (49152+), so outgoing connections can't already hold it.
    private let port = UInt16.random(in: 40_000...44_000)

    func testListensOnPreferredPort() async {
        let server = LanServer(serviceName: "VolleyTest-\(UUID().uuidString.prefix(6))", txt: [:], port: port)
        defer { server.stop() }
        let ready = await readyPort(server)
        XCTAssertEqual(ready, port)
    }

    func testFallsBackWhenPreferredPortIsTaken() async {
        let first = LanServer(serviceName: "VolleyTest-\(UUID().uuidString.prefix(6))", txt: [:], port: port)
        defer { first.stop() }
        let firstPort = await readyPort(first)
        XCTAssertEqual(firstPort, port)
        let second = LanServer(serviceName: "VolleyTest-\(UUID().uuidString.prefix(6))", txt: [:], port: port)
        defer { second.stop() }
        let secondPort = await readyPort(second)
        XCTAssertNotNil(secondPort)
        XCTAssertNotEqual(secondPort, port)
    }

    func testBinaryFrameRoundTrip() async throws {
        let server = LanServer(serviceName: "VolleyTest-\(UUID().uuidString.prefix(6))", txt: [:], port: port)
        defer { server.stop() }
        var opened: ConnectionID?
        var received: Data?
        let ready = expectation(description: "ready")
        let gotBinary = expectation(description: "binary")
        server.onEvent = { event in
            switch event {
            case .ready: ready.fulfill()
            case .opened(let id): opened = id
            case let .binary(_, data): received = data; gotBinary.fulfill()
            default: break
            }
        }
        server.start()
        await fulfillment(of: [ready], timeout: 5)

        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/"))
        let client = URLSession.shared.webSocketTask(with: url)
        client.resume()
        try await client.send(.data(Data([1, 2, 3])))
        await fulfillment(of: [gotBinary], timeout: 5)
        XCTAssertEqual(received, Data([1, 2, 3]))

        server.sendBinary(Data([9]), to: try XCTUnwrap(opened))
        guard case let .data(echo) = try await client.receive() else { return XCTFail("expected binary") }
        XCTAssertEqual(echo, Data([9]))
        client.cancel(with: .normalClosure, reason: nil)
    }
}
