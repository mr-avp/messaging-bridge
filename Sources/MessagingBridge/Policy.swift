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
        parts(author: author, text: text, limit: limit, html: true)
    }

    /// Plain counterpart for chats that do not parse HTML (MAX). The text is
    /// copied verbatim: nothing is escaped and no HTML entities are decoded, so
    /// a user's literal `<b>`, `&amp;` or `&lt;` arrives exactly as typed.
    static func plainParts(author: String, text: String, limit: Int) -> [String] {
        parts(author: author, text: text, limit: limit, html: false)
    }

    private static func parts(author: String, text: String, limit: Int, html: Bool) -> [String] {
        let safeLimit = max(1, limit)
        let authorText = authorWithinBudget(author, limit: safeLimit)
        let prefix = html
            ? "<b>\(htmlEscape(authorText))</b>:\n"
            : "\(authorText):\n"
        let firstBudget = max(1, safeLimit - (authorText.utf16.count + 2))
        var parts: [String] = []
        var body = ""
        var units = 0
        var budget = firstBudget
        func flush() {
            parts.append((parts.isEmpty ? prefix : "") + (html ? htmlEscape(body) : body))
            body = ""
            units = 0
            budget = safeLimit
        }
        for character in text {
            let width = String(character).utf16.count
            if units > 0 && units + width > budget { flush() }
            // A grapheme cluster is never split. If it alone is wider than the
            // budget it becomes its own part, and the send-time limit check
            // reports it explicitly instead of truncating the message.
            body.append(character)
            units += width
        }
        if !body.isEmpty || parts.isEmpty { flush() }
        return parts
    }

    /// Keep the author label within half of the limit, measured in UTF-16 units
    /// the same way Telegram counts them. Trimming stops on a grapheme boundary;
    /// a single grapheme wider than the allowance is dropped together with the
    /// rest of the label instead of being split or pushing the part over budget.
    private static func authorWithinBudget(_ author: String, limit: Int) -> String {
        let budget = max(0, limit / 2 - 2)
        if author.utf16.count <= budget { return author }
        var trimmed = ""
        var units = 0
        for character in author {
            let width = String(character).utf16.count
            if units + width > budget { break }
            trimmed.append(character)
            units += width
        }
        return trimmed
    }
}
