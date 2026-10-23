import CryptoKit
import XCTest
@testable import Volley

@MainActor
final class FakeLink: FileLink {
    var isConnected = true
    private(set) var sent: [(type: String, data: Data)] = []
    private(set) var binary: [Data] = []

    func sendMessage<B: Encodable>(_ type: String, _ body: B) -> Bool {
        guard isConnected, let data = Codec.encode(type, body) else { return false }
        sent.append((type, data))
        return true
    }

    func sendBinary(_ data: Data) -> Bool {
        guard isConnected else { return false }
        binary.append(data)
        return true
    }

    func bodies<B: Decodable>(_ type: String, as: B.Type) -> [B] {
        sent.filter { $0.type == type }.compactMap { Codec.body(B.self, from: $0.data) }
    }
}

@MainActor
final class FileSessionTests: XCTestCase {
    private var link: FakeLink!
    private var files: FileSession!
    private var dir: URL!
    private var opened: [URL] = []

    override func setUp() async throws {
        link = FakeLink()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        files = FileSession(link: link, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                            tempDir: dir.appendingPathComponent("tmp"), open: { [unowned self] in opened.append($0) })
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func deliver<B: Encodable>(_ type: String, _ body: B) {
        files.handle(type: type, data: Codec.encode(type, body)!)
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func entry(_ name: String, dir isDir: Bool = false, size: Int64 = 3) -> FsEntry {
        FsEntry(name: name, isDir: isDir, size: size, modified: 0, mime: nil)
    }

    /// Plays the phone's side of a download of `data`.
    private func serveDownload(_ data: Data, name: String = "a.bin") throws {
        let req = try XCTUnwrap(link.bodies(MsgType.fsDownload, as: FsDownload.self).last)
        let id = try XCTUnwrap(UUID(uuidString: req.transferId))
        deliver(MsgType.fsBegin, FsBegin(transferId: req.transferId, size: Int64(data.count), name: name))
        if !data.isEmpty { files.handleBinary(ChunkFrame.encode(id, data)) }
        deliver(MsgType.fsEnd, FsEnd(transferId: req.transferId, sha256: sha(data)))
    }

    func testOpenSendsListAndAppliesListing() throws {
        files.open(path: "Pictures")
        let req = try XCTUnwrap(link.bodies(MsgType.fsList, as: FsList.self).last)
        XCTAssertEqual(req.path, "Pictures")
        XCTAssertTrue(files.loading)
        let listing = FsListing(requestId: req.requestId, path: "Pictures", entries: [entry("a.jpg")], error: nil)
        deliver(MsgType.fsListing, listing)
        XCTAssertEqual(files.entries.map(\.name), ["a.jpg"])
        XCTAssertFalse(files.loading)
        XCTAssertEqual(files.path, "Pictures")
    }

    func testStaleListingIgnored() throws {
        files.open(path: "A")
        let first = try XCTUnwrap(link.bodies(MsgType.fsList, as: FsList.self).last)
        files.open(path: "B")
        let stale = FsListing(requestId: first.requestId, path: "A", entries: [entry("old")], error: nil)
        deliver(MsgType.fsListing, stale)
        XCTAssertTrue(files.entries.isEmpty)
        XCTAssertEqual(files.path, "B")
    }

    func testBackForward() {
        files.open(path: "A")
        files.open(path: "A/B")
        files.back()
        XCTAssertEqual(files.path, "A")
        XCTAssertTrue(files.canGoForward)
        files.forward()
        XCTAssertEqual(files.path, "A/B")
        XCTAssertFalse(files.canGoForward)
    }

    func testDownloadQueueRunsOneAtATime() throws {
        files.download(["x.bin", "y.bin"], to: dir)
        XCTAssertEqual(link.bodies(MsgType.fsDownload, as: FsDownload.self).map(\.path), ["x.bin"])
        XCTAssertEqual(files.transfers.map(\.state), [.running, .queued])
        try serveDownload(Data([1]), name: "x.bin")
        XCTAssertEqual(link.bodies(MsgType.fsDownload, as: FsDownload.self).map(\.path), ["x.bin", "y.bin"])
        XCTAssertEqual(files.transfers.map(\.state), [.done, .running])
    }

    func testDownloadWritesFileAndVerifies() throws {
        files.download(["a.bin"], to: dir)
        try serveDownload(Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("a.bin")), Data([1, 2, 3]))
        XCTAssertEqual(link.bodies(MsgType.fileAck, as: FileAck.self).map(\.received), [1])
        XCTAssertEqual(link.bodies(MsgType.fsDone, as: FsDone.self).map(\.ok), [true])
        XCTAssertEqual(files.transfers.first?.transferred, 3)
    }

    func testDownloadChecksumMismatchFailsAndDeletes() throws {
        files.download(["a.bin"], to: dir)
        let req = try XCTUnwrap(link.bodies(MsgType.fsDownload, as: FsDownload.self).last)
        let id = try XCTUnwrap(UUID(uuidString: req.transferId))
        deliver(MsgType.fsBegin, FsBegin(transferId: req.transferId, size: 1, name: "a.bin"))
        files.handleBinary(ChunkFrame.encode(id, Data([1])))
        deliver(MsgType.fsEnd, FsEnd(transferId: req.transferId, sha256: "00"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.bin").path))
        guard case .failed = files.transfers.first?.state else { return XCTFail("expected failure") }
    }

    func testUploadWaitsForReadyThenStreams() throws {
        let local = dir.appendingPathComponent("up.txt")
        try Data("hello".utf8).write(to: local)
        files.upload([local], into: "Download")
        let req = try XCTUnwrap(link.bodies(MsgType.fsUpload, as: FsUpload.self).last)
        XCTAssertEqual(req.dir, "Download")
        XCTAssertEqual(req.name, "up.txt")
        XCTAssertEqual(req.size, 5)
        XCTAssertTrue(link.binary.isEmpty)
        deliver(MsgType.fsUploadReady, FsUploadReady(transferId: req.transferId, finalName: "up (1).txt"))
        XCTAssertEqual(link.binary.count, 1)
        XCTAssertEqual(link.bodies(MsgType.fsEnd, as: FsEnd.self).map(\.sha256), [sha(Data("hello".utf8))])
        deliver(MsgType.fileAck, FileAck(transferId: req.transferId, received: 1))
        deliver(MsgType.fsDone, FsDone(transferId: req.transferId, ok: true, error: nil))
        XCTAssertEqual(files.transfers.first?.state, .done)
        XCTAssertEqual(files.transfers.first?.name, "up (1).txt")
    }

    func testUploadOfFolderKeepsStructureAndSkipsDotfiles() throws {
        let folder = dir.appendingPathComponent("Trip")
        let day1 = folder.appendingPathComponent("Day1")
        try FileManager.default.createDirectory(at: day1, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("Day1/a.jpg"))
        try Data([1]).write(to: folder.appendingPathComponent(".DS_Store"))
        files.upload([folder], into: "Pictures")
        let req = try XCTUnwrap(link.bodies(MsgType.fsUpload, as: FsUpload.self).first)
        XCTAssertEqual(req.dir, "Pictures/Trip/Day1")
        XCTAssertEqual(files.transfers.count, 1)
    }

    func testCancelSendsCancelAndDeletesPartial() throws {
        files.download(["a.bin", "b.bin"], to: dir)
        let req = try XCTUnwrap(link.bodies(MsgType.fsDownload, as: FsDownload.self).last)
        deliver(MsgType.fsBegin, FsBegin(transferId: req.transferId, size: 10, name: "a.bin"))
        files.handleBinary(ChunkFrame.encode(try XCTUnwrap(UUID(uuidString: req.transferId)), Data([1])))
        files.cancel(try XCTUnwrap(files.transfers.first?.id))
        XCTAssertEqual(link.bodies(MsgType.fsCancel, as: FsCancel.self).map(\.transferId), [req.transferId])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.bin").path))
        XCTAssertEqual(files.transfers.map(\.state), [.cancelled, .running])
    }

    func testDisconnectFailsActiveAndQueued() throws {
        files.download(["a.bin", "b.bin"], to: dir)
        let req = try XCTUnwrap(link.bodies(MsgType.fsDownload, as: FsDownload.self).last)
        deliver(MsgType.fsBegin, FsBegin(transferId: req.transferId, size: 10, name: "a.bin"))
        link.isConnected = false
        files.disconnected()
        XCTAssertEqual(files.transfers.map(\.state), [.failed("Phone disconnected"), .failed("Phone disconnected")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.bin").path))
        XCTAssertNil(files.allFilesAccess)
    }

    func testStrayAckIgnored() {
        deliver(MsgType.fileAck, FileAck(transferId: UUID().uuidString, received: 3))
        files.handleBinary(ChunkFrame.encode(UUID(), Data([1])))
        XCTAssertTrue(files.transfers.isEmpty)
    }

    func testZeroByteDownload() throws {
        files.download(["empty.txt"], to: dir)
        try serveDownload(Data(), name: "empty.txt")
        XCTAssertEqual(files.transfers.first?.state, .done)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("empty.txt")), Data())
    }

    func testFinderStyleUniqueName() throws {
        try Data().write(to: dir.appendingPathComponent("photo.jpg"))
        try Data().write(to: dir.appendingPathComponent("photo 2.jpg"))
        try Data().write(to: dir.appendingPathComponent("README"))
        XCTAssertEqual(finderStyleUniqueURL(in: dir, name: "photo.jpg").lastPathComponent, "photo 3.jpg")
        XCTAssertEqual(finderStyleUniqueURL(in: dir, name: "README").lastPathComponent, "README 2")
        XCTAssertEqual(finderStyleUniqueURL(in: dir, name: "new.txt").lastPathComponent, "new.txt")
    }

    func testOpenInDefaultAppDownloadsToTempThenOpens() throws {
        files.openInDefaultApp("Pictures/a.jpg")
        try serveDownload(Data([1]), name: "a.jpg")
        XCTAssertEqual(opened.map(\.lastPathComponent), ["a.jpg"])
    }

    func testDeleteReportsFailures() async throws {
        let task = Task { await files.delete(["a", "b"]) }
        await Task.yield()
        let req = try XCTUnwrap(link.bodies(MsgType.fsDelete, as: FsDelete.self).last)
        XCTAssertEqual(req.paths, ["a", "b"])
        let failure = FsDeleteFailure(path: "b", error: "Not found")
        deliver(MsgType.fsDeleted, FsDeleted(requestId: req.requestId, failed: [failure]))
        let failed = await task.value
        XCTAssertEqual(failed, [FsDeleteFailure(path: "b", error: "Not found")])
    }

    func testNoStatusMeansOldPhone() {
        XCTAssertNil(files.allFilesAccess)
        deliver(MsgType.fsStatus, FsStatus(allFilesAccess: true))
        XCTAssertEqual(files.allFilesAccess, true)
    }

    func testViewModeRememberedPerFolder() {
        XCTAssertEqual(files.viewMode(for: "Pictures"), .list)
        files.setViewMode(.icons, for: "Pictures")
        XCTAssertEqual(files.viewMode(for: "Pictures"), .icons)
        XCTAssertEqual(files.viewMode(for: "Download"), .list)
    }

    func testFailedDownloadTellsWaiter() throws {
        var results: [URL?] = []
        files.download(["a.bin"], to: dir, then: { results.append($0) })
        let req = try XCTUnwrap(link.bodies(MsgType.fsDownload, as: FsDownload.self).last)
        deliver(MsgType.fsDone, FsDone(transferId: req.transferId, ok: false, error: "Not found"))
        XCTAssertEqual(results, [nil])
    }

    func testDisconnectTellsQueuedWaiters() {
        var results: [URL?] = []
        files.download(["a.bin", "b.bin"], to: dir, then: { results.append($0) })
        files.disconnected()
        XCTAssertEqual(results, [nil, nil])
    }

    func testUnreadableUploadFailsAndContinues() throws {
        let gone = dir.appendingPathComponent("gone.txt")
        let next = dir.appendingPathComponent("next.txt")
        try Data([1]).write(to: gone)
        try Data([2]).write(to: next)
        files.upload([gone, next], into: "Download")
        let req = try XCTUnwrap(link.bodies(MsgType.fsUpload, as: FsUpload.self).last)
        try FileManager.default.removeItem(at: gone)
        deliver(MsgType.fsUploadReady, FsUploadReady(transferId: req.transferId, finalName: "gone.txt"))
        guard case .failed = files.transfers.first?.state else { return XCTFail("expected failure") }
        XCTAssertEqual(link.bodies(MsgType.fsCancel, as: FsCancel.self).map(\.transferId), [req.transferId])
        XCTAssertEqual(files.transfers.last?.state, .running)
    }

    func testMacSideDownloadFailureTellsPhone() throws {
        files.download(["a.bin"], to: dir.appendingPathComponent("does/not/exist"))
        let req = try XCTUnwrap(link.bodies(MsgType.fsDownload, as: FsDownload.self).last)
        deliver(MsgType.fsBegin, FsBegin(transferId: req.transferId, size: 1, name: "a.bin"))
        guard case .failed = files.transfers.first?.state else { return XCTFail("expected failure") }
        XCTAssertEqual(link.bodies(MsgType.fsCancel, as: FsCancel.self).map(\.transferId), [req.transferId])
    }
}
