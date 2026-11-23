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
}
