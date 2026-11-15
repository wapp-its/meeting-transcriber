// Where the app's menu bar icon is on screen, read from the window AppKit
// creates for the menu bar item, for placing the prompt window (issue #99).
import AppKit

/// SwiftUI's `MenuBarExtra` does not hand out its status item, so the icon's
/// frame is read from the app's own windows. Measured on macOS 26 in a
/// throwaway helper app with a `MenuBarExtra` (the installed app cannot run
/// probe code):
///
/// - Each display that shows a menu bar gets its own window for the item, of
///   class `NSStatusBarWindow` at `.statusBar` level, as wide as the icon and
///   as tall as that display's menu bar.
/// - An icon pushed into the notch overflow keeps a window on the screen,
///   behind the notch; so do items pushed further left, over the app menus.
///   Only the occlusion state tells that they are not visible.
/// - An item that is not inserted keeps a window with an empty frame, or one
///   off every screen.
enum MenuBarIconFrame {
    /// What the lookup reads of one of the app's windows.
    struct Candidate: Equatable {
        var className: String
        var level: NSWindow.Level
        var frame: CGRect
        /// Whether any part of the window is visible on screen
        /// (`NSWindow.occlusionState`).
        var isVisible: Bool
    }

    static let iconWindowClassName = "NSStatusBarWindow"

    /// The frame of a visible icon window with a non-empty frame: the one on
    /// `menuBarScreen` (the frame of the screen with the menu bar) when there
    /// is one, else the first in `windows`. Nil when no window qualifies.
    static func frame(among windows: [Candidate], menuBarScreen: CGRect?) -> CGRect? {
        let icons = windows.filter { window in
            window.className == iconWindowClassName && window.level == .statusBar
                && window.isVisible && !window.frame.isEmpty
        }
        let onMenuBarScreen = menuBarScreen.flatMap { screen in
            icons.first { screen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        }
        return (onMenuBarScreen ?? icons.first)?.frame
    }

    /// The icon's frame among `app`'s windows; nil when `app` is nil, as
    /// `NSApp` is in an xctest process.
    @MainActor
    static func frame(in app: NSApplication?, menuBarScreen: CGRect?) -> CGRect? {
        frame(among: app?.windows.map(Candidate.init) ?? [], menuBarScreen: menuBarScreen)
    }
}

@MainActor
extension MenuBarIconFrame.Candidate {
    init(_ window: NSWindow) {
        self.init(
            className: NSStringFromClass(type(of: window)),
            level: window.level,
            frame: window.frame,
            isVisible: window.occlusionState.contains(.visible),
        )
    }
}
