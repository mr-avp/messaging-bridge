import Foundation

enum AppSection: String, CaseIterable, Identifiable, Codable {
    case bridge = "bridge"
    case settings = "settings"
    case information = "information"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bridge: return "Мост"
        case .settings: return "Настройки"
        case .information: return "Информация"
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case connections = "connections"
    case automation = "automation"
    case telegram = "telegram"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .connections: return "Подключения"
        case .automation: return "Автоматизация"
        case .telegram: return "Telegram-бот"
        }
    }
}

enum InformationPane: String, CaseIterable, Identifiable {
    case about = "about"
    case journal = "journal"
    case developer = "developer"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .about: return "О программе"
        case .journal: return "Журнал"
        case .developer: return "Для разработчика"
        }
    }
}

enum AppMetadata {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "local.messaging-bridge"
    }
}

typealias AppVersion = AppMetadata
typealias BundleInfo = AppMetadata
typealias AppInfo = AppMetadata
typealias SettingsSection = AppSection
typealias MainSection = AppSection
typealias AppTab = AppSection
typealias SettingsTab = AppSection
