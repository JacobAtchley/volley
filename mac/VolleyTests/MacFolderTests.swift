import XCTest
@testable import Volley

@MainActor
final class MacFolderTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let zdir = root.appendingPathComponent("zdir")
        try FileManager.default.createDirectory(at: zdir, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: root.appendingPathComponent("b.txt"))
        try Data([1]).write(to: root.appendingPathComponent("A.txt"))
        try Data([1]).write(to: root.appendingPathComponent(".hidden"))
        defaults = scratchDefaults()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testListsDirsFirstSkippingHidden() {
        let folder = MacFolder(defaults: defaults, start: root)
        XCTAssertEqual(folder.entries.map(\.name), ["zdir", "A.txt", "b.txt"])
        XCTAssertEqual(folder.entries.first { $0.name == "b.txt" }?.size, 2)
        XCTAssertTrue(folder.entries.first?.isDir == true)
    }

    func testBackForward() {
        let folder = MacFolder(defaults: defaults, start: root)
        folder.open(root.appendingPathComponent("zdir"))
        XCTAssertEqual(folder.url.lastPathComponent, "zdir")
        folder.back()
        XCTAssertEqual(folder.url, root)
        XCTAssertTrue(folder.canGoForward)
        folder.forward()
        XCTAssertEqual(folder.url.lastPathComponent, "zdir")
    }

    func testRemembersLastFolder() {
        MacFolder(defaults: defaults, start: root).open(root.appendingPathComponent("zdir"))
        XCTAssertEqual(MacFolder(defaults: defaults).url.lastPathComponent, "zdir")
    }

    func testDefaultsToDownloads() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(MacFolder(defaults: defaults).url.standardizedFileURL, downloads.standardizedFileURL)
    }

    func testRefreshPicksUpNewFiles() throws {
        let folder = MacFolder(defaults: defaults, start: root)
        try Data([1]).write(to: root.appendingPathComponent("new.txt"))
        folder.refresh()
        XCTAssertTrue(folder.entries.contains { $0.name == "new.txt" })
    }

    func testSortByDateNewestFirstIsRemembered() throws {
        let old = root.appendingPathComponent("A.txt")
        let longAgo: [FileAttributeKey: Any] = [.modificationDate: Date(timeIntervalSince1970: 1)]
        try FileManager.default.setAttributes(longAgo, ofItemAtPath: old.path)
        let folder = MacFolder(defaults: defaults, start: root)
        folder.sort = SortChoice(key: .date, ascending: false)
        XCTAssertEqual(folder.entries.map(\.name), ["zdir", "b.txt", "A.txt"])
        XCTAssertEqual(MacFolder(defaults: defaults, start: root).sort, SortChoice(key: .date, ascending: false))
    }
}
