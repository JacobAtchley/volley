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

    private let port = UInt16.random(in: 49_200...49_900)

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
}
