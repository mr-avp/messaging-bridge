import AppKit
import XCTest
@testable import MessagingBridge

@MainActor
final class WindowLifecycleTests: XCTestCase {
    private let title = "Мост сообщений (Messaging Bridge)"

    override func tearDown() {
        for window in NSApp.windows where window.title.contains("Мост сообщений") {
            window.orderOut(nil)
        }
        super.tearDown()
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func testCloseButtonHidesInsteadOfClosing() {
        let window = makeWindow()
        let delegate = AppDelegate()

        let shouldClose = delegate.windowShouldClose(window)

        XCTAssertFalse(shouldClose, "the close button must not destroy the window")
        XCTAssertFalse(window.isVisible, "closing must hide the window")
        XCTAssertTrue(NSApp.windows.contains(window), "the same window must remain alive")
    }

    func testRepeatedHideShowReusesSameWindow() {
        let window = makeWindow()
        let delegate = AppDelegate()
        let baseline = NSApp.windows.filter { $0.title.contains("Мост сообщений") }.count

        for _ in 0..<5 {
            delegate.hideWindow()
            XCTAssertFalse(window.isVisible)
            delegate.showWindow()
            XCTAssertTrue(window.isVisible)
        }

        let matching = NSApp.windows.filter { $0.title.contains("Мост сообщений") }
        XCTAssertEqual(matching.count, baseline, "hide/show must not multiply windows")
        XCTAssertTrue(matching.contains(window), "the original window must be reused")
    }

    func testRepeatedToggleDoesNotMultiplyWindows() {
        let window = makeWindow()
        let delegate = AppDelegate()
        let baseline = NSApp.windows.filter { $0.title.contains("Мост сообщений") }.count

        for _ in 0..<6 {
            delegate.toggleWindow()
        }

        let matching = NSApp.windows.filter { $0.title.contains("Мост сообщений") }
        XCTAssertEqual(matching.count, baseline, "repeated toggles must keep the same number of windows")
        XCTAssertTrue(matching.contains(window))
    }

    func testReopenReusesExistingWindow() {
        let window = makeWindow()
        let delegate = AppDelegate()
        delegate.hideWindow()
        let before = NSApp.windows.filter { $0.title.contains("Мост сообщений") }.count

        let result = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)

        XCTAssertFalse(result, "reopen must be handled manually")
        XCTAssertTrue(window.isVisible, "reopen must show the existing window")
        let after = NSApp.windows.filter { $0.title.contains("Мост сообщений") }.count
        XCTAssertEqual(after, before, "reopen must not create a duplicate window")
    }

    func testLastWindowClosedDoesNotTerminateApp() {
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }
}
