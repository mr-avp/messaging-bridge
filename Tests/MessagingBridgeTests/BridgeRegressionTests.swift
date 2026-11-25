import XCTest
@testable import MessagingBridge

/// A MAX mock that subclasses the internal (non-final) MaxWeb class through
/// @testable — no public API is needed. It records the real calls the Model
/// makes and can delay each configure to emulate slow MAX JavaScript.
@MainActor
private final class MockMaxWeb: MaxWeb {
    private(set) var sentTexts: [String] = []
    private(set) var sentMedia: [(chat: String, kind: MaxMediaKind, text: String, fileName: String, mime: String, data: Data)] = []
    private(set) var configureCalls: [(chat: String, enabled: Bool)] = []
    private(set) var loadCount = 0
    var enableDelayMilliseconds: Int = 0
    var disableDelayMilliseconds: Int = 0
    var onSendText: ((String) -> Void)?

    override func load() { loadCount += 1 }
    override func autoLoad() {}
    override func configure(chat: String, enabled: Bool) async throws {
        configureCalls.append((chat, enabled))
        let delay = enabled ? enableDelayMilliseconds : disableDelayMilliseconds
        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
    }
    override func send(chat: String, text: String) async throws {
        sentTexts.append(text)
        onSendText?(text)
    }
    override func sendMedia(chat: String, kind: MaxMediaKind, data: Data, text: String, fileName: String, mime: String = "") async throws {
        sentMedia.append((chat, kind, text, fileName, mime, data))
        onSendText?(text)
    }
    override func refreshGroups() async throws -> [Group] { [] }
}

/// Scripted Telegram Bot API transport. The Model still runs its real
/// `start()` → `getUpdates` → filter/offset → `max.send` code path; only the
/// network is replaced.
private final class ScriptedTelegramProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var updatesQueue: [[[String: Any]]] = []
    private static var updateOffsets: [Int] = []
    private static var sentMessages: [[String: Any]] = []
    private static var methods: [String] = []
    private static var fileBytesByID: [String: Data] = [:]
    private static var getFileIDs: [String] = []
    private static var downloadedPaths: [String] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        updatesQueue = []
        updateOffsets = []
        sentMessages = []
        methods = []
        fileBytesByID = [:]
        getFileIDs = []
        downloadedPaths = []
    }

    static func queue(updates: [[[String: Any]]]) {
        lock.lock(); defer { lock.unlock() }
        updatesQueue = updates
    }

    /// Bytes served by `getFile` + the download URL, keyed by Telegram file_id.
    static func queue(files: [String: Data]) {
        lock.lock(); defer { lock.unlock() }
        for (id, bytes) in files { fileBytesByID[id] = bytes }
    }

    static func snapshot() -> (methods: [String], offsets: [Int], sent: [[String: Any]], getFileIDs: [String], downloadedPaths: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (methods, updateOffsets, sentMessages, getFileIDs, downloadedPaths)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.url?.lastPathComponent ?? ""
        let body = Self.readBody(request)
        let payload = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]

        Self.lock.lock()
        Self.methods.append(method)
        var result: Any = [:]
        var rawDownload: Data? = nil
        if method == "getUpdates" {
            Self.updateOffsets.append(payload["offset"] as? Int ?? Int.min)
            result = Self.updatesQueue.isEmpty ? [] : Self.updatesQueue.removeFirst()
        } else if method == "sendMessage" {
            Self.sentMessages.append(payload)
            result = ["message_id": 1]
        } else if method == "getFile" {
            let id = payload["file_id"] as? String ?? ""
            Self.getFileIDs.append(id)
            result = ["file_path": "download/\(id)"]
        } else if request.url?.path.hasPrefix("/file/bot") == true {
            let id = request.url!.lastPathComponent
            Self.downloadedPaths.append(id)
            rawDownload = Self.fileBytesByID[id] ?? Data()
        }
        Self.lock.unlock()

        if let rawDownload {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: rawDownload)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let json = (try? JSONSerialization.data(withJSONObject: ["ok": true, "result": result])) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: json)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
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

@MainActor
final class BridgeRegressionTests: XCTestCase {
    private var tempDirs: [URL] = []
    private var suites: [String] = []

    override func setUp() {
        super.setUp()
        ScriptedTelegramProtocol.reset()
    }

    override func tearDown() {
        ScriptedTelegramProtocol.reset()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        tempDirs.removeAll()
        suites.removeAll()
        super.tearDown()
    }

