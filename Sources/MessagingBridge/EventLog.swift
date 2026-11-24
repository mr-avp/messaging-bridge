import Foundation

@MainActor
final class EventLog: ObservableObject {
    enum Level: String, Codable, CaseIterable {
        case debug
        case info
        case warning
        case error
    }

    enum RecoveryErrorCategory: String, Codable, CaseIterable {
        case temporary
        case permanent
        case configuration
        case network
        case authentication
        case rateLimit
        case unknown
    }

    enum Event: Codable, Equatable, Hashable {
        case appStart
        case appQuit
        case bridgeStart
        case bridgeStop
        case bridgeStopManual
        case maxConnect
        case maxDisconnect
        case telegramConnect
        case telegramDisconnect
        case recoveryAttempt
        case recoverySuccess
        case recoveryBlocked
        case recoveryError(RecoveryErrorCategory)

        var recoveryCategory: RecoveryErrorCategory? {
            switch self {
            case .recoveryError(let category): return category
            default: return nil
            }
        }

        var displayText: String {
            switch self {
            case .appStart: return "Запуск приложения"
            case .appQuit: return "Завершение приложения"
            case .bridgeStart: return "Запуск моста"
            case .bridgeStop: return "Остановка моста"
            case .bridgeStopManual: return "Ручная остановка моста"
            case .maxConnect: return "MAX подключён"
            case .maxDisconnect: return "MAX отключён"
            case .telegramConnect: return "Telegram подключён"
            case .telegramDisconnect: return "Telegram отключён"
            case .recoveryAttempt: return "Попытка восстановления"
            case .recoverySuccess: return "Восстановление успешно"
            case .recoveryBlocked: return "Восстановление заблокировано"
            case .recoveryError(let category): return "Ошибка восстановления: \(category.rawValue)"
            }
        }

        private var caseName: String {
            switch self {
            case .appStart: return "appStart"
            case .appQuit: return "appQuit"
            case .bridgeStart: return "bridgeStart"
            case .bridgeStop: return "bridgeStop"
            case .bridgeStopManual: return "bridgeStopManual"
            case .maxConnect: return "maxConnect"
            case .maxDisconnect: return "maxDisconnect"
            case .telegramConnect: return "telegramConnect"
            case .telegramDisconnect: return "telegramDisconnect"
            case .recoveryAttempt: return "recoveryAttempt"
            case .recoverySuccess: return "recoverySuccess"
            case .recoveryBlocked: return "recoveryBlocked"
            case .recoveryError: return "recoveryError"
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .recoveryError(let category):
                try container.encode("recoveryError.\(category.rawValue)")
            default:
                try container.encode(caseName)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if raw.hasPrefix("recoveryError.") {
                let categoryRaw = String(raw.dropFirst("recoveryError.".count))
                let category = RecoveryErrorCategory(rawValue: categoryRaw) ?? .unknown
                self = .recoveryError(category)
                return
            }
            switch raw {
            case "appStart": self = .appStart
            case "appQuit": self = .appQuit
            case "bridgeStart": self = .bridgeStart
            case "bridgeStop": self = .bridgeStop
            case "bridgeStopManual": self = .bridgeStopManual
            case "maxConnect": self = .maxConnect
            case "maxDisconnect": self = .maxDisconnect
            case "telegramConnect": self = .telegramConnect
            case "telegramDisconnect": self = .telegramDisconnect
            case "recoveryAttempt": self = .recoveryAttempt
            case "recoverySuccess": self = .recoverySuccess
            case "recoveryBlocked": self = .recoveryBlocked
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown event: \(raw)")
            }
        }
    }

    struct Entry: Identifiable, Codable, Equatable {
        let id: UUID
        let timestamp: Date
        let level: Level
        let event: Event
        let category: RecoveryErrorCategory?

        init(id: UUID = UUID(), timestamp: Date = Date(), level: Level = .info, event: Event, category: RecoveryErrorCategory? = nil) {
            self.id = id
            self.timestamp = timestamp
            self.level = level
            self.event = event
            self.category = category ?? event.recoveryCategory
        }
    }

    @Published private(set) var entries: [Entry] = []

    let fileURL: URL
    private let maxEvents: Int
    private let maxBytes: Int
    private(set) var lastError: Error?

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var url: URL { fileURL }

    static let shared = EventLog()

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MessagingBridge", isDirectory: true)
        return dir.appendingPathComponent("events.jsonl")
    }

    init(fileURL: URL? = nil, maxEvents: Int = 500, maxBytes: Int = 1_048_576) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.maxEvents = max(1, maxEvents)
        self.maxBytes = max(256, maxBytes)
        load()
    }

    convenience init(url: URL, maxEvents: Int = 500, maxBytes: Int = 1_048_576) {
        self.init(fileURL: url, maxEvents: maxEvents, maxBytes: maxBytes)
    }

    convenience init(path: String, maxEvents: Int = 500, maxBytes: Int = 1_048_576) {
        self.init(fileURL: URL(fileURLWithPath: path), maxEvents: maxEvents, maxBytes: maxBytes)
    }

    convenience init(fileURL: URL? = nil, maxCount: Int, maxFileSize: Int) {
        self.init(fileURL: fileURL, maxEvents: maxCount, maxBytes: maxFileSize)
    }

    convenience init(url: URL, maxCount: Int, maxFileSize: Int) {
        self.init(fileURL: url, maxEvents: maxCount, maxBytes: maxFileSize)
    }

    convenience init(path: String, maxCount: Int, maxFileSize: Int) {
        self.init(fileURL: URL(fileURLWithPath: path), maxEvents: maxCount, maxBytes: maxFileSize)
    }

    func record(_ event: Event, level: Level = .info, category: RecoveryErrorCategory? = nil, timestamp: Date = Date()) {
        let resolvedCategory = category ?? event.recoveryCategory
        insert(Entry(timestamp: timestamp, level: level, event: event, category: resolvedCategory))
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
        lastError = nil
    }

    private func insert(_ entry: Entry) {
        entries.append(entry)
        trim()
        persist()
    }

    private func trim() {
        if entries.count > maxEvents {
            entries.removeFirst(entries.count - maxEvents)
        }
        var encoded = encodeEntries(entries)
        while encoded.count > maxBytes && entries.count > 1 {
            entries.removeFirst()
            encoded = encodeEntries(entries)
        }
    }

    private func encodeEntries(_ entries: [Entry]) -> Data {
        let lines = entries.compactMap { entry -> String? in
            guard let data = try? JSONEncoder().encode(entry),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
        let joined = lines.joined(separator: "\n")
        return Data((joined + (joined.isEmpty ? "" : "\n")).utf8)
    }

    private func persist() {
        do { try write() } catch { lastError = error }
    }

    private func write() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = encodeEntries(entries)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        lastError = nil
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let data: Data
            if fileSize <= maxBytes {
                data = try Data(contentsOf: fileURL)
            } else {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(max(0, fileSize - maxBytes)))
                data = handle.readDataToEndOfFile()
            }
            let decoder = JSONDecoder()
            if let array = try? decoder.decode([Entry].self, from: data) {
                entries = array
                trim()
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(whereSeparator: \.isNewline) {
                if let lineData = String(line).data(using: .utf8),
                   let entry = try? decoder.decode(Entry.self, from: lineData) {
                    entries.append(entry)
                }
            }
            trim()
        } catch {
            lastError = error
        }
    }
}
