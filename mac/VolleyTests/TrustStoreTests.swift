import XCTest
@testable import Volley

final class TrustStoreTests: XCTestCase {
    private final class FakeLegacy: LegacyTokenSource {
        var tokens: [String: String] = [:]
        private(set) var deleted: [String] = []
        func token(for deviceId: String) -> String? { tokens[deviceId] }
        func delete(deviceId: String) { deleted.append(deviceId); tokens[deviceId] = nil }
    }

    private var defaults: UserDefaults!
    private var legacy: FakeLegacy!
    private var store: HashedTrustStore!
    private let pixel = PairedDevice(id: "d1", name: "Pixel")

    override func setUp() {
        defaults = UserDefaults(suiteName: UUID().uuidString)
        legacy = FakeLegacy()
        store = HashedTrustStore(defaults: defaults, legacy: legacy)
    }

    func testVerifiesTokenByHash() {
        store.save(pixel, token: "secret-token")
        XCTAssertEqual(store.verify(deviceId: "d1", token: "secret-token"), pixel)
        XCTAssertNil(store.verify(deviceId: "d1", token: "wrong"))
        XCTAssertNil(store.verify(deviceId: "d2", token: "secret-token"))
    }

    func testNeverStoresPlainToken() {
        store.save(pixel, token: "secret-token")
        let everything = "\(defaults.dictionaryRepresentation())"
        XCTAssertFalse(everything.contains("secret-token"))
    }

    func testMigratesLegacyKeychainToken() {
        // Paired by an older build: device in the index, token only in the Keychain.
        defaults.set(["d1": "Pixel"], forKey: "pairedDevices")
        legacy.tokens["d1"] = "old-token"
        XCTAssertNil(store.verify(deviceId: "d1", token: "old-token"), "verify never touches the Keychain")
        store.migrateLegacyTokens()
        XCTAssertEqual(store.verify(deviceId: "d1", token: "old-token"), pixel)
        XCTAssertEqual(legacy.deleted, ["d1"])
    }

    func testMigrationSkipsDevicesAlreadyHashed() {
        store.save(pixel, token: "new")
        legacy.tokens["d1"] = "stale"
        let deletedBefore = legacy.deleted
        store.migrateLegacyTokens()
        XCTAssertEqual(store.verify(deviceId: "d1", token: "new"), pixel)
        XCTAssertNil(store.verify(deviceId: "d1", token: "stale"))
        XCTAssertEqual(legacy.deleted, deletedBefore, "migration leaves already-hashed devices alone")
    }

    func testRemoveForgetsDevice() {
        store.save(pixel, token: "t")
        store.remove(deviceId: "d1")
        XCTAssertNil(store.verify(deviceId: "d1", token: "t"))
        XCTAssertTrue(store.all().isEmpty)
    }
}
