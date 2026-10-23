import XCTest
@testable import Volley

final class SandboxMigrationTests: XCTestCase {
    private var home: URL!
    private var defaults: UserDefaults!
    private let bundleId = "app.volley.test"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = scratchDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var container: URL { home.appendingPathComponent("Library/Containers/\(bundleId)/Data/Library") }
    private var oldDb: URL { container.appendingPathComponent("Application Support/Volley/volley.sqlite") }
    private var newDb: URL { home.appendingPathComponent("Library/Application Support/Volley/volley.sqlite") }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func writeOldPrefs(_ dict: [String: Any]) throws {
        let url = container.appendingPathComponent("Preferences/\(bundleId).plist")
        try write(try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0), to: url)
    }

    private func migrate() { SandboxMigration.run(home: home, bundleId: bundleId, defaults: defaults) }

    func testCopiesDatabaseWhenMissing() throws {
        try write(Data([1, 2]), to: oldDb)
        migrate()
        XCTAssertEqual(try Data(contentsOf: newDb), Data([1, 2]))
    }

    func testDoesNotOverwriteExistingDatabase() throws {
        try write(Data([1]), to: oldDb)
        try write(Data([9]), to: newDb)
        migrate()
        XCTAssertEqual(try Data(contentsOf: newDb), Data([9]))
    }

    func testImportsMissingDefaultsOnly() throws {
        try writeOldPrefs(["pairedTokenHashes": ["d1": "abc"], "macId": "old-mac"])
        defaults.set("new-mac", forKey: "macId")
        migrate()
        XCTAssertEqual(defaults.dictionary(forKey: "pairedTokenHashes") as? [String: String], ["d1": "abc"])
        XCTAssertEqual(defaults.string(forKey: "macId"), "new-mac")
    }

    func testRunsOnce() throws {
        migrate()
        try writeOldPrefs(["late": "value"])
        migrate()
        XCTAssertNil(defaults.string(forKey: "late"))
    }

    func testNoContainerIsANoOp() {
        migrate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDb.path))
        XCTAssertTrue(defaults.bool(forKey: "sandboxMigrated"))
    }
}
