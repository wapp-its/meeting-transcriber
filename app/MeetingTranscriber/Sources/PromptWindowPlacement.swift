// Where the prompt window (issue #99) is placed: below the menu bar icon, or
// at the top right below the menu bar. Pure, over plain rects, so every case
// can be pinned without a display.
import CoreGraphics

enum PromptWindowPlacement {
    /// The space between the window's top edge and the icon or the menu bar
    /// above it, and between the window and a screen's side edge.
    static let gap: CGFloat = 6

    /// The origin of a window of `size`, or nil when no screen has a usable
    /// frame.
    ///
    /// - With `iconFrame` (`MenuBarIconFrame`) on a screen: centred under
    ///   the icon, its top edge `gap` below the icon's bottom, kept inside
    ///   that screen's frame and `gap` off its sides.
    /// - Otherwise, also when the icon frame lies on no screen: at the top
    ///   right of the first screen (the one with the menu bar, as in
    ///   `NSScreen.screens`), its top edge `gap` below a menu bar of
    ///   `menuBarHeight`. Counted from the screen's frame, not its visible
    ///   frame, so a full-screen app that hides the menu bar does not move
    ///   the window.
    ///
    /// Screens and an icon frame that are not finite or empty, which a
    /// display reconfiguration can report briefly, are ignored.
    static func origin(
        iconFrame: CGRect?, screens: [CaptionScreen], size: CGSize, menuBarHeight: CGFloat,
    ) -> CGPoint? {
        let usable = screens.map(\.frame).filter(isUsable)
        if let icon = iconFrame, isUsable(icon) {
            let midpoint = CGPoint(x: icon.midX, y: icon.midY)
            if let screen = usable.first(where: { $0.contains(midpoint) }) {
                let origin = CGPoint(x: icon.midX - size.width / 2, y: icon.minY - gap - size.height)
                return clamped(origin, size: size, inside: screen)
            }
        }
        guard let first = usable.first else { return nil }
        let origin = CGPoint(
            x: first.maxX - gap - size.width,
            y: first.maxY - menuBarHeight - gap - size.height,
        )
        return clamped(origin, size: size, inside: first)
    }

    private static func clamped(_ origin: CGPoint, size: CGSize, inside screen: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, screen.minX + gap), screen.maxX - gap - size.width),
            y: min(max(origin.y, screen.minY), screen.maxY - size.height),
        )
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
