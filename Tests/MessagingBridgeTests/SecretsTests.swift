import XCTest
@testable import MessagingBridge

final class SecretsTests: XCTestCase {
    private final class Store: TokenStore {
        var value: String?
        var failRead = false
        var failWrite = false
        var failDelete = false
        var writes = 0

        init(_ value: String? = nil) { self.value = value }

        func read() throws -> String? {
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

        XCTAssertEqual(TokenStorage(keychain: keychain, legacy: legacy).read(), "")
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
}
