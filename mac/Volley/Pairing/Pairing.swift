import CryptoKit
import Foundation
import Security

struct PairedDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Paired phones and their tokens.
protocol TrustStore {
    func all() -> [PairedDevice]
    func verify(deviceId: String, token: String) -> PairedDevice?
    func save(_ device: PairedDevice, token: String)
    func remove(deviceId: String)
}

/// Stores only a SHA-256 hash of each phone's token, in the app's sandboxed defaults, plus the
/// non-secret device list (id + name). The Mac only ever checks a presented token, so it never needs
/// the token back, and nothing here can trigger a Keychain prompt.
final class HashedTrustStore: TrustStore {
    private let indexKey = "pairedDevices"
    private let hashesKey = "pairedTokenHashes"
    private let defaults: UserDefaults
    private let legacy: LegacyTokenSource?
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, legacy: LegacyTokenSource? = nil) {
        self.defaults = defaults
        self.legacy = legacy
    }

    func all() -> [PairedDevice] {
        index.map { PairedDevice(id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    func verify(deviceId: String, token: String) -> PairedDevice? {
        guard let stored = hashes[deviceId], Secure.equals(stored, Self.hash(token)) else { return nil }
        return all().first { $0.id == deviceId }
    }

    func save(_ device: PairedDevice, token: String) {
        lock.withLock {
            var i = index, h = hashes
            i[device.id] = device.name
            h[device.id] = Self.hash(token)
            defaults.set(i, forKey: indexKey)
            defaults.set(h, forKey: hashesKey)
        }
        legacy?.delete(deviceId: device.id)
    }

    func remove(deviceId: String) {
        lock.withLock {
            var i = index, h = hashes
            i[deviceId] = nil
            h[deviceId] = nil
            defaults.set(i, forKey: indexKey)
            defaults.set(h, forKey: hashesKey)
        }
        legacy?.delete(deviceId: deviceId)
    }

    /// Moves tokens saved by older builds out of the Keychain. Reading them may show a Keychain prompt,
    /// so call this off the main thread; until it finishes those phones just retry.
    func migrateLegacyTokens() {
        guard let legacy else { return }
        let pending = lock.withLock { index.keys.filter { hashes[$0] == nil } }
        for deviceId in pending {
            guard let token = legacy.token(for: deviceId) else { continue }
            lock.withLock {
                var h = hashes
                h[deviceId] = Self.hash(token)
                defaults.set(h, forKey: hashesKey)
            }
            legacy.delete(deviceId: deviceId)
        }
    }

    private var index: [String: String] { defaults.dictionary(forKey: indexKey) as? [String: String] ?? [:] }
    private var hashes: [String: String] { defaults.dictionary(forKey: hashesKey) as? [String: String] ?? [:] }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Where builds before the hashed store kept tokens.
protocol LegacyTokenSource {
    func token(for deviceId: String) -> String?
    func delete(deviceId: String)
}

struct KeychainLegacyTokens: LegacyTokenSource {
    private let service = "app.volley.mac.devices"

    func token(for deviceId: String) -> String? {
        var q = query(deviceId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(deviceId: String) {
        SecItemDelete(query(deviceId) as CFDictionary)
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// One-time 6-digit pairing code: expires after 5 minutes or 5 wrong attempts.
@MainActor
final class PairingCodes {
    private(set) var current: String?
    private var expiresAt = Date.distantPast
    private var attempts = 0

    func generate() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        current = code
        expiresAt = Date().addingTimeInterval(300)
        attempts = 0
        return code
    }

    func consume(_ candidate: String) -> Bool {
        guard let code = current, Date() < expiresAt else { clear(); return false }
        attempts += 1
        if Secure.equals(code, candidate) { clear(); return true }
        if attempts >= 5 { clear() }
        return false
    }

    func clear() {
        current = nil
        expiresAt = .distantPast
    }
}

enum Secure {
    /// Constant-time comparison for equal-length secrets.
    static func equals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