    private func makeModel(max: MockMaxWeb) -> Model {
        let suite = "BridgeRegression." + UUID().uuidString
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BridgeRegression-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(dir)
        let eventLog = EventLog(fileURL: dir.appendingPathComponent("events.jsonl"))
        let model = Model(defaults: defaults, eventLog: eventLog, max: max)
        model.receive(["kind": "ready", "groups": [["id": "MAX-1", "title": "Family MAX"]]])
        model.maxID = "MAX-1"
        model.tgGroups = [Group(id: "-100", title: "Family TG")]
        model.tgID = "-100"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedTelegramProtocol.self]
        model.telegram = Telegram(token: "1:test", session: URLSession(configuration: config))
        return model
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool,
                         timeout: TimeInterval = 3,
                         file: StaticString = #filePath,
                         line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testStartStopStartUsesRealModelPath() async {
        let max = MockMaxWeb()
        // Emulate a slow MAX JS disable — it must not land after the next enable.
        max.disableDelayMilliseconds = 80
        let model = makeModel(max: max)
        ScriptedTelegramProtocol.queue(updates: [[], [], []])

        XCTAssertTrue(model.canStart, "a ready model with both groups must be startable")
        await model.start()
        XCTAssertTrue(model.running)

        model.stopByUser()
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.canStart, "Start must be enabled again after a manual stop")

