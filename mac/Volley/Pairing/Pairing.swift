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

/// Tokens live in the Keychain; the non-secret device list (id + name) in UserDefaults.
final class KeychainTrustStore: TrustStore {
    private let service = "app.volley.mac.devices"
    private let indexKey = "pairedDevices"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [PairedDevice] {
        let raw = defaults.dictionary(forKey: indexKey) as? [String: String] ?? [:]
        return raw.map { PairedDevice(id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    func verify(deviceId: String, token: String) -> PairedDevice? {
        guard let stored = readToken(deviceId), Secure.equals(stored, token) else { return nil }
        return all().first { $0.id == deviceId }
    }

    func save(_ device: PairedDevice, token: String) {
        deleteToken(device.id)
        var q = query(device.id)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)

        var raw = defaults.dictionary(forKey: indexKey) as? [String: String] ?? [:]
        raw[device.id] = device.name
        defaults.set(raw, forKey: indexKey)
    }

    func remove(deviceId: String) {
        deleteToken(deviceId)
        var raw = defaults.dictionary(forKey: indexKey) as? [String: String] ?? [:]
        raw[deviceId] = nil
        defaults.set(raw, forKey: indexKey)
    }

    private func readToken(_ deviceId: String) -> String? {
        var q = query(deviceId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteToken(_ deviceId: String) {
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
