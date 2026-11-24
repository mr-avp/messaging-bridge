import Foundation

struct TelegramError: Error, CustomStringConvertible {
    let method: String
    let code: Int
    let detail: String
    var retryAfter: TimeInterval?
    var description: String { "\(method): \(code) \(detail)" }
}

enum TelegramMediaKind: String {
    case photo
    case animation
    case video
    case document
}

final class Telegram {
    let token: String
    private let session: URLSession
    init(token: String, session: URLSession? = nil) {
        self.token = token
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.timeoutIntervalForRequest = 40
            self.session = URLSession(configuration: config)
        }
    }

    func call(_ method: String, _ payload: [String: Any] = [:]) async throws -> Any {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { throw RelayError.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw TelegramError(method: method, code: -1, detail: error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, body?["ok"] as? Bool == true else {
            let detail = body?["description"] as? String ?? "HTTP \(status)"
            let params = body?["parameters"] as? [String: Any]
            let retry = (params?["retry_after"] as? Int).map { TimeInterval($0) }
            throw TelegramError(method: method, code: (body?["error_code"] as? Int) ?? status, detail: detail, retryAfter: retry)
        }
        guard let result = body?["result"] else { throw RelayError.api }
        return result
    }

    private func callWithRetry(_ method: String, _ payload: [String: Any]) async throws -> Any {
        var attempt = 0
        while true {
            do { return try await call(method, payload) }
            catch let error as TelegramError where error.code == 429 && attempt < 4 {
                attempt += 1
                let wait = max(1, error.retryAfter ?? TimeInterval(attempt * 2))
                try await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func updates(offset: Int, timeout: Int = 25) async throws -> [[String: Any]] {
        try await call("getUpdates", ["offset": offset, "timeout": timeout, "allowed_updates": ["message"]]) as? [[String: Any]] ?? []
    }

    func send(chat: String, text: String) async throws {
        guard RelayPolicy.visibleUTF16Count(text) <= TelegramLimits.messageUnits else { throw RelayError.configuration }
        _ = try await callWithRetry("sendMessage", ["chat_id": chat, "text": text, "parse_mode": "HTML", "link_preview_options": ["is_disabled": true]])
    }

    func sendMedia(chat: String, kind: TelegramMediaKind, url: String, caption: String = "") async throws {
        let method: String
        let key: String
        switch kind {
        case .photo: method = "sendPhoto"; key = "photo"
        case .animation: method = "sendAnimation"; key = "animation"
        case .video: method = "sendVideo"; key = "video"
        case .document: method = "sendDocument"; key = "document"
        }
        var payload: [String: Any] = ["chat_id": chat, key: url]
        if !caption.isEmpty {
            guard RelayPolicy.visibleUTF16Count(caption) <= TelegramLimits.captionUnits else { throw RelayError.configuration }
            payload["caption"] = caption
            payload["parse_mode"] = "HTML"
        }
        if kind == .video { payload["supports_streaming"] = true }
        _ = try await callWithRetry(method, payload)
    }

    func sendDocument(chat: String, data: Data, fileName: String, mimeType: String = "application/octet-stream", caption: String = "") async throws {
        try await sendUpload(
            method: "sendDocument", field: "document",
            chat: chat, data: data, fileName: fileName, mimeType: mimeType, caption: caption
        )
    }

    func sendAnimation(chat: String, data: Data, fileName: String, mimeType: String = "image/gif", caption: String = "") async throws {
        try await sendUpload(
            method: "sendAnimation", field: "animation",
            chat: chat, data: data, fileName: fileName, mimeType: mimeType, caption: caption
        )
    }

    private func sendUpload(
        method: String,
        field: String,
        chat: String,
        data: Data,
        fileName: String,
        mimeType: String,
        caption: String
    ) async throws {
        var attempt = 0
        while true {
            do {
                let boundary = UUID().uuidString
                var body = Data()
                func appendField(_ name: String, _ value: String) {
                    body.append("--\(boundary)\r\n".data(using: .utf8)!)
                    body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                    body.append("\(value)\r\n".data(using: .utf8)!)
                }
                appendField("chat_id", chat)
                if !caption.isEmpty {
                    guard RelayPolicy.visibleUTF16Count(caption) <= TelegramLimits.captionUnits else { throw RelayError.configuration }
                    appendField("caption", caption)
                    appendField("parse_mode", "HTML")
                }
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
                body.append(data)
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { throw RelayError.configuration }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                let (responseData, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
                guard status == 200, json?["ok"] as? Bool == true else {
                    let detail = json?["description"] as? String ?? "HTTP \(status)"
                    let params = json?["parameters"] as? [String: Any]
                    let retry = (params?["retry_after"] as? Int).map { TimeInterval($0) }
                    throw TelegramError(method: method, code: (json?["error_code"] as? Int) ?? status, detail: detail, retryAfter: retry)
                }
                return
            } catch let error as TelegramError where error.code == 429 && attempt < 4 {
                attempt += 1
                let wait = max(1, error.retryAfter ?? TimeInterval(attempt * 2))
                try await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func downloadFile(fileID: String) async throws -> Data {
        let result = try await callWithRetry("getFile", ["file_id": fileID])
        guard let path = (result as? [String: Any])?["file_path"] as? String, !path.isEmpty else { throw RelayError.api }
        guard let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(path)") else { throw RelayError.configuration }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(from: url) }
        catch { throw TelegramError(method: "downloadFile", code: -1, detail: error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw TelegramError(method: "downloadFile", code: status, detail: "HTTP \(status)") }
        return data
    }
}
