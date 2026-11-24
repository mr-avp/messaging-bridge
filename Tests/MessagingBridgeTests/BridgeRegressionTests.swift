import XCTest
@testable import MessagingBridge

/// A MAX mock that subclasses the internal (non-final) MaxWeb class through
/// @testable — no public API is needed. It records the real calls the Model
/// makes and can delay each configure to emulate slow MAX JavaScript.
@MainActor
private final class MockMaxWeb: MaxWeb {
    private(set) var sentTexts: [String] = []
    private(set) var sentMedia: [(chat: String, kind: MaxMediaKind, text: String)] = []
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
        sentMedia.append((chat, kind, text))
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

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        updatesQueue = []
        updateOffsets = []
        sentMessages = []
        methods = []
    }

    static func queue(updates: [[[String: Any]]]) {
        lock.lock(); defer { lock.unlock() }
        updatesQueue = updates
    }

    static func snapshot() -> (methods: [String], offsets: [Int], sent: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        return (methods, updateOffsets, sentMessages)
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
        if method == "getUpdates" {
            Self.updateOffsets.append(payload["offset"] as? Int ?? Int.min)
            result = Self.updatesQueue.isEmpty ? [] : Self.updatesQueue.removeFirst()
        } else if method == "sendMessage" {
            Self.sentMessages.append(payload)
            result = ["message_id": 1]
        }
        Self.lock.unlock()

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
}
