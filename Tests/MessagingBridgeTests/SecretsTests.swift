import XCTest
@testable import MessagingBridge

final class SecretsTests: XCTestCase {
    private final class Store: TokenStore {
        var value: String?
        var failRead = false
        var failWrite = false
        var failDelete = false
        var writes = 0
        var reads = 0

        init(_ value: String? = nil) { self.value = value }

        func read() throws -> String? {
            reads += 1
            if failRead { throw RelayError.storage }
            return value
        }

        func save(_ value: String) throws {
            writes += 1
            if failWrite { throw RelayError.storage }
            self.value = value
        }

        func delete() throws {
            if failDelete { throw RelayError.storage }
            value = nil
        }
    }

    func testFailedMigrationKeepsLegacyTokenAndNextLaunchRetries() {
        let keychain = Store()
        let legacy = Store("old")
        keychain.failWrite = true

        XCTAssertEqual(TokenStorage(keychain: keychain, legacy: legacy).read(), "old")
        XCTAssertEqual(legacy.value, "old")
        XCTAssertNil(keychain.value)
        XCTAssertEqual(keychain.writes, 1)

        keychain.failWrite = false
        XCTAssertEqual(TokenStorage(keychain: keychain, legacy: legacy).read(), "old")
        XCTAssertNil(legacy.value)
        XCTAssertEqual(keychain.value, "old")
        XCTAssertEqual(TokenStorage(keychain: keychain, legacy: legacy).read(), "old")
        XCTAssertEqual(keychain.writes, 2)
    }

    func testReadFailureDoesNotOverwriteKeychainOrRemoveLegacy() {
        let keychain = Store("current")
        let legacy = Store("old")
        keychain.failRead = true

        let storage = TokenStorage(keychain: keychain, legacy: legacy)
        XCTAssertThrowsError(try storage.readChecked())
        XCTAssertEqual(storage.read(), "")
        XCTAssertEqual(legacy.reads, 0)
        XCTAssertEqual(keychain.value, "current")
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertEqual(legacy.value, "old")
    }

    func testSaveKeepsExistingDataOnFailureAndClearsLegacyOnSuccess() throws {
        let keychain = Store("current")
        let legacy = Store("old")
        let storage = TokenStorage(keychain: keychain, legacy: legacy)
        keychain.failWrite = true

        XCTAssertThrowsError(try storage.save("new"))
        XCTAssertEqual(keychain.value, "current")
        XCTAssertEqual(legacy.value, "old")

        keychain.failWrite = false
        try storage.save("new")
        XCTAssertEqual(keychain.value, "new")
        XCTAssertNil(legacy.value)
    }

    func testDeleteClearsLegacyEvenWhenKeychainFailsAndCanBeRetried() throws {
        let keychain = Store("current")
        let legacy = Store("old")
        let storage = TokenStorage(keychain: keychain, legacy: legacy)
        keychain.failDelete = true

        XCTAssertThrowsError(try storage.delete())
        XCTAssertNil(legacy.value)
        XCTAssertEqual(keychain.value, "current")

        keychain.failDelete = false
        try storage.delete()
        try storage.delete()
        XCTAssertEqual(TokenStorage(keychain: keychain, legacy: legacy).read(), "")
        XCTAssertNil(keychain.value)
    }

    @MainActor
    func testManualAndAutomaticRestoreReportReadFailureWithoutUsingLegacy() async {
        let keychain = Store()
        let legacy = Store("synthetic-legacy")
        keychain.failRead = true
        let suite = "MessagingBridgeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = Model(defaults: defaults, secrets: TokenStorage(keychain: keychain, legacy: legacy))
        model.token = "synthetic-draft"

        model.restoreToken()
        XCTAssertTrue(model.status.contains("Не удалось прочитать"))
        XCTAssertEqual(model.token, "synthetic-draft")

        model.status = ""
        await model.restoreAndConnect()
        XCTAssertTrue(model.status.contains("Не удалось прочитать"))
        XCTAssertEqual(model.token, "synthetic-draft")
        XCTAssertFalse(model.hasTelegram)
        XCTAssertEqual(legacy.reads, 0)

        keychain.failRead = false
        legacy.value = nil
        model.restoreToken()
        XCTAssertTrue(model.status.contains("Токен не найден"))
        XCTAssertEqual(model.token, "")
    }

    @MainActor
    func testModelPreservesTokenOnPartialDeleteAndClearsItAfterRetry() {
        let keychain = Store("synthetic-current")
        let legacy = Store("synthetic-legacy")
        let suite = "MessagingBridgeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = Model(defaults: defaults, secrets: TokenStorage(keychain: keychain, legacy: legacy))
        model.restoreToken()
        keychain.failDelete = true

        model.deleteToken()
        XCTAssertTrue(model.status.contains("Не удалось полностью удалить"))
        XCTAssertEqual(model.token, "synthetic-current")
        XCTAssertEqual(keychain.value, "synthetic-current")
        XCTAssertNil(legacy.value)

        keychain.failDelete = false
        model.deleteToken()
        XCTAssertTrue(model.status.contains("Токен удалён"))
        XCTAssertEqual(model.token, "")
        XCTAssertNil(keychain.value)
        XCTAssertNil(legacy.value)
    }
}
