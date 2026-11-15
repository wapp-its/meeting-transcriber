// The panel that shows the open recording questions below the menu bar icon
// (issue #99). The AppKit shell only: what it shows is its host's root view.
import AppKit
import SwiftUI

/// A borderless, non-activating panel that takes mouse clicks but never
/// becomes the key or main window, so showing it and clicking its buttons
/// leave the meeting app frontmost, and no key press can answer it.
///
/// The live caption panel's recipe (`LiveCaptionsWindowController`), minus
/// its click-through and `.stationary`, plus the naming window's Space and
/// full-screen behaviour (`NamingWindowPolicy`). Measured on macOS 26 in a
/// throwaway helper app with another app frontmost: one real mouse click,
/// posted from outside the helper onto a SwiftUI button in such a panel, ran
/// the button's action; the helper stayed inactive, the panel never became
/// key and the other app stayed frontmost.
final class PromptPanel: NSPanel {
    /// So the debug `/state.windows` lists the panel.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("recording-prompts")

    /// The panel's content view; set its `rootView` to change what it shows.
    let host = PromptHostingView(rootView: AnyView(EmptyView()))

    convenience init(size: CGSize) {
        self.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        contentView = host
        identifier = Self.windowIdentifier
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        sharingType = .none
        // Each flag belongs to an exclusive group, see `NamingWindowPolicy`.
        collectionBehavior = collectionBehavior
            .subtracting([.managed, .moveToActiveSpace, .stationary, .fullScreenPrimary, .fullScreenNone])
            .union([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// The prompt panel's hosting view. It accepts the first mouse, so a click
/// on the panel, which is never key, goes to the button under it. A plain
/// `NSHostingView` answers false here, although in the measurement above its
/// button also ran on the first click; the panel does not rely on that.
final class PromptHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}
