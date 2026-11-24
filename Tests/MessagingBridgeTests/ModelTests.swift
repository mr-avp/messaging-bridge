import XCTest
@testable import MessagingBridge

@MainActor
final class ModelTests: XCTestCase {
    private let suiteName = "MessagingBridgeTests." + UUID().uuidString
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAutoStartPersistsOnlyAfterLaunchAgentChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("LaunchAgents/local.messaging-bridge.plist")
        let key = "messaging-bridge.auto-start"
        let model = Model(defaults: defaults)

        model.setAutoStart(true, launchAgentURL: url, executablePath: "")
        XCTAssertFalse(model.autoStart)
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        try Data().write(to: root)
        model.setAutoStart(true, launchAgentURL: url, executablePath: "/test/MessagingBridge")
        XCTAssertFalse(model.autoStart)
        XCTAssertNil(defaults.object(forKey: key))
        try FileManager.default.removeItem(at: root)

        model.setAutoStart(true, launchAgentURL: url, executablePath: "/test/MessagingBridge")
        XCTAssertTrue(model.autoStart)
        XCTAssertTrue(defaults.bool(forKey: key))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil
        ) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/test/MessagingBridge"])

        model.setAutoStart(false, launchAgentURL: url)
        XCTAssertFalse(model.autoStart)
        XCTAssertFalse(defaults.bool(forKey: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTrayIconLoadsFromSwiftPMResources() throws {
        let image = try XCTUnwrap(loadTrayIcon())
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertFalse(image.isTemplate)
    }

    func testMaxLoadsOfficialWebClient() {
        XCTAssertEqual(MaxWeb.endpoint.absoluteString, "https://web.max.ru",
                       "The panel must load the official MAX web client, not a placeholder")
    }

    func testReadySetsMaxReady() {
        let model = Model(defaults: defaults)
        model.receive(["kind": "ready", "groups": []])
        XCTAssertTrue(model.maxReady, "receive(ready) must set maxReady=true")
    }

    func testAutoSelectsFirstAvailableGroup() {
        let model = Model(defaults: defaults)
        model.receive(["kind": "ready", "groups": [
            ["id": "-814", "title": "Family chat"],
            ["id": "-815", "title": "Another chat"]
        ]])
        XCTAssertEqual(model.maxID, "-814", "the first available group should be preselected, no hardcoded group names")
    }

    func testPartialGroupUpdateKeepsSelection() {
        let model = Model(defaults: defaults)
        model.receive(["kind": "ready", "groups": [
            ["id": "-100", "title": "test_max"],
            ["id": "-200", "title": "other"]
        ]])
        model.maxID = "-100"
        model.receive(["kind": "groups", "groups": [["id": "-300", "title": "third"]]])
        XCTAssertEqual(model.maxID, "-100", "a partial chat list must not clear the chosen group")
        XCTAssertEqual(Set(model.maxGroups.map(\.id)), ["-100", "-200", "-300"])
    }
}
