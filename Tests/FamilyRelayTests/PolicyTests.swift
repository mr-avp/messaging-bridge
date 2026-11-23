import XCTest
@testable import FamilyRelay
final class PolicyTests: XCTestCase {
    func testPrivateChatNeverPasses() {
        XCTAssertFalse(RelayPolicy.accept(chat: "private", allowed: "family", text: "Код 123456"))
        XCTAssertFalse(RelayPolicy.accept(chat: "", allowed: "", text: "hello"))
    }
    func testEchoAndBotsNeverPass() {
        let echo = "Анна · MAX:\nПривет\u{2063}семейный-мост\u{2063}"
        XCTAssertFalse(RelayPolicy.accept(chat: "family", allowed: "family", text: echo))
        XCTAssertFalse(RelayPolicy.accept(chat: "family", allowed: "family", text: "hello", bot: true))
    }
    func testVisibleAndInvisibleServiceMarkersNeverPass() {
        XCTAssertFalse(RelayPolicy.accept(chat: "family", allowed: "family", text: "привет\u{2063}семейный-мост\u{2063}"))
        XCTAssertFalse(RelayPolicy.accept(chat: "family", allowed: "family", text: "привет\u{2063}\u{200B}\u{2063}\u{200B}\u{2063}"))
    }
    func testRenderUsesRealNameWithoutGenericSource() {
        let text = RelayPolicy.render(author: "Анна", text: "Привет")
        XCTAssertFalse(text.contains("семейный-мост"))
        XCTAssertFalse(text.contains("Участник"))
        XCTAssertTrue(text.hasPrefix("Анна:\n"))
    }
    func testTelegramRenderBoldEscapesHTML() {
        let text = RelayPolicy.renderTelegram(author: "Анна <тест>", text: "a & b")
        XCTAssertEqual(text, "<b>Анна &lt;тест&gt;</b>:\na &amp; b")
        XCTAssertTrue(text.hasPrefix("<b>"))
    }
    func testFamilyTextPasses() {
        XCTAssertTrue(RelayPolicy.accept(chat: "family", allowed: "family", text: "Привет"))
    }
    func testMediaWithoutTextPasses() {
        XCTAssertTrue(RelayPolicy.accept(chat: "family", allowed: "family", text: "", hasMedia: true))
        XCTAssertFalse(RelayPolicy.accept(chat: "family", allowed: "family", text: "", hasMedia: false))
    }
}
