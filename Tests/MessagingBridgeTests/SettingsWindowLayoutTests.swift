import AppKit
import SwiftUI
import XCTest
@testable import MessagingBridge

/// Regression coverage for the "Скрыть/Показать MAX" window geometry.
///
/// These tests host the real production `SettingsWindowContent` in a real
/// `NSWindow` + `NSHostingView`, inject only plain probe views (no
/// `Model.shared`, no WKWebView, no network) and measure after layout/runloop.
@MainActor
final class SettingsWindowLayoutTests: XCTestCase {
    private final class Visibility: ObservableObject {
        @Published var maxPanelVisible: Bool
        init(_ visible: Bool) { maxPanelVisible = visible }
    }

    private final class Probe: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 1) }
    }

    private final class ProbeLog {
        private(set) var views: [Probe] = []
        func add(_ view: Probe) { views.append(view) }
    }

    private struct ProbeView: NSViewRepresentable {
        let register: (Probe) -> Void
        func makeNSView(context: Context) -> Probe {
            let view = Probe()
            register(view)
            return view
        }
        func updateNSView(_ nsView: Probe, context: Context) {}
    }

    private struct Fixture: View {
        @ObservedObject var visibility: Visibility
        let menuProbe: (Probe) -> Void
        let panelProbe: (Probe) -> Void

        var body: some View {
            SettingsWindowContent(isMaxPanelVisible: visibility.maxPanelVisible) {
                ProbeView(register: menuProbe)
            } panel: {
                ProbeView(register: panelProbe)
            }
        }
    }

    private struct Harness {
        let window: NSWindow
        let hosting: NSHostingView<Fixture>
        let visibility: Visibility
        let sizer: SettingsWindowSizer
        let menuLog: ProbeLog
        let panelLog: ProbeLog
    }

    private var windows: [NSWindow] = []
    private var suites: [String] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        for window in windows {
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        suites.removeAll()
        super.tearDown()
    }

    private func makeHarness(visible: Bool) -> Harness {
        let suite = "SettingsWindowLayoutTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let sizer = SettingsWindowSizer(maxPanelVisible: visible, defaults: defaults)
        let visibility = Visibility(visible)
        let menuLog = ProbeLog()
        let panelLog = ProbeLog()

        let root = Fixture(
            visibility: visibility,
            menuProbe: { menuLog.add($0) },
            panelProbe: { panelLog.add($0) }
        )
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: sizer.initialContentWidth(panelVisible: visible),
                height: SettingsWindowMetrics.defaultContentHeight
            ),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        sizer.setMinimumSize(panelVisible: visible, for: window)
        window.contentView = hosting
        window.orderFront(nil)
        windows.append(window)

        settle(window, hosting)
        sizer.apply(panelVisible: visible, to: window)
        settle(window, hosting)

        return Harness(
            window: window,
            hosting: hosting,
            visibility: visibility,
            sizer: sizer,
            menuLog: menuLog,
            panelLog: panelLog
        )
    }

    /// Mirrors the production toggle: AppDelegate captures the current width
    /// and resizes before the model change reaches SwiftUI, then reconciles
    /// once more on the next runloop turn after SwiftUI rebuilds its content.
    private func setVisible(_ visible: Bool, _ harness: Harness) {
        harness.sizer.apply(panelVisible: visible, to: harness.window)
        harness.visibility.maxPanelVisible = visible
        settle(harness.window, harness.hosting)
        harness.sizer.apply(panelVisible: visible, to: harness.window)
        settle(harness.window, harness.hosting)
    }

    private func settle(_ window: NSWindow, _ view: NSView) {
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
    }

    private func windowWidth(_ harness: Harness) -> CGFloat {
        harness.window.frame.width
    }

    private func menuWidth(_ harness: Harness) -> CGFloat {
        harness.menuLog.views.last?.frame.width ?? -1
    }

    private func panelWidth(_ harness: Harness) -> CGFloat {
        harness.panelLog.views.last?.frame.width ?? -1
    }

    func testDefaultLayoutUses400ptMenuAndRemainingWidthForMax() {
        let harness = makeHarness(visible: true)

        XCTAssertEqual(windowWidth(harness), 1100, accuracy: 2,
                       "the settings window opens at its default width")
        XCTAssertEqual(menuWidth(harness), 400, accuracy: 2,
                       "the menu pane is ~400pt by default, not half of the window")
        XCTAssertEqual(panelWidth(harness), 700, accuracy: 3,
                       "the MAX panel gets everything to the right of the 400pt menu")
        XCTAssertEqual(harness.window.contentMinSize.width, 820, accuracy: 0.5)
    }

    func testHidingMaxShrinksWindowToMenuWidthWithoutStretchingMenu() {
        let harness = makeHarness(visible: true)
        let panelView = harness.panelLog.views.first
        XCTAssertNotNil(panelView)

        setVisible(false, harness)

        XCTAssertEqual(windowWidth(harness), 400, accuracy: 2,
                       "hiding MAX must shrink the window to the previous menu width")
        XCTAssertEqual(menuWidth(harness), 400, accuracy: 2,
                       "the menu must not stretch when MAX is hidden")
        XCTAssertEqual(panelWidth(harness), 0, accuracy: 1,
                       "the MAX panel is collapsed, not removed")
        XCTAssertEqual(harness.window.contentMinSize.width, 400, accuracy: 0.5)

        XCTAssertEqual(harness.panelLog.views.count, 1,
                       "the panel NSView must not be recreated on hide")
        XCTAssertTrue(harness.panelLog.views.first === panelView,
                      "the same panel NSView (WebView host) must stay mounted")
        XCTAssertNotNil(harness.panelLog.views.first?.superview,
                        "the collapsed panel stays in the view hierarchy")
    }

    func testShowingMaxRestoresPreviousExpandedSize() {
        let harness = makeHarness(visible: true)
        setVisible(false, harness)
        XCTAssertEqual(windowWidth(harness), 400, accuracy: 2)

        setVisible(true, harness)

        XCTAssertEqual(windowWidth(harness), 1100, accuracy: 2,
                       "showing MAX restores the pre-hide window size")
        XCTAssertEqual(menuWidth(harness), 400, accuracy: 2)
        XCTAssertEqual(panelWidth(harness), 700, accuracy: 3)
        XCTAssertEqual(harness.window.contentMinSize.width, 820, accuracy: 0.5)
    }

    func testRepeatedHideShowCyclesDoNotDrift() {
        let harness = makeHarness(visible: true)
        let initialMenu = menuWidth(harness)

        for cycle in 0..<6 {
            setVisible(false, harness)
            XCTAssertEqual(windowWidth(harness), 400, accuracy: 2, "hide cycle \(cycle)")
            XCTAssertEqual(menuWidth(harness), initialMenu, accuracy: 2, "menu width cycle \(cycle)")

            setVisible(true, harness)
            XCTAssertEqual(windowWidth(harness), 1100, accuracy: 2, "show cycle \(cycle)")
            XCTAssertEqual(menuWidth(harness), initialMenu, accuracy: 2, "menu width cycle \(cycle)")
            XCTAssertEqual(panelWidth(harness), 700, accuracy: 3, "panel width cycle \(cycle)")
        }
    }

    func testManualResizeIsRestoredAfterHideShow() {
        let harness = makeHarness(visible: true)
        harness.window.setContentSize(NSSize(width: 1400, height: 720))
        settle(harness.window, harness.hosting)
        XCTAssertEqual(windowWidth(harness), 1400, accuracy: 2)

        setVisible(false, harness)
        XCTAssertEqual(windowWidth(harness), 400, accuracy: 2)

        setVisible(true, harness)
        XCTAssertEqual(windowWidth(harness), 1400, accuracy: 2,
                       "the resized width, not the original default, must be restored")
        XCTAssertEqual(menuWidth(harness), 400, accuracy: 2)
        XCTAssertEqual(panelWidth(harness), 1000, accuracy: 3)
    }
}
