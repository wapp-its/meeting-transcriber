import AppKit
@testable import MeetingTranscriber
import XCTest

/// While a "meeting seems to have ended" countdown runs, the icon pulses, so
/// the countdown shows even when its notification does not: the whole icon is
/// drawn faded on the second half of the 6-frame cycle (frames 3 to 5) and as
/// without the countdown on the first half. Alpha only, so the template rule
/// is the one the icon had before.
@MainActor
final class MenuBarIconCountdownTests: XCTestCase {
    /// What else the recording icon is drawn with: nothing, the watching dot
    /// it has beside a countdown in the app, or that and the red overlays.
    private enum Overlays: CaseIterable {
        case bare
        case watching
        case watchingAndRed
    }

    /// A 1x render: its bytes, and the alpha of all its pixels added up.
    private struct Bitmap {
        let bytes: Data
        let alpha: CGFloat
    }

    private func render(_ image: NSImage) throws -> Bitmap {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        var alpha: CGFloat = 0
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide {
                alpha += try XCTUnwrap(rep.colorAt(x: x, y: y)).alphaComponent
            }
        }
        let data = try XCTUnwrap(rep.bitmapData)
        return Bitmap(bytes: Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh), alpha: alpha)
    }

    private func recordingIcon(_ frame: Int, countdown: Bool, _ overlays: Overlays) -> NSImage {
        MenuBarIcon.image(
            badge: .recording,
            animationFrame: frame,
            watchingOverlay: overlays != .bare,
            meetingEndCountdownOverlay: countdown,
            permissionOverlay: overlays == .watchingAndRed,
            micSilentOverlay: overlays == .watchingAndRed,
        )
    }

    func testFramesZeroToTwoAreDrawnAsWithoutTheCountdownAndThreeToFiveFaded() throws {
        for overlays in Overlays.allCases {
            for frame in 0 ..< MenuBarIcon.frameCount {
                let label = "\(overlays), frame \(frame)"
                let plain = try render(recordingIcon(frame, countdown: false, overlays))
                let counting = try render(recordingIcon(frame, countdown: true, overlays))
                if frame < 3 {
                    XCTAssertEqual(counting.bytes, plain.bytes, label)
                } else {
                    XCTAssertLessThan(counting.alpha, plain.alpha / 2, label)
                    XCTAssertGreaterThan(counting.alpha, 0, "\(label): faded, not gone")
                }
            }
        }
    }

    /// macOS tints a template for light and dark menu bars, so the faded
    /// recording icon must stay one; a red overlay keeps it non-template.
    func testTheFadeLeavesTheTemplateRuleAsItWas() {
        for frame in 0 ..< MenuBarIcon.frameCount {
            XCTAssertTrue(recordingIcon(frame, countdown: true, .bare).isTemplate, "frame \(frame)")
            XCTAssertTrue(recordingIcon(frame, countdown: true, .watching).isTemplate, "dot, frame \(frame)")
            XCTAssertFalse(recordingIcon(frame, countdown: true, .watchingAndRed).isTemplate, "red, frame \(frame)")
        }
    }

    /// Off is the default, and off is the cached image every badge showed
    /// before the countdown mark existed, with the dot or the question mark.
    func testWithTheFlagOffEveryBadgeRendersAsBefore() {
        for badge in BadgeKind.allCases {
            for frame in 0 ..< MenuBarIcon.frameCount {
                for (watching, question) in [(false, false), (true, false), (false, true)] {
                    let byDefault = MenuBarIcon.image(
                        badge: badge, animationFrame: frame, watchingOverlay: watching, questionOverlay: question,
                    )
                    let off = MenuBarIcon.image(
                        badge: badge, animationFrame: frame, watchingOverlay: watching, questionOverlay: question,
                        meetingEndCountdownOverlay: false,
                    )
                    XCTAssertIdentical(byDefault, off, "\(badge), frame \(frame), dot \(watching), question \(question)")
                }
            }
        }
    }
}
