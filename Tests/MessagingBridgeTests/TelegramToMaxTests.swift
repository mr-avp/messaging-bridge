import XCTest
@testable import MessagingBridge

/// Regression tests for the Telegram → MAX direction. MAX does not parse HTML,
/// so the bridge must send plain text with exactly the characters the sender
/// typed: no `<b>` wrapper, no escapes and no entity decoding.
final class TelegramToMaxTests: XCTestCase {
    private let prefix = "Анна:\n"

    private func bodies(_ parts: [String], prefix: String) -> [String] {
        parts.enumerated().map { index, part in
            index == 0 ? String(part.dropFirst(prefix.count)) : part
        }
    }

    func testAuthorAndTextArriveWithoutMarkup() {
        XCTAssertEqual(RelayPolicy.plainParts(author: "Анна", text: "Привет", limit: 4000), [prefix + "Привет"])
    }

    func testHTMLCharactersAreKeptVerbatim() {
        let author = "Анна <тест> & Ко"
        let text = "1 < 2 & 3 > 2, <b>не жирный</b>, &amp; и &lt; остаются как есть"
        let parts = RelayPolicy.plainParts(author: author, text: text, limit: 4000)
        XCTAssertEqual(parts, [author + ":\n" + text], "every character must arrive verbatim")
        XCTAssertFalse(parts[0].contains("&amp;amp;"), "user entities must not be re-encoded")
        XCTAssertFalse(parts[0].contains("&amp;lt;"), "user entities must not be re-encoded")
        XCTAssertFalse(parts[0].contains("&lt;b&gt;"), "user text must not be escaped")
        XCTAssertFalse(parts[0].contains("<b>Анна"), "MAX must not receive Telegram HTML markup")
    }

    func testEmojiGraphemesAreKeptWhole() {
        let text = "Семья 👨‍👩‍👧‍👦, 👍🏽, 🇷🇺, 🏴󠁧󠁢󠁥󠁮󠁧󠁿, 👩🏽‍🚀"
        XCTAssertEqual(RelayPolicy.plainParts(author: "Анна", text: text, limit: 4000), [prefix + text])
    }

    func testLongTextSplitsWithoutLoss() {
        let text = String(repeating: "строка ", count: 1000)
        let parts = RelayPolicy.plainParts(author: "Анна", text: text, limit: 4000)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts[0].hasPrefix(prefix))
        for part in parts {
            XCTAssertLessThanOrEqual(part.utf16.count, 4000)
        }
        XCTAssertEqual(bodies(parts, prefix: prefix).joined(), text)
    }

    func testLongEmojiTextSplitsOnGraphemeClusters() {
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family + " ", count: 400)
        let parts = RelayPolicy.plainParts(author: "Анна", text: text, limit: 1024)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertLessThanOrEqual(part.utf16.count, 1024)
            XCTAssertFalse(part.contains("\u{FFFD}"), "no broken grapheme clusters")
        }
        XCTAssertEqual(bodies(parts, prefix: prefix).joined(), text)
    }

    func testMediaCaptionStaysPlainAndFitsTheCaptionBudget() {
        let caption = String(repeating: "🙂", count: 512)
        let parts = RelayPolicy.plainParts(author: "Анна", text: caption, limit: TelegramLimits.captionUnits)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts[0].hasPrefix(prefix))
        for part in parts {
            XCTAssertLessThanOrEqual(part.utf16.count, TelegramLimits.captionUnits)
        }
        XCTAssertEqual(bodies(parts, prefix: prefix).joined(), caption)
        XCTAssertFalse(parts.joined().contains("<b>"))
    }

    func testLongEmojiAuthorIsTrimmedByUTF16BudgetForMax() {
        let family = "👨‍👩‍👧‍👦"
        let author = String(repeating: family, count: 300)
        let parts = RelayPolicy.plainParts(author: author, text: "Привет", limit: 1024)
        XCTAssertEqual(parts.count, 1)
        XCTAssertLessThanOrEqual(parts[0].utf16.count, 1024)
        XCTAssertTrue(parts[0].hasSuffix(":\nПривет"))
        let label = String(parts[0].dropLast(":\nПривет".count))
        XCTAssertEqual(label.utf16.count % 11, 0, "the label must be cut on a grapheme boundary")
        XCTAssertFalse(label.contains("\u{FFFD}"))
        XCTAssertFalse(parts[0].contains("<b>"))
    }

    func testLongEmojiAuthorIsTrimmedByUTF16BudgetForTelegram() {
        let family = "👨‍👩‍👧‍👦"
        let author = String(repeating: family, count: 300)
        let parts = RelayPolicy.telegramParts(author: author, text: "Привет", limit: 1024)
        XCTAssertEqual(parts.count, 1)
        XCTAssertLessThanOrEqual(RelayPolicy.visibleUTF16Count(parts[0]), 1024)
        XCTAssertTrue(parts[0].hasPrefix("<b>"))
        XCTAssertTrue(parts[0].hasSuffix("</b>:\nПривет"))
    }

    func testAuthorGraphemeWiderThanBudgetIsDroppedExplicitly() {
        let parts = RelayPolicy.plainParts(author: "👨‍👩‍👧‍👦", text: "ok", limit: 10)
        XCTAssertEqual(parts, [":\nok"], "an unbreakable label wider than its budget is dropped, never split")
    }

    func testBodyGraphemeWiderThanBudgetGetsItsOwnPart() {
        let family = "👨‍👩‍👧‍👦"
        let parts = RelayPolicy.plainParts(author: "А", text: "a" + family + "b", limit: 6)
        XCTAssertEqual(parts, ["А:\na", family, "b"],
                       "an unbreakable grapheme is isolated in its own part, so the send-time limit check can reject it explicitly")
        XCTAssertEqual(bodies(parts, prefix: "А:\n").joined(), "a" + family + "b")
    }
}
