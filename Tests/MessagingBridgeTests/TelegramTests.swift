import XCTest
@testable import MessagingBridge

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest, Data) -> (Int, Data))?
    static var requests: [(URLRequest, Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(request)
        Self.requests.append((request, body))
        let (status, data) = Self.handler?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class TelegramPayloadTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        super.tearDown()
    }

    private func makeAPI() -> Telegram {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return Telegram(token: "1:test", session: URLSession(configuration: config))
    }

    func testAnimationURLUsesSendAnimationAndKeepsEmojiCaption() async throws {
        let api = makeAPI()
        let caption = "<b>Анна</b>:\n👨‍👩‍👧‍👦 👍🏽 🇷🇺 🏴󠁧󠁢󠁥󠁮󠁧󠁿"
        var payload: [String: Any] = [:]
        StubURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.lastPathComponent, "sendAnimation")
            payload = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            return (200, Data(#"{"ok":true,"result":{}}"#.utf8))
        }
        try await api.sendMedia(chat: "-100", kind: .animation, url: "https://example.com/a.gif", caption: caption)
        XCTAssertEqual(payload["animation"] as? String, "https://example.com/a.gif")
        XCTAssertEqual(payload["caption"] as? String, caption)
        XCTAssertEqual(payload["parse_mode"] as? String, "HTML")
        XCTAssertNil(payload["supports_streaming"], "sendAnimation does not accept supports_streaming")
    }

    func testVideoURLUsesSendVideoWithStreaming() async throws {
        let api = makeAPI()
        var payload: [String: Any] = [:]
        StubURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.lastPathComponent, "sendVideo")
            payload = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            return (200, Data(#"{"ok":true,"result":{}}"#.utf8))
        }
        try await api.sendMedia(chat: "-100", kind: .video, url: "https://example.com/a.mp4")
        XCTAssertEqual(payload["video"] as? String, "https://example.com/a.mp4")
        XCTAssertEqual(payload["supports_streaming"] as? Bool, true)
    }

    func testAnimationUploadUsesMultipartWithGIFMIME() async throws {
        let api = makeAPI()
        StubURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.lastPathComponent, "sendAnimation")
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"animation\""))
            XCTAssertTrue(text.contains("filename=\"anim.gif\""))
            XCTAssertTrue(text.contains("Content-Type: image/gif"))
            XCTAssertTrue(text.contains("name=\"caption\""))
            XCTAssertTrue(text.contains("👨‍👩‍👧‍👦"))
            return (200, Data(#"{"ok":true,"result":{}}"#.utf8))
        }
        try await api.sendAnimation(
            chat: "-100",
            data: Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
            fileName: "anim.gif",
            mimeType: "image/gif",
            caption: "<b>Анна</b>:\n👨‍👩‍👧‍👦"
        )
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testDocumentUploadUsesRealMIMEAndName() async throws {
        let api = makeAPI()
        StubURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.lastPathComponent, "sendDocument")
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"document\""))
            XCTAssertTrue(text.contains("filename=\"anim.gif\""))
            XCTAssertTrue(text.contains("Content-Type: image/gif"))
            return (200, Data(#"{"ok":true,"result":{}}"#.utf8))
        }
        try await api.sendDocument(
            chat: "-100",
            data: Data([0x47, 0x49, 0x46]),
            fileName: "anim.gif",
            mimeType: "image/gif"
        )
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testTextKeepsEmojiAndUsesHTMLParseMode() async throws {
        let api = makeAPI()
        let text = "<b>Анна</b>:\n👋😀👍 👨‍👩‍👧‍👦 👍🏽 🇷🇺 1️⃣ ❤️"
        var payload: [String: Any] = [:]
        StubURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.lastPathComponent, "sendMessage")
            payload = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            return (200, Data(#"{"ok":true,"result":{}}"#.utf8))
        }
        try await api.send(chat: "-100", text: text)
        XCTAssertEqual(payload["text"] as? String, text)
        XCTAssertEqual(payload["parse_mode"] as? String, "HTML")
    }

    func testCaptionOverLimitIsRejectedBeforeNetwork() async {
        let api = makeAPI()
        var calls = 0
        StubURLProtocol.handler = { _, _ in
            calls += 1
            return (200, Data(#"{"ok":true,"result":{}}"#.utf8))
        }
        do {
            try await api.sendMedia(
                chat: "-100",
                kind: .photo,
                url: "https://example.com/photo.jpg",
                caption: String(repeating: "a", count: TelegramLimits.captionUnits + 1)
            )
            XCTFail("an oversized caption must be rejected")
        } catch {
            XCTAssertEqual(calls, 0, "the request must not reach the network")
        }
    }

    func testTooBigDownloadDetection() {
        XCTAssertTrue(TelegramLimits.isTooBigDownload(
            TelegramError(method: "getFile", code: 400, detail: "Bad Request: file is too big")
        ))
        XCTAssertFalse(TelegramLimits.isTooBigDownload(
            TelegramError(method: "getFile", code: 400, detail: "Bad Request: invalid file_id")
        ))
    }
}
