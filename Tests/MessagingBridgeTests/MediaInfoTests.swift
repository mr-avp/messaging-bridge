import XCTest
@testable import MessagingBridge

final class MediaInfoTests: XCTestCase {
    func testMIMEByExtension() {
        XCTAssertEqual(MediaInfo.mimeType(fileName: "anim.GIF"), "image/gif")
        XCTAssertEqual(MediaInfo.mimeType(fileName: "photo.jpeg"), "image/jpeg")
        XCTAssertEqual(MediaInfo.mimeType(fileName: "clip.MP4"), "video/mp4")
        XCTAssertEqual(MediaInfo.mimeType(fileName: "report.pdf"), "application/pdf")
        XCTAssertEqual(MediaInfo.mimeType(fileName: "no-extension"), "application/octet-stream")
        XCTAssertEqual(MediaInfo.mimeType(fileName: ""), "application/octet-stream")
    }

    func testFileExtensionIgnoresQueryAndFragment() {
        XCTAssertEqual(MediaInfo.fileExtension("https://example.com/a.GIF?token=1#x"), "gif")
        XCTAssertEqual(MediaInfo.fileExtension("anim.gif"), "gif")
        XCTAssertEqual(MediaInfo.fileExtension(""), "")
    }

    func testGIFDetectionFromNameURLOrMIME() {
        XCTAssertTrue(MediaInfo.isGIF(name: "anim.gif", url: nil, mime: nil))
        XCTAssertTrue(MediaInfo.isGIF(name: nil, url: "https://example.com/a.GIF?x=1", mime: nil))
        XCTAssertTrue(MediaInfo.isGIF(name: nil, url: nil, mime: "image/gif"))
        XCTAssertFalse(MediaInfo.isGIF(name: "clip.mp4", url: "https://example.com/a.mp4", mime: "video/mp4"))
    }

    func testTelegramKindKeepsGIFsAsAnimations() {
        XCTAssertEqual(MediaInfo.telegramKind(for: .photo, url: "https://x/a.jpg", name: nil, mime: nil), .photo)
        XCTAssertEqual(MediaInfo.telegramKind(for: .video, url: "https://x/a.mp4", name: nil, mime: nil), .video)
        XCTAssertEqual(MediaInfo.telegramKind(for: .video, url: "https://x/a.mp4", name: "anim.gif", mime: nil), .animation)
        XCTAssertEqual(MediaInfo.telegramKind(for: .video, url: "https://x/a.mp4", name: nil, mime: "image/gif"), .animation)
        XCTAssertEqual(MediaInfo.telegramKind(for: .file, url: "https://x/a.gif", name: nil, mime: nil), .animation)
        XCTAssertEqual(MediaInfo.telegramKind(for: .file, url: "https://x/a.pdf", name: "a.pdf", mime: nil), .document)
    }

    func testTelegramLimits() {
        XCTAssertEqual(TelegramLimits.maxBytes(for: .photo), 10 * 1024 * 1024)
        XCTAssertEqual(TelegramLimits.maxBytes(for: .animation), 50 * 1024 * 1024)
        XCTAssertEqual(TelegramLimits.maxBytes(for: .video), 50 * 1024 * 1024)
        XCTAssertEqual(TelegramLimits.maxBytes(for: .document), 50 * 1024 * 1024)
        XCTAssertTrue(TelegramLimits.canSend(kind: .photo, byteCount: 10 * 1024 * 1024))
        XCTAssertFalse(TelegramLimits.canSend(kind: .photo, byteCount: 10 * 1024 * 1024 + 1))
        XCTAssertTrue(TelegramLimits.canSend(kind: .animation, byteCount: 50 * 1024 * 1024))
        XCTAssertFalse(TelegramLimits.canSend(kind: .animation, byteCount: 50 * 1024 * 1024 + 1))
        XCTAssertTrue(TelegramLimits.canDownload(byteCount: 20 * 1024 * 1024))
        XCTAssertFalse(TelegramLimits.canDownload(byteCount: 20 * 1024 * 1024 + 1))
    }

    func testIncomingAnimationWinsOverDocument() throws {
        let media = try XCTUnwrap(TelegramIncomingMedia.parse([
            "animation": [
                "file_id": "A",
                "file_name": "anim.gif",
                "mime_type": "image/gif",
                "file_size": 12
            ],
            "document": ["file_id": "D", "file_name": "anim.gif"]
        ]))
        XCTAssertEqual(media.kind, .animation)
        XCTAssertEqual(media.fileID, "A")
        XCTAssertEqual(media.fileName, "anim.gif")
        XCTAssertEqual(media.mimeType, "image/gif")
        XCTAssertEqual(media.byteCount, 12)
        XCTAssertEqual(media.maxKind.rawValue, "file", "a GIF animation must go to MAX as a file")
    }

