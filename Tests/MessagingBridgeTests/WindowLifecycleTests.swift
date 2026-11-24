import AppKit
import XCTest
@testable import MessagingBridge

@MainActor
final class WindowLifecycleTests: XCTestCase {
    private var delegates: [AppDelegate] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        for delegate in delegates {
            delegate.settingsWindow?.delegate = nil
            delegate.settingsWindow?.orderOut(nil)
            delegate.settingsWindow?.close()
        }
        delegates.removeAll()
        super.tearDown()
    }

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        // The window factory is the only injected part: no Model/WebKit/EventLog is touched here.
        delegate.makeSettingsContent = { NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600)) }
        delegates.append(delegate)
        return delegate
    }

    private func assertVisibleOnSomeScreen(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let screens = NSScreen.screens.map(\.visibleFrame)
        XCTAssertTrue(window.isVisible, "window must be visible", file: file, line: line)
        XCTAssertTrue(
            screens.contains { $0.intersection(window.frame).width >= window.frame.width - 1
                && $0.intersection(window.frame).height >= window.frame.height - 1 },
            "window frame \(window.frame) must be fully inside a visible screen frame \(screens)",
            file: file, line: line
        )
    }

    // Regression for the GUI blocker: the menu action and Dock/Finder reopen both call showWindow()
    // when no window exists. The old code returned early because NSApp.windows was empty.
    func testMenuOpenCreatesSettingsWindowWhenNoneExists() {
        let delegate = makeDelegate()
        XCTAssertNil(delegate.settingsWindow)

        delegate.showWindow() // exactly what "Открыть Мост" calls

        let window = delegate.settingsWindow
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.title, settingsWindowTitle)
        XCTAssertFalse(window?.isReleasedWhenClosed ?? true)
        XCTAssertTrue(window?.contentView is NSView)
        assertVisibleOnSomeScreen(window!)
    }

    func testReopenCreatesWindowWhenSceneWindowIsGone() {
        let delegate = makeDelegate()
        XCTAssertNil(delegate.settingsWindow)

        let result = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)

        XCTAssertFalse(result, "reopen must be handled manually")
        XCTAssertNotNil(delegate.settingsWindow, "reopen must recreate the missing settings window")
        assertVisibleOnSomeScreen(delegate.settingsWindow!)
    }

    func testCloseButtonHidesInsteadOfClosing() {
        let delegate = makeDelegate()
        delegate.showWindow()
        let window = delegate.settingsWindow!

        let shouldClose = delegate.windowShouldClose(window)

        XCTAssertFalse(shouldClose, "the close button must not destroy the window")
        XCTAssertFalse(window.isVisible, "closing must hide the window")
        XCTAssertTrue(delegate.settingsWindow === window, "the same window must be kept for the next open")
    }

    func testRepeatedHideShowReusesSameWindow() {
        let delegate = makeDelegate()
        delegate.showWindow()
        let window = delegate.settingsWindow!

        for _ in 0..<5 {
            delegate.hideWindow()
            XCTAssertFalse(window.isVisible)
            delegate.showWindow()
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(delegate.settingsWindow === window, "hide/show must reuse the singleton")
        }
    }

    func testRepeatedToggleDoesNotMultiplyWindows() {
        let delegate = makeDelegate()
        delegate.showWindow()
        let window = delegate.settingsWindow!
        let baseline = NSApp.windows.filter { $0.title == settingsWindowTitle }.count

        for _ in 0..<6 { delegate.toggleWindow() }

        let matching = NSApp.windows.filter { $0.title.contains("Мост сообщений") }
        XCTAssertEqual(matching.count, baseline, "repeated toggles must keep the same number of windows")
        XCTAssertTrue(delegate.settingsWindow === window)
    }

    func testClosedSceneWindowIsReplacedOnNextOpen() {
        let delegate = makeDelegate()
        delegate.showWindow()
        let first = delegate.settingsWindow!

        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: first))
        XCTAssertNil(delegate.settingsWindow)

        delegate.showWindow()
        XCTAssertNotNil(delegate.settingsWindow)
        XCTAssertFalse(delegate.settingsWindow === first, "a destroyed window must be recreated")
        assertVisibleOnSomeScreen(delegate.settingsWindow!)
    }

    func testOffscreenWindowIsMovedOntoVisibleScreen() {
        let delegate = makeDelegate()
        delegate.showWindow()
        let window = delegate.settingsWindow!
        window.setFrameOrigin(NSPoint(x: 100_000, y: 100_000))

        delegate.showWindow()

        assertVisibleOnSomeScreen(window)
    }

    func testLastWindowClosedDoesNotTerminateApp() {
        let delegate = makeDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }
}
