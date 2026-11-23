import Foundation

struct Secrets {
    static let service = "local.family-relay"
    private static let tokenKey = "local.family-relay.telegram-token"

    static func save(_ value: String) throws {
        UserDefaults.standard.set(value, forKey: tokenKey)
    }

    static func read() -> String {
        UserDefaults.standard.string(forKey: tokenKey) ?? ""
    }

    static func delete() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }
}

enum RelayError: Error { case storage, network, api, uncertain, configuration }
