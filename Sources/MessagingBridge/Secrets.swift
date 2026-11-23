import Foundation

struct Secrets {
    static let service = "local.messaging-bridge"
    private static let tokenKey = "local.messaging-bridge.telegram-token"
    private static let legacyTokenKey = "local.family-relay.telegram-token"
    private static let legacyDefaults = UserDefaults(suiteName: "local.family-relay")

    static func save(_ value: String) throws {
        UserDefaults.standard.set(value, forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: legacyTokenKey)
        legacyDefaults?.removeObject(forKey: legacyTokenKey)
    }

    static func read() -> String {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: tokenKey), !value.isEmpty { return value }
        if let legacy = defaults.string(forKey: legacyTokenKey), !legacy.isEmpty {
            defaults.set(legacy, forKey: tokenKey)
            defaults.removeObject(forKey: legacyTokenKey)
            return legacy
        }
        if let legacy = legacyDefaults?.string(forKey: legacyTokenKey), !legacy.isEmpty {
            defaults.set(legacy, forKey: tokenKey)
            legacyDefaults?.removeObject(forKey: legacyTokenKey)
            return legacy
        }
        let oldPlist = NSHomeDirectory() + "/Library/Preferences/local.family-relay.plist"
        if let dict = NSDictionary(contentsOfFile: oldPlist), let legacy = dict[legacyTokenKey] as? String, !legacy.isEmpty {
            defaults.set(legacy, forKey: tokenKey)
            return legacy
        }
        return ""
    }

    static func delete() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: legacyTokenKey)
        legacyDefaults?.removeObject(forKey: legacyTokenKey)
    }
}

enum RelayError: Error { case storage, network, api, uncertain, configuration }
