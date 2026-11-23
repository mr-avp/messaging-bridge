import XCTest
@testable import FamilyRelay

@MainActor
final class ModelTests: XCTestCase {
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
