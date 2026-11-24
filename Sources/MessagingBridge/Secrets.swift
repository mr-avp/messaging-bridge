import Foundation
import Security

struct Secrets {
    static let service = "local.messaging-bridge"
    private static let storage = TokenStorage(keychain: KeychainTokenStore(), legacy: LegacyTokenStore())

    static func save(_ value: String) throws { try storage.save(value) }
    static func read() -> String { storage.read() }
    static func delete() { try? deleteChecked() }
    static func deleteChecked() throws { try storage.delete() }
}

protocol LegacyTokenStorage {
    func read() throws -> String?
    func delete() throws
}

protocol TokenStore: LegacyTokenStorage {
    func save(_ value: String) throws
}

final class TokenStorage {
    private let keychain: any TokenStore
    private let legacy: any LegacyTokenStorage
    private let lock = NSLock()

    init(keychain: any TokenStore, legacy: any LegacyTokenStorage) {
        self.keychain = keychain
        self.legacy = legacy
    }

    func read() -> String {
        lock.withLock {
            do {
                if let value = try keychain.read() { return value }
                guard let value = try legacy.read(), !value.isEmpty else { return "" }
                // Keep the old value usable and retry migration on a later read if the write fails.
                if (try? keychain.save(value)) != nil {
                    try? legacy.delete()
                }
                return value
            } catch {
                return ""
            }
        }
    }

    func save(_ value: String) throws {
        try lock.withLock {
            try keychain.save(value)
            try legacy.delete()
        }
    }

    func delete() throws {
        try lock.withLock {
            // Clear the migration sources so a later read cannot restore the deleted token.
            try legacy.delete()
            try keychain.delete()
        }
    }
}

private struct KeychainTokenStore: TokenStore {
    private var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Secrets.service,
            kSecAttrAccount as String: "telegram-token"
        ]
    }

    func read() throws -> String? {
        var query = item
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw RelayError.storage }
        return value
    }

    func save(_ value: String) throws {
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let newItem = item.merging(attributes) { _, newValue in newValue }
        let status = SecItemAdd(newItem as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(item as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                throw RelayError.storage
            }
        } else if status != errSecSuccess {
            throw RelayError.storage
        }
    }

    func delete() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RelayError.storage }
    }
}

private struct LegacyTokenStore: LegacyTokenStorage {
    private let tokenKey = "local.messaging-bridge.telegram-token"
    private let legacyTokenKey = "local.family-relay.telegram-token"
    private let legacyDomain = "local.family-relay"

    func read() throws -> String? {
        let defaults = UserDefaults.standard
        // The named persistent domain is backed by local.family-relay.plist on macOS.
        let values = [
            defaults.string(forKey: tokenKey),
            defaults.string(forKey: legacyTokenKey),
            defaults.persistentDomain(forName: legacyDomain)?[legacyTokenKey] as? String
        ]
        return values.compactMap { $0 }.first { !$0.isEmpty }
    }

    func delete() throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: tokenKey)
        defaults.removeObject(forKey: legacyTokenKey)
        guard let legacyDefaults = UserDefaults(suiteName: legacyDomain) else { throw RelayError.storage }
        legacyDefaults.removeObject(forKey: legacyTokenKey)
    }
}

enum RelayError: Error { case storage, network, api, uncertain, configuration }
