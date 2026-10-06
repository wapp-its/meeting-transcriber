import AppKit
@testable import MeetingTranscriber
import XCTest

/// The icon tells "watching for meetings, nothing going on" from "not
/// watching" by a dot at the top right. Before, both rendered the same idle
/// waveform, and watching went off unnoticed after every restart.
@MainActor
final class MenuBarIconWatchingTests: XCTestCase {
    /// Alpha of the pixel at the dot's centre, rendered at 1x.
    private func dotAlpha(_ image: NSImage) throws -> CGFloat {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        // Bitmap rows run top-down, so the top-right dot is near (16, 2).
        return try XCTUnwrap(rep.colorAt(x: 16, y: 2)).alphaComponent
    }

    func testIdleIconShowsTheDotOnlyWhileWatching() throws {
        let watching = MenuBarIcon.image(badge: .inactive, watchingOverlay: true)
        let notWatching = MenuBarIcon.image(badge: .inactive)

        XCTAssertGreaterThan(try dotAlpha(watching), 0.9, "no dot while watching")
        XCTAssertLessThan(try dotAlpha(notWatching), 0.1, "a dot while not watching")
    }

    /// Drawn in the icon's own colour, so macOS still tints it for light and
    /// dark menu bars.
    func testTheDotKeepsTheIconATemplate() {
        XCTAssertTrue(MenuBarIcon.image(badge: .inactive, watchingOverlay: true).isTemplate)
        XCTAssertTrue(MenuBarIcon.image(badge: .recording, animationFrame: 2, watchingOverlay: true).isTemplate)
    }

    func testTheDotAppearsOnEveryBadgeAndAlongsideTheRedOverlays() throws {
        for badge in BadgeKind.allCases {
            XCTAssertGreaterThan(
                try dotAlpha(MenuBarIcon.image(badge: badge, watchingOverlay: true)), 0.9, "\(badge)",
            )
        }
        let withOverlays = MenuBarIcon.image(
            badge: .inactive, watchingOverlay: true, permissionOverlay: true, recordOnlyOverlay: true,
        )
        XCTAssertGreaterThan(try dotAlpha(withOverlays), 0.9)
    }

    func testAnimatedBadgesKeepAnimatingWithTheDot() {
        let frame0 = MenuBarIcon.image(badge: .recording, animationFrame: 0, watchingOverlay: true)
        let frame3 = MenuBarIcon.image(badge: .recording, animationFrame: 3, watchingOverlay: true)
        XCTAssertNotEqual(frame0.tiffRepresentation, frame3.tiffRepresentation)
    }
}
