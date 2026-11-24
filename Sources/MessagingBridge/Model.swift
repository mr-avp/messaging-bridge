import SwiftUI
import AppKit

struct Group: Identifiable, Hashable { let id: String; let title: String }
struct BridgeConnection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var maxID: String
    var tgID: String
    var title: String
    var maxTitle: String?
    var tgTitle: String?
}
enum RelayMediaKind: String { case photo, video, file }
struct RelayMedia { let kind: RelayMediaKind; let url: String; let name: String?; let mime: String? }
struct RelayMessage { let id: String; let chat: String; let sender: String; let text: String; let media: [RelayMedia] }
@MainActor final class Model: ObservableObject {
    static let shared = Model()
    @Published var token = ""
    @Published var maxGroups: [Group] = []
    @Published var tgGroups: [Group] = []
    @Published var connections: [BridgeConnection] = []
    @Published var connectionID: UUID? = nil
    @Published var maxID = ""
    @Published var tgID = ""
    @Published var status = "Войдите в MAX и подключите Telegram-бота."
    @Published var running = false
    @Published var busy = false
    @Published var maxReady = false
    @Published var maxEvents = 0
    @Published var readyCount = 0
    @Published var readySocketGen = 0
    @Published var jsStart = 0
    @Published var jsSocket = 0
    @Published var jsAuth = 0
    @Published var jsHost = ""
    @Published var lastFrames = ""
    @Published var lastDebug = ""
    @Published var jsTitle = ""
    @Published var jsTextLen = 0
    @Published var jsVisibility = ""
    @Published var count = 0
    @Published var sessionRelayCount = 0
    @Published var lastSuccessfulRelayAt: Date? = nil
    @Published var autoStart = false
    @Published var autoRelay = false
    @Published var autoRecover = false
    @Published var recovering = false
    @Published var selectedSection: AppSection = .bridge
    @Published var maxPanelVisible: Bool = true
    @Published var settingsPane: SettingsPane = .connections
    @Published var informationPane: InformationPane = .about
    let eventLog: EventLog
    var autoRecovery: Bool { get { autoRecover } set { setAutoRecover(newValue) } }
    var isRecovering: Bool { recovering }
    var recoveryBackoff: RecoveryBackoff { RecoveryBackoff() }
    @Published var recoveryAttempt = 0
    let max: MaxWeb
    var telegram: Telegram?
    private let downloadSession = URLSession(configuration: .ephemeral)
    private var poll: Task<Void, Never>?
    private var deliver: Task<Void, Never>?
    private var queue: [RelayMessage] = []
    private var seen = Set<String>()
    private var runID = UUID()
    private var startupID: UUID?
    private var offset = 0
    private var didAutoStart = false
    private var userStopped = false
    private var recoveryBlocked = false
    private var terminating = false
    private var recoveryTask: Task<Void, Never>?
    /// The async "disable MAX relay" issued by stop(). start() awaits it before
    /// re-enabling so a late disable cannot land after our enable.
    private var disableTask: Task<Void, Never>?
    private var recoveryGeneration: Int = 0
    private var wakeObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard, eventLog: EventLog? = nil, max: MaxWeb? = nil) {
        self.defaults = defaults
        self.eventLog = eventLog ?? EventLog()
        self.max = max ?? MaxWeb()
        self.max.onMessage = { [weak self] data in
            self?.receive(data)
        }
        loadConnections()
        loadSettings()
        registerWakeObserver()
    }
    func openMAX() { max.load() }
    private func registerWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }
    func handleWake() {
        guard autoRecover, !userStopped, !recoveryBlocked else { return }
        // Real MAX reload with backoff; do not just wait for ready forever.
        maxReady = false
        max.load()
        if running {
            stop("MAX перезагружается после выхода из сна.", manual: false)
        }
        scheduleRecovery(reason: "выход из сна")
    }
    func receive(_ data: [String: Any]) {
        switch data["kind"] as? String {
        case "ready":
            let wasReady = maxReady
            maxReady = true
            readyCount += 1
            maxEvents += 1
            readySocketGen = jsSocket
            if !wasReady { eventLog.record(.maxConnect) }
            let raw = data["groups"] as? [[String: Any]] ?? []
            apply(groups: raw)
            status = raw.isEmpty
                ? "MAX подключён, но список групп пуст. Откройте нужный чат в MAX справа и нажмите «Обновить группы»."
                : "MAX подключён. Выберите группу-источник и оставьте её открытой справа."
            if running {
                // Every `ready` marks a freshly authenticated MAX JS world (new
                // socket or reloaded page), where the relay's `enabled`/`chat`
                // state can have been reset. Re-arm on each one, not only on a
                // false→true transition: if the `disconnected` event was missed
                // (page navigated away), maxReady stayed true and a stale-ready
                // would leave sends rejected as "offline" while the UI is green.
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.max.configure(chat: self.maxID, enabled: true)
                }
            }
            autoStartIfNeeded()
            if !running && autoRecover && !userStopped && !recoveryBlocked { scheduleRecovery(reason: "MAX готов") }
        case "groups":
            maxEvents += 1
            apply(groups: data["groups"] as? [[String: Any]] ?? [])
            if maxReady {
                status = maxGroups.isEmpty
                    ? "MAX подключён, но список групп пуст. Нажмите «Обновить группы»."
                    : "MAX подключён. Групп: \(maxGroups.count). Выберите группу-источник и оставьте чат открытым."
            }
        case "login-error":
            let wasReady = maxReady
            maxReady = false
            recoveryBlocked = true
            cancelRecovery()
            if wasReady { eventLog.record(.maxDisconnect) }
            eventLog.record(.recoveryBlocked, level: .warning)
            status = "MAX не принял вход (\(data["code"] ?? "?" )). Перезагрузите MAX и войдите заново."
        case "debug":
            let stage = data["stage"] as? String ?? "?"
            switch stage {
            case "start":
                jsStart += 1
                if let host = data["host"] as? String, !host.isEmpty { jsHost = host }
                lastDebug = "JS старт: \(jsHost)"
            case "ws":
                if let host = data["host"] as? String, !host.isEmpty { jsHost = host }
                if let count = data["count"] as? Int { jsSocket = count }
                lastDebug = "WebSocket: \(jsHost) (#\(jsSocket))"
            case "ws-skip":
                if let host = data["host"] as? String, !host.isEmpty { jsHost = host }
                lastDebug = "WebSocket пропущен: \(jsHost)"
            case "frame":
                if let opcode = data["opcode"] as? Int, let cmd = data["cmd"] as? Int {
                    let entry = "\(opcode):\(cmd)"
                    if lastFrames.isEmpty { lastFrames = entry } else { lastFrames = (lastFrames + ", " + entry).suffix(160).description }
                }
                if let opcode = data["opcode"] as? Int, let cmd = data["cmd"] as? Int, cmd == 1, opcode == 19 || opcode == 23 { jsAuth += 1 }
                lastDebug = "Кадр \(data["opcode"] ?? "?"):\(data["cmd"] ?? "?") \(data["type"] ?? "?") seq=\(data["seq"] ?? "?") len=\(data["len"] ?? 0) comp=\(data["comp"] ?? 0) err=\(data["error"] ?? false) groups=\(data["groups"] ?? 0)"
            case "finish":
                if let title = data["title"] as? String { jsTitle = title }
                if let n = data["textLen"] as? Int { jsTextLen = n }
                if let host = data["host"] as? String, !host.isEmpty { jsHost = host }
                if let visibility = data["visibility"] as? String { jsVisibility = visibility }
                if let n = data["ws"] as? Int { jsSocket = Swift.max(jsSocket, n) }
                lastDebug = "Загрузка: title=\(jsTitle), text=\(jsTextLen), ws=\(jsSocket), visibility=\(jsVisibility)"
            default:
                lastDebug = "\(stage): \(data)"
            }
            print("MessagingBridge MAX debug: \(lastDebug)")
        case "disconnected":
            let wasReady = maxReady
            maxReady = false
            if wasReady { eventLog.record(.maxDisconnect) }
            max.load()
            if autoRecover, !userStopped, !recoveryBlocked {
                stop("MAX отключился. Восстановление будет выполнено автоматически.", manual: false)
                scheduleRecovery(reason: "MAX отключился")
            } else {
                stop("MAX отключился. После восстановления соединения включите мост снова.", manual: false)
            }
        case "nav":
            let stage = data["stage"] as? String ?? "?"
            let info = data["error"] as? String ?? (data["url"] as? String ?? "")
            status = "MAX навигация: \(stage) \(info)"
            print("MessagingBridge MAX nav: \(stage) \(info)")
        case "message":
            guard running, let chat = data["chat"] as? String, let id = data["id"] as? String else { return }
            let text = (data["text"] as? String) ?? ""
            let sender = (data["sender"] as? String) ?? "Участник MAX"
            let media = ((data["media"] as? [[String: Any]]) ?? []).compactMap { item -> RelayMedia? in
                guard let kind = (item["kind"] as? String).flatMap(RelayMediaKind.init(rawValue:)),
                      let url = item["url"] as? String, !url.isEmpty else { return nil }
                return RelayMedia(kind: kind, url: url, name: item["name"] as? String, mime: item["mime"] as? String)
            }
            guard RelayPolicy.accept(chat: chat, allowed: maxID, text: text, hasMedia: !media.isEmpty),
                  seen.insert("max:\(id)").inserted else { return }
            let caption = RelayPolicy.render(author: sender, text: text)
            guard caption.utf16.count <= 4000 else { recoveryBlocked = true; eventLog.record(.recoveryBlocked, level: .warning); stop("Слишком длинное сообщение MAX. Мост остановлен.", manual: false); return }
            guard queue.count < 100, seen.count < 10000 else { recoveryBlocked = true; eventLog.record(.recoveryBlocked, level: .warning); stop("Очередь заполнена. Мост остановлен.", manual: false); return }
            queue.append(RelayMessage(id: id, chat: chat, sender: sender, text: text, media: media))
        default: break
        }
    }
    private func apply(groups raw: [[String: Any]]) {
        apply(groups: raw.compactMap { d -> Group? in
            guard let id = d["id"] as? String, let title = d["title"] as? String else { return nil }
            return Group(id: id, title: title)
        })
    }
    private func apply(groups: [Group]) {
        guard !groups.isEmpty else { return }
        var merged = Dictionary(uniqueKeysWithValues: maxGroups.map { ($0.id, $0) })
        for group in groups { merged[group.id] = group }
        maxGroups = merged.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if maxID.isEmpty {
            maxID = groups.first?.id ?? ""
        }
        updateConnectionTitles()
    }
    func refreshGroups() async {
        guard maxReady, !running, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let groups = try await max.refreshGroups()
            apply(groups: groups)
            status = groups.isEmpty ? "MAX не вернул группы. Откройте список чатов в MAX справа и повторите." : "Список групп MAX обновлён."
        } catch {
            status = "Не удалось обновить список групп MAX. Проверьте, что вход выполнен, и повторите."
        }
    }
    func connectTelegram() async {
        guard !running, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.range(of: #"^[0-9]+:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw RelayError.configuration }
            let api = Telegram(token: value)
            let me = try await api.call("getMe") as? [String: Any] ?? [:]
            let hook = try await api.call("getWebhookInfo") as? [String: Any] ?? [:]
            guard (hook["url"] as? String ?? "").isEmpty else {
                status = "У бота уже настроен другой сервис. Создайте отдельного бота для моста."; return
            }
            guard me["can_read_all_group_messages"] as? Bool == true else {
                status = "В BotFather отключите Group Privacy для этого бота, затем удалите и заново добавьте его в группу Telegram."; return
            }
            try Secrets.save(value)
            telegram = api
            token = ""
            status = "Бот подключён. Добавьте его в группу Telegram и отправьте там /family, затем нажмите «Найти группу»."
            eventLog.record(.telegramConnect)
        Task { await refreshSavedGroupTitles() }
        } catch let error as TelegramError {
            status = "Не удалось подключить бота: \(error.description). Токен и ответ API в лог не пишутся."
        } catch {
            status = "Не удалось подключить бота: \(String(describing: error)). Проверьте токен и доступ к api.telegram.org."
        }
    }
    func restoreToken() {
        let saved = Secrets.read()
        token = saved
        if saved.isEmpty {
            status = "Токен не найден в локальном хранилище. Вставьте токен и нажмите «Подключить бота»."
        }
    }
    func deleteToken() {
        guard !running, !busy else { return }
        if telegram != nil { eventLog.record(.telegramDisconnect) }
        Secrets.delete()
        telegram = nil
        token = ""
        status = "Токен удалён из локального хранилища. Вставьте новый токен и нажмите «Подключить бота»."
    }
    func restoreAndConnect() async {
        let saved = Secrets.read()
        guard !saved.isEmpty, telegram == nil, !running, !busy else { return }
        token = saved
        await connectTelegram()
        if telegram != nil { status = "Бот подключён автоматически из локального хранилища. \(status)"; await refreshSavedGroupTitles(); autoStartIfNeeded() }
    }
    func discover() async {
        guard !running, !busy, let api = telegram else { return }
        status = "Ищу группу. Сначала добавьте бота в группу Telegram и отправьте там /family."
        busy = true; defer { busy = false }
        do {
            let updates = try await api.updates(offset: offset, timeout: 0)
            var lastSeen = "нет обновлений"
            for update in updates {
                if let id = update["update_id"] as? Int { offset = maxInt(offset, id + 1) }
                guard let message = update["message"] as? [String: Any] else { continue }
                let text = message["text"] as? String ?? ""
                let chatType = (message["chat"] as? [String: Any])?["type"] as? String ?? "?"
                lastSeen = "«\(text)» в \(chatType)"
                guard text == "/family" || text.hasPrefix("/family@"),
                      let chat = message["chat"] as? [String: Any],
                      ["group", "supergroup"].contains(chat["type"] as? String ?? ""),
                      let id = chat["id"] as? NSNumber else { continue }
                let group = Group(id: id.stringValue, title: chat["title"] as? String ?? id.stringValue)
                if !tgGroups.contains(where: { $0.id == group.id }) { tgGroups.append(group) }
                if tgID.isEmpty { tgID = group.id }
            }
            updateConnectionTitles()
            if tgGroups.isEmpty {
                status = "Не вижу /family в группе. Проверено обновлений: \(updates.count). Последнее: \(lastSeen). Убедитесь, что бот добавлен в группу, privacy отключён, команда отправлена отдельным сообщением и токен не используется другим процессом."
            } else {
                status = "Выберите две группы и включите мост. Старая переписка переноситься не будет."
            }
        } catch { status = "Не удалось найти группу. Проверьте сеть и убедитесь, что бот не запущен в другом сервисе." }
    }
    private static func telegramName(_ from: [String: Any]) -> String {
        let first = from["first_name"] as? String ?? ""
        let last = from["last_name"] as? String ?? ""
        let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        let username = from["username"] as? String ?? ""
        return username.isEmpty ? "Участник Telegram" : "@\(username)"
    }
    private func downloadData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw RelayError.configuration }
        let (data, response) = try await downloadSession.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw RelayError.api }
        return data
    }
    private func loadSettings() {
        autoStart = defaults.bool(forKey: "messaging-bridge.auto-start")
        autoRelay = defaults.bool(forKey: "messaging-bridge.auto-relay")
        autoRecover = defaults.bool(forKey: "messaging-bridge.auto-recover")
    }
    func setAutoStart(
        _ enabled: Bool,
        launchAgentURL url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.messaging-bridge.plist"),
        executablePath: String? = Bundle.main.executablePath
    ) {
        do {
            if enabled {
                guard let executablePath, !executablePath.isEmpty else {
                    status = "Не удалось изменить автозапуск: путь к приложению пуст."
                    return
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "Label": "local.messaging-bridge",
                    "ProgramArguments": [executablePath],
                    "RunAtLoad": true,
                    "KeepAlive": ["SuccessfulExit": false],
                    "ThrottleInterval": 10
                ]
                try (plist as NSDictionary).write(to: url)
            } else {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                    // The agent is already absent.
                }
            }
            defaults.set(enabled, forKey: "messaging-bridge.auto-start")
            autoStart = enabled
        } catch {
            status = "Не удалось изменить автозапуск: \(error.localizedDescription)"
        }
    }
    func setAutoRelay(_ enabled: Bool) {
        autoRelay = enabled
        defaults.set(enabled, forKey: "messaging-bridge.auto-relay")
        if enabled { autoStartIfNeeded() }
    }
    func setAutoRecover(_ enabled: Bool) {
        autoRecover = enabled
        defaults.set(enabled, forKey: "messaging-bridge.auto-recover")
        recoveryBlocked = false
        if !enabled { cancelRecovery() }
        else if !running && !userStopped { scheduleRecovery(reason: "включено восстановление") }
    }
    func applyStartupSettings() {
        autoStartIfNeeded()
    }
    func autoStartIfNeeded() {
        guard autoRelay, !didAutoStart, !running, !busy, canStart, !userStopped, !recoveryBlocked, recoveryTask == nil, !recovering else { return }
        didAutoStart = true
        Task { await start() }
    }
    var hasTelegram: Bool { telegram != nil }
    func refreshSavedGroupTitles() async {
        guard let api = telegram else { return }
        var changed = false
        for index in connections.indices {
            let id = connections[index].tgID
            if connections[index].tgTitle != nil { continue }
            if let chat = try? await api.call("getChat", ["chat_id": id]) as? [String: Any],
               let title = chat["title"] as? String, !title.isEmpty {
                connections[index].tgTitle = title
                let maxTitle = connections[index].maxTitle ?? connections[index].maxID
                connections[index].title = "\(maxTitle) ↔ \(title)"
                changed = true
            }
        }
        if changed {
            persistConnections()
            if tgGroups.isEmpty || tgGroups.allSatisfy({ $0.id == $0.title }) {
                tgGroups = connections.map { Group(id: $0.tgID, title: $0.tgTitle ?? $0.tgID) }
            }
        }
    }
    var canSaveConnection: Bool { maxGroups.contains(where: { $0.id == maxID }) && tgGroups.contains(where: { $0.id == tgID }) }
    var canStart: Bool { telegram != nil && maxReady && maxGroups.contains(where: {$0.id == maxID}) && tgGroups.contains(where: {$0.id == tgID}) && !busy }
    /// Single funnel for Telegram → MAX text send paths (including split parts).
    /// Keeping it here lets the real model path be exercised with an injected
    /// MaxWeb mock instead of bypassing `start()` in tests.
    private func sendTextToMax(_ text: String) async throws {
        try await max.send(chat: maxID, text: text)
    }
    /// Why a click on Start cannot begin relaying yet. Returned instead of
    /// silently doing nothing so a temporary MAX disconnect explains the wait.
    var startBlockedReason: String? {
        if running { return nil }
        if busy { return "Мост уже запускается. Дождитесь завершения." }
        if telegram == nil { return "Telegram-бот не подключён. Вставьте токен и нажмите «Подключить бота»." }
        if !maxReady { return "MAX ещё не подключён. Войдите в MAX справа и дождитесь восстановления, затем нажмите «Запустить»." }
        if !maxGroups.contains(where: { $0.id == maxID }) { return "Выберите группу-источник MAX." }
        if !tgGroups.contains(where: { $0.id == tgID }) { return "Выберите группу Telegram." }
        return nil
    }
    func saveConnection() {
        guard canSaveConnection else { return }
        let maxTitle = maxGroups.first(where: { $0.id == maxID })?.title ?? maxID
        let tgTitle = tgGroups.first(where: { $0.id == tgID })?.title ?? tgID
        if let existing = connections.first(where: { $0.maxID == maxID && $0.tgID == tgID }) {
            connectionID = existing.id
            return
        }
        let connection = BridgeConnection(maxID: maxID, tgID: tgID, title: "\(maxTitle) ↔ \(tgTitle)", maxTitle: maxTitle, tgTitle: tgTitle)
        connections.append(connection)
        connectionID = connection.id
        persistConnections()
    }
    func selectConnection(_ id: UUID?) {
        guard !running, !busy else { return }
        connectionID = id
        guard let id, let connection = connections.first(where: { $0.id == id }) else { return }
        maxID = connection.maxID
        tgID = connection.tgID
    }
    func newConnection() {
        guard !running, !busy else { return }
        connectionID = nil
        maxID = ""
        tgID = ""
    }
    func deleteConnection() {
        guard !running, !busy, let id = connectionID else { return }
        connections.removeAll { $0.id == id }
        connectionID = nil
        persistConnections()
    }
    private func updateConnectionTitles() {
        var changed = false
        for index in connections.indices {
            if let group = maxGroups.first(where: { $0.id == connections[index].maxID }), connections[index].maxTitle != group.title {
                connections[index].maxTitle = group.title
                changed = true
            }
            if let group = tgGroups.first(where: { $0.id == connections[index].tgID }), connections[index].tgTitle != group.title {
                connections[index].tgTitle = group.title
                changed = true
            }
            let maxTitle = connections[index].maxTitle ?? connections[index].maxID
            let tgTitle = connections[index].tgTitle ?? connections[index].tgID
            let newTitle = "\(maxTitle) ↔ \(tgTitle)"
            if connections[index].title != newTitle {
                connections[index].title = newTitle
                changed = true
            }
        }
        if changed { persistConnections() }
    }
    private func persistConnections() {
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: "messaging-bridge.connections")
        }
    }
    private func loadConnections() {
        let isTest = NSClassFromString("XCTest") != nil
        let legacyDefaults = isTest ? nil : UserDefaults(suiteName: "local.family-relay")
        let oldPlist = NSHomeDirectory() + "/Library/Preferences/local.family-relay.plist"
        let plistConnections = isTest ? nil : (NSDictionary(contentsOfFile: oldPlist)?["family-relay.connections"] as? Data)
        let data = defaults.data(forKey: "messaging-bridge.connections")
            ?? (!isTest ? defaults.data(forKey: "family-relay.connections") : nil)
            ?? legacyDefaults?.data(forKey: "family-relay.connections")
            ?? plistConnections
        guard let data, let decoded = try? JSONDecoder().decode([BridgeConnection].self, from: data) else { return }
        if defaults.data(forKey: "messaging-bridge.connections") == nil {
            defaults.set(data, forKey: "messaging-bridge.connections")
            defaults.removeObject(forKey: "family-relay.connections")
        }
        connections = decoded
        if maxGroups.isEmpty {
            maxGroups = decoded.map { Group(id: $0.maxID, title: $0.maxTitle ?? $0.maxID) }
        }
        if tgGroups.isEmpty {
            tgGroups = decoded.map { Group(id: $0.tgID, title: $0.tgTitle ?? $0.tgID) }
        }
        if connectionID == nil, let first = decoded.first {
            connectionID = first.id
            maxID = first.maxID
            tgID = first.tgID
        }
        updateConnectionTitles()
    }
    func start(cancelRecovery: Bool = true) async {
        // A start initiated by the user (or by auto-start) clears the latch that
        // an earlier manual stop set. Recovery calls start(cancelRecovery:false)
        // and must keep respecting an explicit user stop.
        if cancelRecovery {
            userStopped = false
            recoveryBlocked = false
            self.cancelRecovery()
        }
        guard !userStopped, !recoveryBlocked else { return }
        guard !running else { return }
        guard !busy else { status = "Мост уже запускается. Дождитесь завершения."; return }
        if let reason = startBlockedReason { status = reason; return }
        guard canStart, let api = telegram else { return }
        let thisStartup = UUID()
        startupID = thisStartup
        busy = true
        defer {
            if startupID == thisStartup { busy = false }
        }
        do {
            sessionRelayCount = 0
            lastSuccessfulRelayAt = nil
            // Drop pre-existing updates. The first run never exports old conversations.
            let latest = try await api.updates(offset: -1, timeout: 0)
            guard startupID == thisStartup, !userStopped, !recoveryBlocked else { return }
            if let id = latest.last?["update_id"] as? Int { offset = id + 1 }
            // A manual stop dispatches an async disable of the MAX relay. Wait
            // for it before re-enabling, otherwise a slow disable can complete
            // after this enable and leave the relay off while the bridge is
            // shown as running (every send then rejects "offline").
            // Keep the reference: if a stop creates a newer disable task while
            // we are starting, that task stays tracked for the next start.
            if let pendingDisable = disableTask { await pendingDisable.value }
            try await max.configure(chat: maxID, enabled: true)
            guard startupID == thisStartup, !userStopped, !recoveryBlocked else { return }
            queue.removeAll(); seen.removeAll(); runID = UUID(); sessionRelayCount = 0; lastSuccessfulRelayAt = nil
            let current = runID
            let started = Int(Date().timeIntervalSince1970)
            running = true; status = "Мост работает. Оставьте выбранный чат MAX открытым справа; переносятся только новые тексты, фото, видео, GIF и документы."
            eventLog.record(.bridgeStart)
            poll = Task { [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled && self.running && self.runID == current {
                        let updates = try await api.updates(offset: self.offset)
                        guard self.running && self.runID == current else { return }
                        for update in updates {
                            guard self.running && self.runID == current else { return }
                            if let id = update["update_id"] as? Int { self.offset = maxInt(self.offset, id + 1) }
                            guard let m = update["message"] as? [String: Any], let c = m["chat"] as? [String: Any],
                                  let id = c["id"] as? NSNumber,
                                  (m["date"] as? Int ?? 0) >= started else { continue }
                            let text = (m["text"] as? String) ?? ""
                            let caption = (m["caption"] as? String) ?? ""
                            let content = text.isEmpty ? caption : text
                            guard content != "/family", !content.hasPrefix("/family@") else { continue }
                            let media = TelegramIncomingMedia.parse(m)
                            let sender = m["from"] as? [String: Any] ?? [:]
                            guard RelayPolicy.accept(chat: id.stringValue, allowed: self.tgID, text: content,
                                                     bot: sender["is_bot"] as? Bool ?? false,
                                                     hasMedia: media != nil) else { continue }
                            let renderedParts = RelayPolicy.plainParts(
                                author: Self.telegramName(sender),
                                text: content,
                                limit: media == nil ? TelegramLimits.messageUnits : TelegramLimits.captionUnits
                            )
                            let rendered = renderedParts.first ?? ""
                            if let media {
                                if let size = media.byteCount, !TelegramLimits.canDownload(byteCount: size) {
                                    self.status = "Вложение Telegram больше 20 МБ не скачано (ограничение Bot API). Передайте его вручную."
                                    if !content.isEmpty {
                                        for part in renderedParts { try await self.sendTextToMax(part) }
                                        self.count += 1; self.sessionRelayCount += 1; self.lastSuccessfulRelayAt = Date()
                                    }
                                    continue
                                }
                                do {
                                    let data = try await api.downloadFile(fileID: media.fileID)
                                    try await self.max.sendMedia(
                                        chat: self.maxID,
                                        kind: media.maxKind,
                                        data: data,
                                        text: rendered,
                                        fileName: media.fileName,
                                        mime: media.mimeType
                                    )
                                    for part in renderedParts.dropFirst() {
                                        try await self.sendTextToMax(part)
                                    }
                                } catch {
                                    if TelegramLimits.isTooBigDownload(error) {
                                        self.status = "Вложение Telegram больше 20 МБ не скачано (ограничение Bot API). Передайте его вручную."
                                        if !content.isEmpty {
                                            for part in renderedParts { try await self.sendTextToMax(part) }
                                            self.count += 1; self.sessionRelayCount += 1; self.lastSuccessfulRelayAt = Date()
                                        }
                                        continue
                                    }
                                    throw error
                                }
                            } else {
                                for part in renderedParts {
                                    try await self.sendTextToMax(part)
                                }
                            }
                            self.count += 1; self.sessionRelayCount += 1; self.lastSuccessfulRelayAt = Date()
                            try await Task.sleep(for: .milliseconds(350))
                        }
                    }
                } catch {
                    if self.runID == current {
                        let temporary = Model.isTemporaryError(error)
                        if temporary {
                            self.eventLog.record(.recoveryError(.temporary), level: .warning, category: .temporary)
                            self.stop("Передача остановлена из-за временной ошибки связи. Проверьте последнее сообщение перед повторным запуском: оно могло быть доставлено.", manual: false)
                            self.scheduleRecovery(reason: "временная ошибка связи")
                        } else {
                            self.recoveryBlocked = true
                            self.eventLog.record(.recoveryBlocked, level: .warning)
                            self.eventLog.record(.recoveryError(.permanent), level: .error, category: .permanent)
                            self.stop("Передача остановлена из-за ошибки связи. Проверьте последнее сообщение перед повторным запуском: оно могло быть доставлено.", manual: false)
                        }
                    }
                }
            }
            deliver = Task { [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled && self.running && self.runID == current {
                        if !self.queue.isEmpty {
                            let message = self.queue.removeFirst()
                            let parts = RelayPolicy.telegramParts(
                                author: message.sender,
                                text: message.text,
                                limit: message.media.isEmpty ? TelegramLimits.messageUnits : TelegramLimits.captionUnits
                            )
                            if message.media.isEmpty {
                                for part in parts {
                                    try await api.send(chat: self.tgID, text: part)
                                }
                            } else {
                                var captionSent = false
                                for (index, media) in message.media.enumerated() {
                                    let label = index == 0 ? (parts.first ?? "") : ""
                                    do {
                                        let kind = MediaInfo.telegramKind(
                                            for: media.kind,
                                            url: media.url,
                                            name: media.name,
                                            mime: media.mime
                                        )
                                        switch kind {
                                        case .photo, .video:
                                            try await api.sendMedia(chat: self.tgID, kind: kind, url: media.url, caption: label)
                                        case .animation:
                                            if media.kind == .file {
                                                let data = try await self.downloadData(from: media.url)
                                                guard TelegramLimits.canSend(kind: .animation, byteCount: data.count) else { throw RelayError.api }
                                                try await api.sendAnimation(
                                                    chat: self.tgID,
                                                    data: data,
                                                    fileName: media.name ?? "animation.gif",
                                                    mimeType: media.mime ?? MediaInfo.mimeType(fileName: media.name ?? "animation.gif"),
                                                    caption: label
                                                )
                                            } else {
                                                try await api.sendMedia(chat: self.tgID, kind: .animation, url: media.url, caption: label)
                                            }
                                        case .document:
                                            let data = try await self.downloadData(from: media.url)
                                            guard TelegramLimits.canSend(kind: .document, byteCount: data.count) else { throw RelayError.api }
                                            let name = media.name ?? "document"
                                            try await api.sendDocument(
                                                chat: self.tgID,
                                                data: data,
                                                fileName: name,
                                                mimeType: media.mime ?? MediaInfo.mimeType(fileName: name),
                                                caption: label
                                            )
                                        }
                                        if index == 0 { captionSent = true }
                                    } catch {
                                        try await api.send(chat: self.tgID, text: RelayPolicy.htmlEscape(media.url))
                                    }
                                }
                                let extra = captionSent ? Array(parts.dropFirst()) : parts
                                for part in extra {
                                    try await api.send(chat: self.tgID, text: part)
                                }
                            }
                            self.count += 1; self.sessionRelayCount += 1; self.lastSuccessfulRelayAt = Date()
                            try await Task.sleep(for: .milliseconds(350))
                        } else { try await Task.sleep(for: .milliseconds(200)) }
                    }
                } catch {
                    if self.runID == current {
                        let temporary = Model.isTemporaryError(error)
                        if temporary {
                            self.eventLog.record(.recoveryError(.temporary), level: .warning, category: .temporary)
                            self.stop("Передача остановлена из-за временной ошибки связи. Проверьте последнее сообщение перед повторным запуском: оно могло быть доставлено.", manual: false)
                            self.scheduleRecovery(reason: "временная ошибка связи")
                        } else {
                            self.recoveryBlocked = true
                            self.eventLog.record(.recoveryBlocked, level: .warning)
                            self.eventLog.record(.recoveryError(.permanent), level: .error, category: .permanent)
                            self.stop("Передача остановлена из-за ошибки связи. Проверьте последнее сообщение перед повторным запуском: оно могло быть доставлено.", manual: false)
                        }
                    }
                }
            }
        } catch {
            guard startupID == thisStartup else { return }
            startupID = nil
            busy = false
            let temporary = Model.isTemporaryError(error)
            if temporary {
                eventLog.record(.recoveryError(.temporary), level: .warning, category: .temporary)
                stop("Не удалось запустить мост из-за временной ошибки связи. Повтор будет выполнен автоматически.", manual: false)
                scheduleRecovery(reason: "временная ошибка запуска")
            } else {
                recoveryBlocked = true
                eventLog.record(.recoveryBlocked, level: .warning)
                eventLog.record(.recoveryError(.permanent), level: .error, category: .permanent)
                stop("Не удалось запустить мост. Проверьте вход в MAX и связь с Telegram.", manual: false)
            }
        }
    }

    func stop(_ reason: String = "Мост выключен.", manual: Bool = true) {
        running = false; busy = false; startupID = nil; runID = UUID(); poll?.cancel(); deliver?.cancel()
        if manual {
            userStopped = true
            cancelRecovery()
            if !terminating { eventLog.record(.bridgeStopManual, level: .info) }
        } else if !terminating {
            eventLog.record(.bridgeStop, level: .info)
        }
        // Internal stops preserve recovery attempt/backoff and do not cancel an active recovery owner.
        queue.removeAll(); status = reason
        disableTask = Task { [weak self] in
            guard let self else { return }
            try? await self.max.configure(chat: self.maxID, enabled: false)
        }
    }
    func stopByUser(_ reason: String = "Мост выключен.") {
        stop(reason, manual: true)
    }
    func cancelRecovery() {
        recoveryTask?.cancel(); recoveryTask = nil; recovering = false; recoveryAttempt = 0
        recoveryGeneration += 1
    }
    func scheduleRecovery(reason: String = "") {
        scheduleAutoRecovery(reason: reason)
    }
    func scheduleAutoRecovery(reason: String = "") {
        guard autoRecover, !userStopped, !recoveryBlocked, !running else { return }
        guard recoveryTask == nil else { return }
        recovering = true
        let generation = recoveryGeneration
        let startAttempt = recoveryAttempt
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            var attempt = startAttempt
            while !Task.isCancelled {
                let cont = await MainActor.run { () -> Bool in
                    guard self.recoveryGeneration == generation else { return false }
                    guard self.autoRecover, !self.userStopped, !self.recoveryBlocked, !self.running else { return false }
                    return true
                }
                guard cont else { break }
                if attempt > 0 {
                    let delay = RecoveryBackoff.delay(forAttempt: attempt)
                    await MainActor.run {
                        self.recovering = true
                        self.recoveryAttempt = attempt
                        self.status = "Восстановление моста: попытка \(attempt + 1), ожидание \(Int(delay)) с. \(reason)".trimmingCharacters(in: .whitespaces)
                    }
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                    if Task.isCancelled { return }
                    let cont2 = await MainActor.run { () -> Bool in
                        guard self.recoveryGeneration == generation else { return false }
                        guard self.autoRecover, !self.userStopped, !self.recoveryBlocked, !self.running else { return false }
                        return true
                    }
                    guard cont2 else { break }
                }
                attempt += 1
                await MainActor.run {
                    self.recovering = true
                    self.recoveryAttempt = attempt
                    self.eventLog.record(.recoveryAttempt, level: .info)
                }
                // Real MAX reload when not ready: reload page, then wait for ready with backoff.
                let needsReload = await MainActor.run { !self.maxReady }
                if needsReload {
                    await MainActor.run { self.max.load() }
                }
                // Try to restore Telegram if needed.
                await self.restoreAndConnectIfPossible()
                let can = await MainActor.run { self.canStart }
                if can {
                    await self.start(cancelRecovery: false)
                    let done = await MainActor.run { self.running }
                    if done {
                        await MainActor.run {
                            self.recovering = false
                            self.recoveryAttempt = 0
                            self.recoveryTask = nil
                            self.eventLog.record(.recoverySuccess, level: .info)
                        }
                        return
                    }
                }
                if Task.isCancelled { return }
            }
            await MainActor.run {
                if self.recoveryGeneration == generation {
                    self.recoveryTask = nil
                    self.recovering = false
                }
            }
        }
    }
    private func restoreAndConnectIfPossible() async {
        await restoreAndConnect()
    }
    func autoRecoverIfNeeded() {
        if !running && autoRecover && !userStopped && !recoveryBlocked { scheduleRecovery(reason: "готово к восстановлению") }
    }
    func prepareForTermination() {
        terminating = true
        userStopped = true
        cancelRecovery()
        stop("Приложение завершено.", manual: true)
    }
    static func recoveryBackoffDelay(forAttempt attempt: Int) -> TimeInterval { RecoveryBackoff.delay(forAttempt: attempt) }
    static func isTemporaryError(_ error: Error) -> Bool {
        if let tg = error as? TelegramError {
            if tg.code == 429 || tg.code == 408 { return true }
            if tg.code >= 500 { return true }
            if tg.code <= 0 { return true }
            return false
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return true }
        return false
    }
    func copyDiagnostics() {
        let text = """
        Статус: \(status)
        Telegram-бот: \(telegram == nil ? "не подключён" : "подключён")
        MAX: \(maxReady ? "подключён" : "нет"), событий: \(maxEvents), ready: \(readyCount), групп: \(maxGroups.count)
        Выбрано: MAX \(maxGroups.first(where: { $0.id == maxID })?.title ?? "—"), TG \(tgGroups.first(where: { $0.id == tgID })?.title ?? "—")
        JS: старт \(jsStart), сокет \(jsSocket), авторизация \(jsAuth)
        Хост сокета: \(jsHost.isEmpty ? "—" : jsHost)
        Страница: \(jsTitle.isEmpty ? "—" : jsTitle), текст \(jsTextLen), видимость \(jsVisibility.isEmpty ? "—" : jsVisibility)
        Кадры: \(lastFrames.isEmpty ? "—" : lastFrames)
        Отладка: \(lastDebug.isEmpty ? "—" : lastDebug)
        Перенесено: \(count)
        Восстановление: \(autoRecover ? "включено" : "выключено"), \(recovering ? "активно (попытка \(recoveryAttempt))" : "нет")
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clearEventLog() { eventLog.clear() }
    func copyEventLog() {
        let text = eventLog.entries.map { entry in
            let stamp = entry.timestamp.formatted(date: .numeric, time: .standard)
            return "\(stamp) [\(entry.level.rawValue)] \(entry.event.displayText)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
struct RecoveryBackoff {
    var base: TimeInterval = 2
    var maxDelay: TimeInterval = 60
    func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = min(max(0, attempt - 1), 10)
        return min(base * pow(2.0, Double(exponent)), maxDelay)
    }
    static func delay(forAttempt attempt: Int) -> TimeInterval { RecoveryBackoff().delay(forAttempt: attempt) }
}
private func maxInt(_ a: Int, _ b: Int) -> Int { a > b ? a : b }
