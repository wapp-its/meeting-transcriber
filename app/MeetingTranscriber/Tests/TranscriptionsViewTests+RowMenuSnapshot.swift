import AppKit
@testable import MeetingTranscriber
import SnapshotTesting
import SwiftUI
import XCTest

/// The pixel record (dev-only) of a row's "…" menu with its Additional Reports
/// group, so a long report name can be seen to widen the menu rather than be cut.
/// It is the menu AppKit draws for the SwiftUI `Menu`, not a stand-in: SwiftUI
/// fills the menu of its `NSPopUpButton` only when the menu opens, and an open menu
/// runs its own tracking loop, so a timer in that loop captures the menu's window
/// and closes it, and a second one closes it should the first find no window.
extension TranscriptionsViewTests {
    /// What the timers hand back from the tracking loop, which ends before the
    /// test reads it.
    private final class OpenMenuCapture: @unchecked Sendable {
        var menu: NSMenu?
        var image: NSImage?
    }

    func testSnapshotOfTheRowMenuWithLongReportNames() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Snapshot tests are machine-dependent")
        let row = entry("Regional leadership weekly check-in", protocolPath: "/out/s.md", transcriptPath: "/out/s.txt")
        let meeting = meeting(row)
        var actions = AllRecordingsActions.noop
        actions.meetingFiles = { _ in meeting.record }
        actions.audioOnDisk = { _ in meeting.audio }
        actions.filesOnDisk = { _ in
            FilesOnDisk(protocolExists: true, transcriptExists: true, transcriptSource: .transcriptFile, reports: [
                .init(name: "Board summary for the partners and the regional leads", url: URL(fileURLWithPath: "/out/s (Board).md")),
                .init(name: "Short", url: URL(fileURLWithPath: "/out/s (Short).md")),
            ])
        }

        let image = try XCTUnwrap(openedMenuImage(of: hostedMoreButton(makeView([row], actions: actions))), "no menu window while the menu was open")

        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
        }
    }

    /// The row's "…" button, in a window in the light appearance so the snapshot
    /// does not depend on the time of day.
    private func hostedMoreButton(_ view: TranscriptionsView) throws -> NSPopUpButton {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        pump(timeout: 1) { false }
        func popUpButton(in view: NSView) -> NSPopUpButton? {
            (view as? NSPopUpButton) ?? view.subviews.lazy.compactMap(popUpButton(in:)).first
        }
        return try XCTUnwrap(popUpButton(in: hosting), "the row's … button")
    }

    /// Opens the button's menu and returns what its window drew once it was open.
    private func openedMenuImage(of button: NSPopUpButton) throws -> NSImage? {
        let capture = OpenMenuCapture()
        capture.menu = try XCTUnwrap(button.menu)
        capture.menu?.appearance = NSAppearance(named: .aqua)
        let shoot = Timer(timeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated {
                let menuWindow = NSApplication.shared.windows.last { $0.isVisible && String(describing: type(of: $0)).contains("MenuWindow") }
                if let content = menuWindow?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    let image = NSImage(size: rep.size)
                    image.addRepresentation(rep)
                    capture.image = image
                }
                capture.menu?.cancelTracking()
            }
        }
        let giveUp = Timer(timeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated { capture.menu?.cancelTracking() }
        }
        for timer in [shoot, giveUp] {
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
        defer { [shoot, giveUp].forEach { $0.invalidate() } }
        button.performClick(nil)
        return capture.image
    }
}