    func testIncomingAnimationDefaultsToMP4() throws {
        let media = try XCTUnwrap(TelegramIncomingMedia.parse([
            "animation": ["file_id": "A"]
        ]))
        XCTAssertEqual(media.fileName, "animation.mp4")
        XCTAssertEqual(media.mimeType, "video/mp4")
        XCTAssertEqual(media.maxKind.rawValue, "video")
    }

    func testIncomingVideoPhotoAndDocument() throws {
        let video = try XCTUnwrap(TelegramIncomingMedia.parse([
            "video": ["file_id": "V", "mime_type": "video/mp4", "file_size": 5]
        ]))
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.maxKind.rawValue, "video")

        let photo = try XCTUnwrap(TelegramIncomingMedia.parse([
            "photo": [
                ["file_id": "small", "file_size": 1],
                ["file_id": "large", "file_size": 2]
            ]
        ]))
        XCTAssertEqual(photo.fileID, "large", "the largest Telegram photo must be used")
        XCTAssertEqual(photo.fileName, "photo.jpg")
        XCTAssertEqual(photo.maxKind.rawValue, "photo")

        let document = try XCTUnwrap(TelegramIncomingMedia.parse([
            "document": ["file_id": "D", "file_name": "report.pdf", "mime_type": "application/pdf"]
        ]))
        XCTAssertEqual(document.kind, .document)
        XCTAssertEqual(document.maxKind.rawValue, "file")
        XCTAssertEqual(document.mimeType, "application/pdf")

        XCTAssertNil(TelegramIncomingMedia.parse(["text": "no media"]))
    }
}

final class EmojiTextTests: XCTestCase {
    private let prefix = "<b>Анна</b>:\n"

    func testZWJSkinToneAndFlagsSurviveRendering() {
        let text = "Семья 👨‍👩‍👧‍👦, 👍🏽, 🇷🇺, 🏴󠁧󠁢󠁥󠁮󠁧󠁿, 👩🏽‍🚀"
        XCTAssertEqual(RelayPolicy.renderTelegram(author: "Анна", text: text), prefix + text)
        XCTAssertEqual(RelayPolicy.telegramParts(author: "Анна", text: text, limit: 1024), [prefix + text])
    }

    func testLongEmojiTextIsSplitOnGraphemeClusters() {
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family + " ", count: 400)
        let parts = RelayPolicy.telegramParts(author: "Анна", text: text, limit: 1024)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertLessThanOrEqual(RelayPolicy.visibleUTF16Count(part), 1024, "Telegram counts visible UTF-16 units")
        }
        XCTAssertTrue(parts[0].hasPrefix(prefix))
        let bodies = parts.enumerated().map { index, part in
            index == 0 ? String(part.dropFirst(prefix.count)) : part
        }
        XCTAssertEqual(bodies.joined(), text, "splitting must not lose or duplicate emoji")
        for body in bodies {
            XCTAssertFalse(body.contains("\u{FFFD}"), "no broken grapheme clusters")
        }
    }

    func testHTMLIsEscapedAfterSplitting() {
        let text = String(repeating: "a", count: 1023) + "<&>" + String(repeating: "b", count: 2000)
        let parts = RelayPolicy.telegramParts(author: "Анна", text: text, limit: 1024)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts[0].hasPrefix(prefix))
        let bodies = parts.enumerated().map { index, part in
            index == 0 ? String(part.dropFirst(prefix.count)) : part
        }
        XCTAssertEqual(bodies.joined(), RelayPolicy.htmlEscape(text))
        for body in bodies {
            for partial in ["&", "&a", "&am", "&amp", "&l", "&lt", "&g", "&gt"] {
                XCTAssertFalse(body.hasSuffix(partial), "an HTML entity must never be cut: \(partial)")
            }
        }
    }

    func testCaptionLimitIncludesAuthorPrefix() {
        let text = String(repeating: "🙂", count: 2000)
        let parts = RelayPolicy.telegramParts(author: "Анна", text: text, limit: 1024)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertLessThanOrEqual(RelayPolicy.visibleUTF16Count(parts[0]), 1024)
        XCTAssertTrue(parts[0].hasPrefix(prefix))
    }
}
