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
struct RelayMedia { let kind: RelayMediaKind; let url: String; let name: String? }
struct RelayMessage { let id: String; let chat: String; let sender: String; let text: String; let media: [RelayMedia] }
@MainActor final class Model: ObservableObject {
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
    let max = MaxWeb()
    private var telegram: Telegram?
    private let downloadSession = URLSession(configuration: .ephemeral)
    private var poll: Task<Void, Never>?
    private var deliver: Task<Void, Never>?
    private var queue: [RelayMessage] = []
    private var seen = Set<String>()
    private var runID = UUID()
    private var offset = 0
    init() {
        max.onMessage = { [weak self] data in
            self?.receive(data)
        }
        loadConnections()
    }
    func openMAX() { max.load() }
    func receive(_ data: [String: Any]) {
        switch data["kind"] as? String {
        case "ready":
            maxReady = true
            readyCount += 1
            maxEvents += 1
            readySocketGen = jsSocket
            let raw = data["groups"] as? [[String: Any]] ?? []
            apply(groups: raw)
            status = raw.isEmpty
                ? "MAX подключён, но список групп пуст. Откройте нужный чат в MAX справа и нажмите «Обновить группы»."
                : "MAX подключён. Выберите группу-источник и оставьте её открытой справа."
        case "groups":
            maxEvents += 1
            apply(groups: data["groups"] as? [[String: Any]] ?? [])
            if maxReady {
                status = maxGroups.isEmpty
                    ? "MAX подключён, но список групп пуст. Нажмите «Обновить группы»."
                    : "MAX подключён. Групп: \(maxGroups.count). Выберите группу-источник и оставьте чат открытым."
            }
        case "login-error":
            maxReady = false
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
            print("FamilyRelay MAX debug: \(lastDebug)")
        case "disconnected":
            maxReady = false
            stop("MAX отключился. После восстановления соединения включите мост снова.")
        case "nav":
            let stage = data["stage"] as? String ?? "?"
            let info = data["error"] as? String ?? (data["url"] as? String ?? "")
            status = "MAX навигация: \(stage) \(info)"
            print("FamilyRelay MAX nav: \(stage) \(info)")
        case "message":
            guard running, let chat = data["chat"] as? String, let id = data["id"] as? String else { return }
            let text = (data["text"] as? String) ?? ""
            let sender = (data["sender"] as? String) ?? "Участник MAX"
            let media = ((data["media"] as? [[String: Any]]) ?? []).compactMap { item -> RelayMedia? in
                guard let kind = (item["kind"] as? String).flatMap(RelayMediaKind.init(rawValue:)),
                      let url = item["url"] as? String, !url.isEmpty else { return nil }
                return RelayMedia(kind: kind, url: url, name: item["name"] as? String)
            }
            guard RelayPolicy.accept(chat: chat, allowed: maxID, text: text, hasMedia: !media.isEmpty),
                  seen.insert("max:\(id)").inserted else { return }
            let caption = RelayPolicy.render(author: sender, text: text)
            guard caption.utf16.count <= 4000 else { stop("Слишком длинное сообщение MAX. Мост остановлен."); return }
            guard queue.count < 100, seen.count < 10000 else { stop("Очередь заполнена. Мост остановлен."); return }
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
            status = "Токен в Связке ключей не найден. Вставьте токен и нажмите «Подключить бота»."
        }
    }
    func deleteToken() {
        guard !running, !busy else { return }
        Secrets.delete()
        telegram = nil
        token = ""
        status = "Токен удалён из Связки ключей. Вставьте новый токен и нажмите «Подключить бота»."
    }
    func restoreAndConnect() async {
        let saved = Secrets.read()
        guard !saved.isEmpty, telegram == nil, !running, !busy else { return }
        token = saved
        await connectTelegram()
        if telegram != nil { status = "Бот подключён автоматически из Связки ключей. \(status)"; await refreshSavedGroupTitles() }
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
    private func persistConnections() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: "family-relay.connections")
        }
    }
    private func loadConnections() {
        guard let data = UserDefaults.standard.data(forKey: "family-relay.connections"),
              let decoded = try? JSONDecoder().decode([BridgeConnection].self, from: data) else { return }
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
    }
    func start() async {
        guard canStart, !running, let api = telegram else { return }
        busy = true; defer { busy = false }
        do {
            // Drop pre-existing updates. The first run never exports old conversations.
            let latest = try await api.updates(offset: -1, timeout: 0)
            if let id = latest.last?["update_id"] as? Int { offset = id + 1 }
            try await max.configure(chat: maxID, enabled: true)
            queue.removeAll(); seen.removeAll(); runID = UUID()
            let current = runID
            let started = Int(Date().timeIntervalSince1970)
            running = true; status = "Мост работает. Оставьте выбранный чат MAX открытым справа; переносятся только новые тексты, фото и видео."
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
                            let photoID = (m["photo"] as? [[String: Any]])?.last?["file_id"] as? String
                            let videoID = (m["video"] as? [String: Any])?["file_id"] as? String
                            let document = m["document"] as? [String: Any]
                            let documentID = document?["file_id"] as? String
                            let documentName = document?["file_name"] as? String
                            let sender = m["from"] as? [String: Any] ?? [:]
                            guard RelayPolicy.accept(chat: id.stringValue, allowed: self.tgID, text: content,
                                                     bot: sender["is_bot"] as? Bool ?? false,
                                                     hasMedia: photoID != nil || videoID != nil || documentID != nil) else { continue }
                            let rendered = RelayPolicy.render(author: Self.telegramName(sender), text: content)
                            guard rendered.utf16.count <= 4000 else { self.stop("Слишком длинное сообщение. Мост остановлен; передайте его вручную."); return }
                            if let fileID = photoID {
                                let data = try await api.downloadFile(fileID: fileID)
                                try await self.max.sendMedia(chat: self.maxID, kind: .photo, data: data, text: rendered, fileName: "photo.jpg")
                            } else if let fileID = videoID {
                                let data = try await api.downloadFile(fileID: fileID)
                                try await self.max.sendMedia(chat: self.maxID, kind: .video, data: data, text: rendered, fileName: "video.mp4")
                            } else if let fileID = documentID {
                                let data = try await api.downloadFile(fileID: fileID)
                                try await self.max.sendMedia(chat: self.maxID, kind: .file, data: data, text: rendered, fileName: documentName ?? "document")
                            } else {
                                try await self.max.send(chat: self.maxID, text: rendered)
                            }
                            self.count += 1
                            try await Task.sleep(for: .milliseconds(350))
                        }
                    }
                } catch {
                    if self.runID == current { self.stop("Передача остановлена из-за ошибки связи. Проверьте последнее сообщение перед повторным запуском: оно могло быть доставлено.") }
                }
            }
            deliver = Task { [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled && self.running && self.runID == current {
                        if !self.queue.isEmpty {
                            let message = self.queue.removeFirst()
                            let caption = RelayPolicy.renderTelegram(author: message.sender, text: message.text)
                            if message.media.isEmpty {
                                try await api.send(chat: self.tgID, text: caption)
                            } else {
                                for (index, media) in message.media.enumerated() {
                                    let label = index == 0 ? caption : ""
                                    do {
                                        if media.kind == .file {
                                            let data = try await self.downloadData(from: media.url)
                                            try await api.sendDocument(chat: self.tgID, data: data, fileName: media.name ?? "document", caption: label)
                                        } else {
                                            let tgKind: TelegramMediaKind = (media.kind == .photo) ? .photo : .video
                                            try await api.sendMedia(chat: self.tgID, kind: tgKind, url: media.url, caption: label)
                                        }
                                    } catch {
                                        let fallback = label.isEmpty ? media.url : "\(caption)\n\(media.url)"
                                        try await api.send(chat: self.tgID, text: String(fallback.prefix(4000)))
                                    }
                                }
                                if caption.utf16.count > 1024 {
                                    let extra = String(caption.dropFirst(1024))
                                    try await api.send(chat: self.tgID, text: String(extra.prefix(4000)))
                                }
                            }
                            self.count += 1
                            try await Task.sleep(for: .milliseconds(350))
                        } else { try await Task.sleep(for: .milliseconds(200)) }
                    }
                } catch {
                    if self.runID == current { self.stop("Передача остановлена из-за ошибки связи. Проверьте последнее сообщение перед повторным запуском: оно могло быть доставлено.") }
                }
            }
        } catch { stop("Не удалось запустить мост. Проверьте вход в MAX и связь с Telegram.") }
    }
    func stop(_ reason: String = "Мост выключен.") {
        running = false; busy = false; runID = UUID(); poll?.cancel(); deliver?.cancel(); queue.removeAll(); status = reason
        Task { try? await max.configure(chat: maxID, enabled: false) }
    }
    func copyDiagnostics() {
        let text = """
        Статус: \(status)
        Бот: \(telegram == nil ? "не подключён" : "подключён"), токен в Связке: \(Secrets.read().isEmpty ? "нет" : "есть")
        MAX: \(maxReady ? "подключён" : "нет"), событий: \(maxEvents), ready: \(readyCount), групп: \(maxGroups.count)
        Выбрано: MAX \(maxGroups.first(where: { $0.id == maxID })?.title ?? "—"), TG \(tgGroups.first(where: { $0.id == tgID })?.title ?? "—")
        JS: старт \(jsStart), сокет \(jsSocket), авторизация \(jsAuth)
        Хост сокета: \(jsHost.isEmpty ? "—" : jsHost)
        Страница: \(jsTitle.isEmpty ? "—" : jsTitle), текст \(jsTextLen), видимость \(jsVisibility.isEmpty ? "—" : jsVisibility)
        Кадры: \(lastFrames.isEmpty ? "—" : lastFrames)
        Отладка: \(lastDebug.isEmpty ? "—" : lastDebug)
        Перенесено: \(count)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
private func maxInt(_ a: Int, _ b: Int) -> Int { a > b ? a : b }
