import AppKit
@testable import MeetingTranscriber
import XCTest

/// While a "Record <App> meeting?" prompt waits for an answer, the icon shows
/// a question mark at the top right in place of the watching dot. Everything
/// else is drawn as without the prompt, so the bottom-right badges and the
/// waveform below the mark stay exactly as they were.
@MainActor
final class MenuBarIconQuestionTests: XCTestCase {
    /// `Data` rather than a byte array, so a failure prints a byte count
    /// instead of 648 numbers.
    private struct Halves: Equatable {
        let top: Data
        let bottom: Data
    }

    /// The pixels of `image` rendered at 1x, split into rows 0-8 and 9-17.
    /// Bitmap rows run top-down, so the first nine rows are the top half.
    private func halves(_ image: NSImage) throws -> Halves {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(rep.bitmapData)
        let split = rep.bytesPerRow * 9
        return Halves(top: Data(bytes: data, count: split), bottom: Data(bytes: data + split, count: split))
    }

    func testEveryBadgeShowsTheQuestionInTheTopHalfAndLeavesTheBottomHalfAlone() throws {
        for permission in [false, true] {
            for badge in BadgeKind.allCases {
                let label = "\(badge), permission overlay \(permission)"
                let plain = try halves(MenuBarIcon.image(badge: badge, permissionOverlay: permission))
                let dot = try halves(MenuBarIcon.image(
                    badge: badge, watchingOverlay: true, permissionOverlay: permission,
                ))
                let question = try halves(MenuBarIcon.image(
                    badge: badge, watchingOverlay: true, questionOverlay: true, permissionOverlay: permission,
                ))
                let questionWithoutWatching = try halves(MenuBarIcon.image(
                    badge: badge, questionOverlay: true, permissionOverlay: permission,
                ))

                XCTAssertNotEqual(question.top, dot.top, "looks like the watching dot: \(label)")
                XCTAssertNotEqual(question.top, plain.top, "nothing drawn in place of the dot: \(label)")
                XCTAssertEqual(question.bottom, dot.bottom, "bottom half changed: \(label)")
                XCTAssertEqual(question, questionWithoutWatching, "the dot is drawn under the question: \(label)")
            }
        }
    }

    /// Drawn in the icon's own colour, so macOS still tints it for light and
    /// dark menu bars.
    func testTheQuestionKeepsTheIconATemplate() {
        XCTAssertTrue(MenuBarIcon.image(badge: .inactive, watchingOverlay: true, questionOverlay: true).isTemplate)
        XCTAssertTrue(MenuBarIcon.image(badge: .recording, watchingOverlay: true, questionOverlay: true).isTemplate)
    }

    func testAnimatedBadgesKeepAnimatingUnderTheQuestion() throws {
        let frame0 = MenuBarIcon.image(badge: .recording, animationFrame: 0, watchingOverlay: true, questionOverlay: true)
        let frame3 = MenuBarIcon.image(badge: .recording, animationFrame: 3, watchingOverlay: true, questionOverlay: true)
        XCTAssertNotEqual(try halves(frame0), try halves(frame3))
    }
}
