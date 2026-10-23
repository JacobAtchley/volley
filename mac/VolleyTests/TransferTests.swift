import CryptoKit
import XCTest
@testable import Volley

final class TransferTests: XCTestCase {
    private let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ bytes: [UInt8]) throws -> FileHandle {
        let url = dir.appendingPathComponent(UUID().uuidString)
        try Data(bytes).write(to: url)
        return try FileHandle(forReadingFrom: url)
    }

    private func sink() throws -> (FileHandle, URL) {
        let url = dir.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (try FileHandle(forWritingTo: url), url)
    }

    private func sha(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    func testFrameRoundTrip() throws {
        let frame = ChunkFrame.encode(id, Data([1, 2, 3]))
        let (decodedId, payload) = try XCTUnwrap(ChunkFrame.decode(frame))
        XCTAssertEqual(decodedId, id)
        XCTAssertEqual(payload, Data([1, 2, 3]))
    }

    func testInteropWithAndroidFraming() {
        // Same vector as Android's TransferTest.frameRoundTrip.
        let hex = ChunkFrame.encode(id, Data([1, 2, 3])).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "00112233445566778899aabbccddeeff010203")
    }

    func testDecodeRejectsShortFrame() { XCTAssertNil(ChunkFrame.decode(Data(count: 15))) }

    func testSenderRespectsWindow() throws {
        var frames: [Data] = []
        let sender = ChunkSender(id: id, input: try file(Array(repeating: 0, count: 80)),
                                 send: { frames.append($0); return true }, window: 8, chunk: 4)
        XCTAssertFalse(sender.pump())
        XCTAssertEqual(frames.count, 8)
        sender.onAck(3)
        XCTAssertFalse(sender.pump())
        XCTAssertEqual(frames.count, 11)
    }

    func testSenderFinishesAfterAllAcked() throws {
        let data = (0..<10).map { UInt8($0) }
        var frames: [Data] = []
        let sender = ChunkSender(id: id, input: try file(data), send: { frames.append($0); return true },
                                 window: 8, chunk: 4)
        XCTAssertTrue(sender.pump())
        XCTAssertEqual(frames.compactMap { ChunkFrame.decode($0)?.1.count }, [4, 4, 2])
        XCTAssertFalse(sender.done)
        sender.onAck(3)
        XCTAssertTrue(sender.done)
        XCTAssertEqual(sender.sha256Hex, sha(data))
    }

    func testReceiverAcksCumulativelyAndVerifies() throws {
        var acks: [Int] = []
        let (out, url) = try sink()
        let receiver = ChunkReceiver(id: id, output: out) { acks.append($0) }
        [Data([1]), Data([2]), Data([3])].forEach(receiver.onChunk)
        XCTAssertEqual(acks, [1, 2, 3])
        XCTAssertTrue(receiver.finish(expectedSha256: sha([1, 2, 3])))
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
    }

    func testReceiverRejectsBadSha() throws {
        let (out, _) = try sink()
        let receiver = ChunkReceiver(id: id, output: out) { _ in }
        receiver.onChunk(Data([1, 2]))
        XCTAssertFalse(receiver.finish(expectedSha256: sha([9])))
    }

    func testZeroByteFileCompletes() throws {
        var frames: [Data] = []
        let sender = ChunkSender(id: id, input: try file([]), send: { frames.append($0); return true })
        XCTAssertTrue(sender.pump())
        XCTAssertTrue(frames.isEmpty)
        XCTAssertTrue(sender.done)
        XCTAssertEqual(sender.sha256Hex, sha([]))
        let (out, _) = try sink()
        XCTAssertTrue(ChunkReceiver(id: id, output: out) { _ in }.finish(expectedSha256: sha([])))
    }

    func testReceiverWriteFailureFailsVerification() throws {
        let (out, _) = try sink()
        try out.close() // writes now fail, as on a full disk
        let receiver = ChunkReceiver(id: id, output: out) { _ in }
        receiver.onChunk(Data([1, 2]))
        XCTAssertFalse(receiver.finish(expectedSha256: sha([1, 2])))
    }
}
