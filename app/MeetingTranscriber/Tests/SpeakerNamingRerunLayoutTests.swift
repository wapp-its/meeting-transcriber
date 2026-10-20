import AppKit
@testable import MeetingTranscriber
import SwiftUI
import XCTest

/// The re-run area of the naming dialog fits the dialog at every width the
/// window can open at (issue #163), checked at the lowest layer that lays the
/// view out: `SpeakerNamingView` hosted in a real `NSWindow`, as
/// `SpeakerNamingFieldIdentityTests` does. ViewInspector never lays out.
///
/// What was wrong: the re-run row was one `HStack` of a label, a picker fixed
/// at 280 pt, a stepper and a button, whose minimum widths summed past the
/// dialog's minimum width (400 pt, less 16 pt padding each side). The window
/// scene uses `.windowResizability(.contentSize)`, so the minimum width is
/// also the narrowest the window opens at (a restored frame, say), and there
/// SwiftUI truncated the row's texts and pushed its controls past the padding.
/// The row is now two lines whose only fixed-width items are the picker, the
/// stepper and the button, with every text free to wrap.
///
/// What this measures: the AppKit-backed controls of the re-run area, the
/// segmented picker and the count stepper, lie inside the dialog's content
/// area at its minimum width and at its opening (fitting) size, for each
/// method and for two-track and single-file jobs. SwiftUI draws its texts and
/// buttons itself, so their frames are not reachable from AppKit; the button's
/// fixed size and the texts' wrapping are pinned by ViewInspector in
/// `SpeakerNamingViewTests`.
@MainActor
final class SpeakerNamingRerunLayoutTests: XCTestCase {
    /// The dialog's own `.padding()`: SwiftUI's default on macOS, measured on
    /// the hosted view (the name fields' container starts at x = 16).
    private static let contentInset: CGFloat = 16

    private func makeData(labels: [String], isDualSource: Bool) -> PipelineQueue.SpeakerNamingData {
        PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: "Weekly sync",
            mapping: Dictionary(uniqueKeysWithValues: labels.map { ($0, $0) }),
            speakingTimes: Dictionary(uniqueKeysWithValues: labels.map { ($0, 10.0) }),
            embeddings: [:],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: isDualSource,
        )
    }

    private func host(_ view: SpeakerNamingView, width: CGFloat?) -> NSHostingView<SpeakerNamingView> {
        let hosting = NSHostingView(rootView: view)
        let opening = hosting.fittingSize
        hosting.frame = width.map { NSRect(x: 0, y: 0, width: $0, height: max(opening.height, 700)) }
            ?? NSRect(origin: .zero, size: opening)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        pump { hosting.descendants(of: NSTextField.self).contains(where: \.isEditable) }
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    /// The re-run area's AppKit-backed controls: the segmented picker and the
    /// count stepper. Found by what they are, not by a private class name: the
    /// dialog has exactly one segmented control and one stepper, both in the
    /// re-run area.
    private func rerunControls(in hosting: NSView) -> [NSControl] {
        hosting.descendants(of: NSControl.self).filter { $0 is NSSegmentedControl || $0 is NSStepper }
    }

    private func assertRerunControlsFit(_ hosting: NSView, expected: Int, _ label: String) {
        let controls = rerunControls(in: hosting)
        XCTAssertEqual(controls.count, expected, "\(label): expected the re-run controls to be hosted")
        let contentArea = hosting.bounds.insetBy(dx: Self.contentInset, dy: 0)
        for control in controls {
            let frame = hosting.convert(control.bounds, from: control)
            XCTAssertTrue(
                contentArea.contains(frame),
                "\(label): \(type(of: control)) at \(frame) must lie inside the content area \(contentArea)",
            )
            XCTAssertGreaterThanOrEqual(
                frame.width, control.fittingSize.width - 0.5,
                "\(label): \(type(of: control)) must not be narrower than it needs",
            )
        }
    }

    /// At the minimum width, for every method and both job kinds.
    func testRerunControlsFitAtMinimumWidth() {
        let twoTrack = makeData(labels: ["R_SPEAKER_00", "R_SPEAKER_01", "M_SPEAKER_00"], isDualSource: true)
        let single = makeData(labels: ["SPEAKER_00", "SPEAKER_01"], isDualSource: false)
        for mode in DiarizerMode.allCases {
            for (data, kind) in [(twoTrack, "two-track"), (single, "single-file")] {
                let hosting = host(
                    SpeakerNamingView(data: data, currentDiarizerMode: mode, gracePeriod: 0) { _ in },
                    width: SpeakerNamingView.minimumWidth,
                )
                // A picker always; a stepper only while Standard shows a count.
                let expected = mode.countsSpeakersItself ? 1 : 2
                assertRerunControlsFit(hosting, expected: expected, "\(mode.displayName), \(kind), minimum width")
            }
        }
    }

    /// At the opening size: the view's fitting size, which is what
    /// `.windowResizability(.contentSize)` opens the window at. It is never
    /// narrower than the minimum width.
    func testRerunControlsFitAtOpeningSize() {
        let twoTrack = makeData(labels: ["R_SPEAKER_00", "R_SPEAKER_01", "M_SPEAKER_00"], isDualSource: true)
        for mode in DiarizerMode.allCases {
            let hosting = host(
                SpeakerNamingView(data: twoTrack, currentDiarizerMode: mode, gracePeriod: 0) { _ in },
                width: nil,
            )
            XCTAssertGreaterThanOrEqual(hosting.frame.width, SpeakerNamingView.minimumWidth, "\(mode.displayName)")
            assertRerunControlsFit(hosting, expected: mode.countsSpeakersItself ? 1 : 2, "\(mode.displayName), opening size")
        }
    }

    /// Voice enrollment passes no method: no picker, a stepper, still fitting.
    func testEnrollmentRerunControlsFitAtMinimumWidth() {
        let single = makeData(labels: ["SPEAKER_00"], isDualSource: false)
        let hosting = host(SpeakerNamingView(data: single, gracePeriod: 0) { _ in }, width: SpeakerNamingView.minimumWidth)
        assertRerunControlsFit(hosting, expected: 1, "enrollment, minimum width")
        XCTAssertTrue(rerunControls(in: hosting).allSatisfy { $0 is NSStepper }, "enrollment shows no method picker")
    }
}
