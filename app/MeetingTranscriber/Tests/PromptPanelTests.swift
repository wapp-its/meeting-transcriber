import AppKit
@testable import MeetingTranscriber
import XCTest

/// The prompt panel's set-up (issue #99, R8 and R9), on a real panel that is
/// never shown. That one click on a shown panel answers without activating
/// the app needs another app frontmost and a click from outside the process,
/// so it is not checked here.
@MainActor
final class PromptPanelTests: XCTestCase {
    func testPanelTakesClicksWithoutEverBecomingKeyOrActivatingTheApp() {
        let panel = PromptPanel(size: CGSize(width: 340, height: 120))

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "a click must not activate the app")
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertFalse(panel.canBecomeKey, "no key press may answer a question")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(
            panel.level, .statusBar,
            "setting isFloatingPanel resets the level to .floating, so the level is set after it",
        )
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertEqual(panel.identifier, PromptPanel.windowIdentifier)
        XCTAssertIdentical(panel.contentView, panel.host)
        XCTAssertTrue(panel.host.acceptsFirstMouse(for: nil), "a plain NSHostingView answers false")
    }
}
