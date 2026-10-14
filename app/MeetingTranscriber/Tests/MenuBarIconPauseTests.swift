import AppKit
@testable import MeetingTranscriber
import XCTest

/// While a recording is paused the icon draws a static pause symbol in place of
/// the waveform. The badge stays `.recording`; only the body changes, so every
/// other overlay draws over the symbol as it draws over the waveform.
@MainActor
final class MenuBarIconPauseTests: XCTestCase {
    /// A 1x render of an icon, read pixel by pixel. Bitmap rows run top-down.
    private struct Bitmap {
        let rep: NSBitmapImageRep

        var bytes: Data {
            rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh) } ?? Data()
        }

        func color(_ x: Int, _ y: Int) throws -> NSColor {
            try XCTUnwrap(rep.colorAt(x: x, y: y))
        }

        func totalAlpha() throws -> CGFloat {
            var alpha: CGFloat = 0
            for y in 0 ..< rep.pixelsHigh {
                for x in 0 ..< rep.pixelsWide {
                    alpha += try color(x, y).alphaComponent
                }
            }
            return alpha
        }
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
        return Bitmap(rep: rep)
    }

    /// The pause symbol: the left bar is opaque at (5, 9), and the gap between
    /// the bars at (9, 9) is empty where the waveform's middle bar would be.
    private func assertShowsThePauseSymbol(_ bitmap: Bitmap, _ label: String) throws {
        XCTAssertGreaterThan(try bitmap.color(5, 9).alphaComponent, 0.9, "\(label): left bar")
        XCTAssertLessThan(try bitmap.color(9, 9).alphaComponent, 0.1, "\(label): gap between the bars")
    }

    private func isRed(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.9 && color.redComponent > 0.8 && color.greenComponent < 0.5
    }

    func testThePausedIconReplacesEveryRecordingFrameAndHoldsStill() throws {
        let still = try render(MenuBarIcon.image(badge: .recording, pausedOverlay: true))
        try assertShowsThePauseSymbol(still, "paused")
        for frame in 0 ..< MenuBarIcon.frameCount {
            let recording = try render(MenuBarIcon.image(badge: .recording, animationFrame: frame))
            let paused = try render(MenuBarIcon.image(badge: .recording, animationFrame: frame, pausedOverlay: true))
            XCTAssertNotEqual(recording.bytes, still.bytes, "frame \(frame)")
            XCTAssertEqual(paused.bytes, still.bytes, "frame \(frame): the pause symbol does not animate")
        }
    }

    /// Drawn in the icon's own colour, so macOS tints it for light and dark
    /// menu bars; a red overlay forces the explicit-colour path as it does
    /// over the waveform.
    func testThePausedIconIsATemplateUnlessARedOverlayIsOn() {
        XCTAssertTrue(MenuBarIcon.image(badge: .recording, pausedOverlay: true).isTemplate)
        XCTAssertTrue(MenuBarIcon.image(badge: .recording, pausedOverlay: true, watchingOverlay: true).isTemplate)
        XCTAssertTrue(MenuBarIcon.image(badge: .recording, pausedOverlay: true, questionOverlay: true).isTemplate)
        XCTAssertTrue(
            MenuBarIcon.image(badge: .recording, animationFrame: 4, pausedOverlay: true, meetingEndCountdownOverlay: true).isTemplate,
        )
        XCTAssertFalse(MenuBarIcon.image(badge: .recording, pausedOverlay: true, permissionOverlay: true).isTemplate)
        XCTAssertFalse(MenuBarIcon.image(badge: .recording, pausedOverlay: true, recordOnlyOverlay: true).isTemplate)
        XCTAssertFalse(MenuBarIcon.image(badge: .recording, pausedOverlay: true, micSilentOverlay: true).isTemplate)
        XCTAssertFalse(MenuBarIcon.image(badge: .recording, pausedOverlay: true, appSilentOverlay: true).isTemplate)
    }

    /// Each overlay leaves the pause symbol in place and marks its own spot:
    /// the dot and the question mark at the top right, the permission badge and
    /// the record-only dot in red at the bottom right, the silent tints in red
    /// on the symbol's own top or bottom half.
    func testEveryOverlayStillDrawsOverThePauseSymbol() throws {
        let plain = try render(MenuBarIcon.image(badge: .recording, pausedOverlay: true))
        XCTAssertLessThan(try plain.color(16, 2).alphaComponent, 0.1, "precondition: the top right is empty")
        XCTAssertLessThan(try plain.color(15, 15).alphaComponent, 0.1, "precondition: the bottom right is empty")

        let watching = try render(MenuBarIcon.image(badge: .recording, pausedOverlay: true, watchingOverlay: true))
        try assertShowsThePauseSymbol(watching, "watching")
        XCTAssertGreaterThan(try watching.color(16, 2).alphaComponent, 0.9, "the watching dot")

        let question = try render(MenuBarIcon.image(badge: .recording, pausedOverlay: true, questionOverlay: true))
        try assertShowsThePauseSymbol(question, "question")
        XCTAssertNotEqual(question.bytes, plain.bytes, "the question mark")
        XCTAssertNotEqual(question.bytes, watching.bytes, "the question mark, not the dot")

        for (name, permission, recordOnly) in [("permission", true, false), ("record-only", false, true)] {
            let badge = try render(MenuBarIcon.image(
                badge: .recording, pausedOverlay: true, permissionOverlay: permission, recordOnlyOverlay: recordOnly,
            ))
            try assertShowsThePauseSymbol(badge, name)
            try XCTAssertTrue(isRed(badge.color(15, 15)), "\(name) badge")
        }

        let micSilent = try render(MenuBarIcon.image(badge: .recording, pausedOverlay: true, micSilentOverlay: true))
        try XCTAssertTrue(isRed(micSilent.color(5, 6)), "mic tint on the top half")
        try XCTAssertFalse(isRed(micSilent.color(5, 12)), "mic tint leaves the bottom half")
        let appSilent = try render(MenuBarIcon.image(badge: .recording, pausedOverlay: true, appSilentOverlay: true))
        try XCTAssertTrue(isRed(appSilent.color(5, 12)), "app tint on the bottom half")
        XCTAssertLessThan(try appSilent.color(9, 9).alphaComponent, 0.1, "the tint redraws the pause symbol, not the waveform")
    }

    /// A paused recording during a meeting-end countdown keeps the pulse: the
    /// pause symbol as it is on frames 0 to 2, faded on frames 3 to 5.
    func testTheCountdownPulseStillRunsOverThePauseSymbol() throws {
        let plain = try render(MenuBarIcon.image(badge: .recording, pausedOverlay: true))
        let plainAlpha = try plain.totalAlpha()
        for frame in 0 ..< MenuBarIcon.frameCount {
            let counting = try render(MenuBarIcon.image(
                badge: .recording, animationFrame: frame, pausedOverlay: true, meetingEndCountdownOverlay: true,
            ))
            if frame < 3 {
                XCTAssertEqual(counting.bytes, plain.bytes, "frame \(frame)")
            } else {
                XCTAssertLessThan(try counting.totalAlpha(), plainAlpha / 2, "frame \(frame): faded")
                XCTAssertGreaterThan(try counting.totalAlpha(), 0, "frame \(frame): faded, not gone")
            }
        }
    }
}