        await model.start()
        XCTAssertTrue(model.running, "a user start after a manual stop must actually start")
        await waitFor { max.configureCalls.last?.enabled == true }
        XCTAssertEqual(max.configureCalls.last?.enabled, true,
                       "a late disable from the previous stop must not leave the relay off while running")
        model.stopByUser()
    }

    func testStopWhileBusyClearsBusyAndAllowsRestart() async {
        let max = MockMaxWeb()
        let model = makeModel(max: max)
        ScriptedTelegramProtocol.queue(updates: [[], []])

        model.busy = true
        XCTAssertFalse(model.canStart, "busy must block Start")
        model.stopByUser()
        XCTAssertFalse(model.busy, "a manual stop while busy must clear busy")
        XCTAssertTrue(model.canStart)

        await model.start()
        XCTAssertTrue(model.running)
        model.stopByUser()
    }

    func testManualStopDuringStartupCancelsIt() async {
        let max = MockMaxWeb()
        max.enableDelayMilliseconds = 250
        let model = makeModel(max: max)
        ScriptedTelegramProtocol.queue(updates: [[], []])

        let starting = Task { await model.start() }
        await waitFor { max.configureCalls.contains { $0.enabled } }
        model.stopByUser()
        await starting.value
        XCTAssertFalse(model.running, "a stop during startup must cancel the start")
        XCTAssertFalse(model.busy)
        XCTAssertTrue(max.configureCalls.contains { $0.enabled })
    }

    func testStaleReadyWhileRunningRearmsMAX() async {
        let max = MockMaxWeb()
        let model = makeModel(max: max)
        ScriptedTelegramProtocol.queue(updates: [[], []])
        await model.start()
        XCTAssertTrue(model.running)

        let before = max.configureCalls.count
        // maxReady stays true, but each `ready` is a new authenticated MAX JS
        // world where `enabled` was reset — the relay must be re-armed anyway.
        model.receive(["kind": "ready", "groups": [["id": "MAX-1", "title": "Family MAX"]]])
        model.receive(["kind": "ready", "groups": [["id": "MAX-1", "title": "Family MAX"]]])
        XCTAssertTrue(model.maxReady)
        XCTAssertTrue(model.running)
        await waitFor { max.configureCalls.count >= before + 2 }
        XCTAssertTrue(max.configureCalls.suffix(2).allSatisfy { $0.enabled },
                      "every ready while running must re-enable the MAX relay")
        XCTAssertEqual(max.configureCalls.last?.chat, "MAX-1")
        model.stopByUser()
    }

    func testTelegramToMaxTextFlowsThroughRealModelPath() async {
        let max = MockMaxWeb()
        let model = makeModel(max: max)
        let now = Int(Date().timeIntervalSince1970)

        func update(id: Int, date: Int, text: String) -> [String: Any] {
            [
                "update_id": id,
                "message": [
                    "message_id": id,
                    "date": date,
                    "chat": ["id": NSNumber(value: Int64(-100)), "type": "group", "title": "Family TG"],
                    "from": ["id": 1, "first_name": "Анна", "is_bot": false],
                    "text": text
                ] as [String: Any]
            ]
        }

        // Startup drops pending updates; the first poll delivers a fresh
        // message and an old-dated one with a newer update_id.
        ScriptedTelegramProtocol.queue(updates: [
            [update(id: 41, date: 1, text: "старое")],
            [update(id: 42, date: now + 1, text: "Привет <b>родные</b>"),
             update(id: 43, date: 1, text: "ещё старое")]
        ])

        await model.start()
        await waitFor { max.sentTexts.contains { $0.contains("Привет") } }

        XCTAssertEqual(max.sentTexts, ["Анна:\nПривет <b>родные</b>"],
                       "MAX receives verbatim plain text, not Telegram HTML")
        XCTAssertEqual(max.sentTexts.count, 1, "old-dated updates must still be filtered out")
        XCTAssertEqual(model.count, 1)
        XCTAssertEqual(model.sessionRelayCount, 1)
        XCTAssertNotNil(model.lastSuccessfulRelayAt)

        // The advanced offset is passed to the next getUpdates call.
        await waitFor { ScriptedTelegramProtocol.snapshot().offsets.contains(44) }
        let snapshot = ScriptedTelegramProtocol.snapshot()
        XCTAssertEqual(snapshot.offsets.first, -1, "startup must drop pending updates")
        XCTAssertTrue(snapshot.offsets.contains(44), "offset must advance past consumed updates")
        XCTAssertFalse(snapshot.methods.contains("sendMessage"),
                       "Telegram → MAX must not send back through Telegram")
        model.stopByUser()
    }

    // MARK: - Voice / video-note send seam (real start() → getFile → max.sendMedia)

    private func mediaUpdate(id: Int, date: Int, mediaKey: String, media: [String: Any], caption: String? = nil) -> [String: Any] {
        var message: [String: Any] = [
            "message_id": id,
            "date": date,
            "chat": ["id": NSNumber(value: Int64(-100)), "type": "group", "title": "Family TG"],
            "from": ["id": 1, "first_name": "Анна", "is_bot": false],
            mediaKey: media
        ]
        if let caption { message["caption"] = caption }
        return ["update_id": id, "message": message]
    }

    func testTelegramVoiceReachesRealMaxSendSeamWithoutCaption() async {
        let max = MockMaxWeb()
        let model = makeModel(max: max)
        let now = Int(Date().timeIntervalSince1970)
        let opusOgg = Data([0x4f, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00]) // "OggS" header
        ScriptedTelegramProtocol.queue(files: ["VOICE-1": opusOgg])
        ScriptedTelegramProtocol.queue(updates: [
            [],
            [mediaUpdate(id: 60, date: now + 1, mediaKey: "voice",
                         media: ["file_id": "VOICE-1", "file_size": opusOgg.count, "duration": 3])]
        ])

        await model.start()
        await waitFor { max.sentMedia.count == 1 }

        guard let sent = max.sentMedia.first else { model.stopByUser(); return }
        XCTAssertEqual(sent.kind.rawValue, "file", "MAX has no verified native voice attach; FILE is the playable fallback")
        XCTAssertEqual(sent.fileName, "voice.ogg")
        XCTAssertEqual(sent.mime, "audio/ogg")
        XCTAssertEqual(sent.data, opusOgg, "Opus/Ogg bytes must arrive unchanged")
        XCTAssertEqual(sent.text, "Анна:\n", "the author label is kept even with an empty caption")
        let snapshot = ScriptedTelegramProtocol.snapshot()
        XCTAssertEqual(snapshot.getFileIDs, ["VOICE-1"], "download must use the Telegram file_id")
        XCTAssertEqual(snapshot.downloadedPaths, ["VOICE-1"])
        XCTAssertFalse(snapshot.methods.contains("sendMessage"), "Telegram → MAX must not send back via Telegram")
        XCTAssertEqual(model.count, 1)
        XCTAssertTrue(model.running)
        model.stopByUser()
    }

    func testTelegramVideoNoteReachesRealMaxSendSeamWithoutCaption() async {
        let max = MockMaxWeb()
        let model = makeModel(max: max)
        let now = Int(Date().timeIntervalSince1970)
        let mp4 = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d]) // ftyp/isom
        ScriptedTelegramProtocol.queue(files: ["VIDEONOTE-1": mp4])
        ScriptedTelegramProtocol.queue(updates: [
            [],
            [mediaUpdate(id: 61, date: now + 1, mediaKey: "video_note",
                         media: ["file_id": "VIDEONOTE-1", "file_size": mp4.count, "duration": 5, "length": 240])]
        ])

        await model.start()
        await waitFor { max.sentMedia.count == 1 }

        guard let sent = max.sentMedia.first else { model.stopByUser(); return }
        XCTAssertEqual(sent.kind.rawValue, "video", "a round note falls back to an ordinary MAX video")
        XCTAssertEqual(sent.fileName, "video_note.mp4")
        XCTAssertEqual(sent.mime, "video/mp4")
        XCTAssertEqual(sent.data, mp4, "MP4 bytes must arrive unchanged")
        XCTAssertEqual(sent.text, "Анна:\n")
        let snapshot = ScriptedTelegramProtocol.snapshot()
        XCTAssertEqual(snapshot.getFileIDs, ["VIDEONOTE-1"])
        XCTAssertEqual(snapshot.downloadedPaths, ["VIDEONOTE-1"])
        XCTAssertEqual(model.count, 1)
        model.stopByUser()
    }

    func testTelegramVoiceWithCaptionKeepsAuthorAndCaption() async {
        let max = MockMaxWeb()
        let model = makeModel(max: max)
        let now = Int(Date().timeIntervalSince1970)
        let bytes = Data("opus".utf8)
        ScriptedTelegramProtocol.queue(files: ["VOICE-CAP": bytes])
        ScriptedTelegramProtocol.queue(updates: [
            [],
            [mediaUpdate(id: 62, date: now + 1, mediaKey: "voice",
                         media: ["file_id": "VOICE-CAP", "file_size": bytes.count], caption: "слушай")]
        ])

        await model.start()
        await waitFor { max.sentMedia.count == 1 }

        guard let sent = max.sentMedia.first else { model.stopByUser(); return }
        XCTAssertEqual(sent.text, "Анна:\nслушай")
        XCTAssertEqual(sent.data, bytes)
        XCTAssertEqual(max.sentTexts, [], "the caption rides with the media, not as a second message")
        model.stopByUser()
    }

    func testExistingGIFVideoAndDocumentKindsAreUnchanged() async {
        let max = MockMaxWeb()
        let model = makeModel(max: max)
        let now = Int(Date().timeIntervalSince1970)
        let bytes = Data("payload".utf8)
        ScriptedTelegramProtocol.queue(files: [
            "GIF-1": bytes, "VIDEO-1": bytes, "DOC-1": bytes
        ])
        ScriptedTelegramProtocol.queue(updates: [
            [],
            [
                mediaUpdate(id: 63, date: now + 1, mediaKey: "animation",
                            media: ["file_id": "GIF-1", "file_name": "anim.gif", "mime_type": "image/gif"]),
                mediaUpdate(id: 64, date: now + 2, mediaKey: "video",
                            media: ["file_id": "VIDEO-1", "mime_type": "video/mp4"]),
                mediaUpdate(id: 65, date: now + 3, mediaKey: "document",
                            media: ["file_id": "DOC-1", "file_name": "report.pdf", "mime_type": "application/pdf"])
            ]
        ])

        await model.start()
        await waitFor { max.sentMedia.count >= 3 }

        XCTAssertEqual(max.sentMedia.map { $0.kind.rawValue }, ["file", "video", "file"],
                       "GIF → FILE, video → VIDEO, document → FILE must not regress")
        XCTAssertEqual(max.sentMedia.map(\.fileName), ["anim.gif", "video.mp4", "report.pdf"])
        XCTAssertEqual(max.sentMedia.map(\.mime), ["image/gif", "video/mp4", "application/pdf"])
        XCTAssertEqual(model.count, 3)
        model.stopByUser()
    }

    func testOversizedVoiceIsSkippedExplicitlyWithoutStoppingTheBridge() async {
        let max = MockMaxWeb()
        let model = makeModel(max: max)
        let now = Int(Date().timeIntervalSince1970)
        ScriptedTelegramProtocol.queue(updates: [
            [],
            [mediaUpdate(id: 66, date: now + 1, mediaKey: "voice",
                         media: ["file_id": "BIG-VOICE", "file_size": 20 * 1024 * 1024 + 1],
                         caption: "важное")]
        ])

        await model.start()
        await waitFor { max.sentTexts.contains { $0.contains("важное") } }

        XCTAssertTrue(max.sentMedia.isEmpty, "a >20 MB file must not be downloaded or sent")
        XCTAssertEqual(max.sentTexts, ["Анна:\nважное"], "its caption must still be relayed")
        XCTAssertTrue(model.status.contains("20 МБ"), "the skip must be visible, not silent")
        XCTAssertTrue(ScriptedTelegramProtocol.snapshot().getFileIDs.isEmpty)
        XCTAssertTrue(model.running, "one oversized attachment must not stop the bridge")
        model.stopByUser()
    }
}
