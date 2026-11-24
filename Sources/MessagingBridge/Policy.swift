import Foundation
struct RelayPolicy {
    // Старые сообщения с видимой подписью больше не создаются, но всё ещё отфильтровываются.
    private static let legacyMarker = "\u{2063}семейный-мост\u{2063}"
    private static let invisibleMarker = "\u{2063}\u{200B}\u{2063}\u{200B}\u{2063}"
    static func accept(chat: String, allowed: String, text: String, bot: Bool = false, hasMedia: Bool = false) -> Bool {
        !allowed.isEmpty && chat == allowed && !bot && (!text.isEmpty || hasMedia)
            && !text.contains(legacyMarker) && !text.contains(invisibleMarker)
    }
    static func render(author: String, text: String) -> String {
        "\(author):\n\(text)"
    }
    static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    static func renderTelegram(author: String, text: String) -> String {
        "<b>\(htmlEscape(author))</b>:\n\(htmlEscape(text))"
    }

    /// Telegram applies limits after entities are parsed. Count visible text,
    /// not the markup and entity escapes produced by `htmlEscape`.
    static func visibleUTF16Count(_ html: String) -> Int {
        var text = html
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
        text = text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return text.utf16.count
    }

    /// Split a message into Telegram-sized HTML parts. Splitting happens on
    /// grapheme clusters, so ZWJ emoji, skin-tone modifiers and flags are never
    /// cut in half, and HTML escaping is applied after the split. The limit is
    /// measured in UTF-16 units because that is how Telegram counts text.
    static func telegramParts(author: String, text: String, limit: Int) -> [String] {
        let safeLimit = max(1, limit)
        var authorText = author
        if authorText.utf16.count + 2 >= safeLimit {
            authorText = String(authorText.prefix(max(1, safeLimit / 2)))
        }
        let prefix = "<b>\(htmlEscape(authorText))</b>:\n"
        let firstBudget = max(1, safeLimit - (authorText.utf16.count + 2))
        var parts: [String] = []
        var body = ""
        var units = 0
        var budget = firstBudget
        func flush() {
            let html = (parts.isEmpty ? prefix : "") + htmlEscape(body)
            parts.append(html)
            body = ""
            units = 0
            budget = safeLimit
        }
        for character in text {
            let width = String(character).utf16.count
            if units > 0 && units + width > budget { flush() }
            body.append(character)
            units += width
        }
        if !body.isEmpty || parts.isEmpty { flush() }
        return parts
    }
}
