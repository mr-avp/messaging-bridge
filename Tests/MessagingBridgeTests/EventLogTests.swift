import Foundation
import XCTest
@testable import MessagingBridge

@MainActor
final class EventLogTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventLogTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        super.tearDown()
    }

    func testRecordPersistAndReload() {
        let log = EventLog(fileURL: tempURL)
        log.record(.appStart, level: .info)
        log.record(.bridgeStart, level: .info)
        XCTAssertEqual(log.entries.count, 2)

        let reloaded = EventLog(fileURL: tempURL)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.entries.first?.event, .appStart)
        XCTAssertEqual(reloaded.entries.last?.event, .bridgeStart)
    }

    func testClearRemovesEntriesAndFile() {
        let log = EventLog(fileURL: tempURL)
        log.record(.appStart)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testRotationByCount() {
        let log = EventLog(fileURL: tempURL, maxEvents: 3, maxBytes: 1_048_576)
        for _ in 0..<5 {
            log.record(.recoveryAttempt)
        }
        XCTAssertEqual(log.entries.count, 3)
        let reloaded = EventLog(fileURL: tempURL, maxEvents: 3, maxBytes: 1_048_576)
        XCTAssertEqual(reloaded.entries.count, 3)
    }

    func testRotationBySize() {
        let log = EventLog(fileURL: tempURL, maxEvents: 1000, maxBytes: 256)
        for _ in 0..<50 {
            log.record(.recoveryAttempt)
        }
        XCTAssertLessThanOrEqual(try! Data(contentsOf: tempURL).count, 256)
        XCTAssertGreaterThan(log.entries.count, 0)
    }

    func testPrivacyNoForbiddenContent() {
        let log = EventLog(fileURL: tempURL)
        log.record(.maxConnect, level: .info)
        log.record(.recoveryError(.temporary), level: .warning, category: .temporary)
        let raw = try! String(contentsOf: tempURL)
        let forbidden = ["secret", "token", "http://", "https://", "chat", "user", "password"]
        for word in forbidden {
            XCTAssertFalse(raw.lowercased().contains(word), "log contains forbidden word: \(word)")
        }
    }

    func testFilePermissions() {
        let log = EventLog(fileURL: tempURL)
        log.record(.appStart)
        let attrs = try! FileManager.default.attributesOfItem(atPath: tempURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testGracefulIOFailureKeepsInMemory() {
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-dir")
            .appendingPathComponent("events.jsonl")
        // Make parent a file to force directory creation failure.
        try? "block".write(to: badURL.deletingLastPathComponent(), atomically: true, encoding: .utf8)
        let log = EventLog(fileURL: badURL)
        log.record(.appStart)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertNotNil(log.lastError)
        try? FileManager.default.removeItem(at: badURL.deletingLastPathComponent())
    }

    func testLevelAndCategoryPersist() {
        let log = EventLog(fileURL: tempURL)
        log.record(.recoveryError(.temporary), level: .warning, category: .temporary)
        let entry = log.entries.first!
        XCTAssertEqual(entry.level, .warning)
        XCTAssertEqual(entry.category, .temporary)
        XCTAssertEqual(entry.event, .recoveryError(.temporary))
    }
    func testUnknownEventDoesNotDecodeAsAppStart() {
        let data = Data("\"unknownEvent\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EventLog.Event.self, from: data))
    }

    func testBoundedLoadDoesNotReadUnboundedFile() {
        let big = Data(repeating: 0x20, count: 1024)
        // Write a file larger than maxBytes and ensure load does not crash.
        let dir = tempURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? big.write(to: tempURL)
        let log = EventLog(fileURL: tempURL, maxEvents: 10, maxBytes: 256)
        XCTAssertLessThanOrEqual(log.entries.count, 10)
    }

}
