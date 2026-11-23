import XCTest
@testable import MessagingBridge

@MainActor
final class ModelTests: XCTestCase {
    private var savedConnections: Data?
    private var savedLegacyConnections: Data?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedConnections = defaults.data(forKey: "messaging-bridge.connections")
        savedLegacyConnections = defaults.data(forKey: "family-relay.connections")
        defaults.removeObject(forKey: "messaging-bridge.connections")
        defaults.removeObject(forKey: "family-relay.connections")
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let savedConnections { defaults.set(savedConnections, forKey: "messaging-bridge.connections") }
        if let savedLegacyConnections { defaults.set(savedLegacyConnections, forKey: "family-relay.connections") }
        super.tearDown()
    }

    func testMaxLoadsOfficialWebClient() {
        XCTAssertEqual(MaxWeb.endpoint.absoluteString, "https://web.max.ru",
                       "The panel must load the official MAX web client, not a placeholder")
    }

    func testReadySetsMaxReady() {
        let model = Model()
        model.receive(["kind": "ready", "groups": []])
        XCTAssertTrue(model.maxReady, "receive(ready) must set maxReady=true")
    }

    func testAutoSelectsFirstAvailableGroup() {
        let model = Model()
        model.receive(["kind": "ready", "groups": [
            ["id": "-814", "title": "Family chat"],
            ["id": "-815", "title": "Another chat"]
        ]])
        XCTAssertEqual(model.maxID, "-814", "the first available group should be preselected, no hardcoded group names")
    }

    func testPartialGroupUpdateKeepsSelection() {
        let model = Model()
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
