import AppKit
import SwiftUI

/// Single source of truth for the settings window geometry.
///
/// The window always shows the fixed-width menu (left) pane. The MAX panel is
/// mounted eagerly and only collapsed to zero width, so hiding it never tears
/// down the `WKWebView`. Hiding "MAX" therefore shrinks the window to exactly
/// the menu width instead of reflowing/stretching the menu.
enum SettingsWindowMetrics {
    /// The menu pane is always this wide, both when MAX is visible and hidden.
    static let menuWidth: CGFloat = 400
    /// The MAX panel may never be narrower than this while visible.
    static let maxPanelMinWidth: CGFloat = 420
    static let maxPanelMinHeight: CGFloat = 500
    static let minContentHeight: CGFloat = 600
    static let defaultContentWidth: CGFloat = 1100
    static let defaultContentHeight: CGFloat = 720

    /// 400 (menu) + 420 (smallest usable MAX panel).
    static var expandedMinContentWidth: CGFloat { menuWidth + maxPanelMinWidth }

    static func minContentWidth(maxPanelVisible: Bool) -> CGFloat {
        maxPanelVisible ? expandedMinContentWidth : menuWidth
    }

    static func minContentSize(maxPanelVisible: Bool) -> NSSize {
        NSSize(width: minContentWidth(maxPanelVisible: maxPanelVisible), height: minContentHeight)
    }
}

/// The production settings layout, parameterised so tests can inject plain
/// views instead of `Model.shared`/WKWebView.
struct SettingsWindowContent<MenuContent: View, PanelContent: View>: View {
    let isMaxPanelVisible: Bool
    private let menu: MenuContent
    private let panel: PanelContent

    init(
        isMaxPanelVisible: Bool,
        @ViewBuilder menu: () -> MenuContent,
        @ViewBuilder panel: () -> PanelContent
    ) {
        self.isMaxPanelVisible = isMaxPanelVisible
        self.menu = menu()
        self.panel = panel()
    }

    var body: some View {
        HStack(spacing: 0) {
            menu
                .frame(width: SettingsWindowMetrics.menuWidth)
            panel
                .frame(
                    minWidth: isMaxPanelVisible ? SettingsWindowMetrics.maxPanelMinWidth : 0,
                    maxWidth: isMaxPanelVisible ? .infinity : 0,
                    minHeight: SettingsWindowMetrics.maxPanelMinHeight
                )
                .opacity(isMaxPanelVisible ? 1 : 0)
                .clipped()
                .allowsHitTesting(isMaxPanelVisible)
                .accessibilityHidden(!isMaxPanelVisible)
        }
        .frame(
            minWidth: SettingsWindowMetrics.minContentWidth(maxPanelVisible: isMaxPanelVisible),
            minHeight: SettingsWindowMetrics.minContentHeight
        )
    }
}

/// Keeps the real `NSWindow` size in sync with the MAX panel state.
///
/// * visible -> hidden: remember the current expanded width, shrink the window
///   to the menu width only;
/// * hidden -> visible: restore the remembered expanded width;
/// * repeated toggles and manual resizes never accumulate drift.
///
/// The expanded width is also persisted separately from the window frame
/// autosave, because autosave records the narrow frame while MAX is hidden.
final class SettingsWindowSizer {
    private static let expandedWidthKey = "MessagingBridge.settingsWindow.expandedContentWidth"

    private(set) var maxPanelVisible: Bool
    /// Last width of the window while the MAX panel was visible.
    private(set) var expandedContentWidth: CGFloat?
    private let defaults: UserDefaults?

    init(maxPanelVisible: Bool = true, defaults: UserDefaults? = .standard) {
        self.maxPanelVisible = maxPanelVisible
        self.defaults = defaults
        if let stored = defaults?.object(forKey: Self.expandedWidthKey) as? NSNumber {
            let width = CGFloat(truncating: stored)
            if width >= SettingsWindowMetrics.expandedMinContentWidth {
                expandedContentWidth = width
            }
        }
    }

    /// Initial content width before the autosaved frame is restored.
    func initialContentWidth(panelVisible: Bool) -> CGFloat {
        panelVisible
            ? max(expandedContentWidth ?? SettingsWindowMetrics.defaultContentWidth,
                  SettingsWindowMetrics.expandedMinContentWidth)
            : SettingsWindowMetrics.menuWidth
    }

    /// Applies the matching minimum size without resizing.
    func setMinimumSize(panelVisible: Bool, for window: NSWindow) {
        window.contentMinSize = SettingsWindowMetrics.minContentSize(maxPanelVisible: panelVisible)
    }

    /// Reconciles the window with the requested panel state. Safe to call
    /// repeatedly for the same state (idempotent, no drift).
    func apply(panelVisible visible: Bool, to window: NSWindow) {
        setMinimumSize(panelVisible: visible, for: window)

        if maxPanelVisible && !visible {
            let current = contentWidth(of: window)
            if current >= SettingsWindowMetrics.expandedMinContentWidth {
                rememberExpanded(current)
            }
        }
        maxPanelVisible = visible

        let target: CGFloat
        if visible {
            let current = contentWidth(of: window)
            let base = expandedContentWidth
                ?? (current >= SettingsWindowMetrics.expandedMinContentWidth
                    ? current
                    : SettingsWindowMetrics.defaultContentWidth)
            let expanded = max(base, SettingsWindowMetrics.expandedMinContentWidth)
            rememberExpanded(expanded)
            target = expanded
        } else {
            target = SettingsWindowMetrics.menuWidth
        }
        setContentWidth(target, of: window)
    }

    private func rememberExpanded(_ width: CGFloat) {
        expandedContentWidth = width
        defaults?.set(Double(width), forKey: Self.expandedWidthKey)
    }

    private func contentWidth(of window: NSWindow) -> CGFloat {
        window.contentRect(forFrameRect: window.frame).width
    }

    private func setContentWidth(_ width: CGFloat, of window: NSWindow) {
        let current = contentWidth(of: window)
        guard abs(current - width) > 0.5 else { return }
        var frame = window.frame
        frame.size.width += width - current
        window.setFrame(frame, display: true)
    }
}
