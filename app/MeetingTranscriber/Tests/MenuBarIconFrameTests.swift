import AppKit
@testable import MeetingTranscriber
import XCTest

/// Reading the menu bar icon's frame from the app's windows (issue #99, R8).
/// The frames have the shape AppKit gives a notched main screen with a second
/// screen above it, where one menu bar item has a window on each.
final class MenuBarIconFrameTests: XCTestCase {
    private let mainScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let mainIcon = CGRect(x: 1034, y: 1084, width: 32, height: 33)
    private let secondIcon = CGRect(x: 2065, y: 2527, width: 32, height: 30)

    private func window(
        _ frame: CGRect, className: String = MenuBarIconFrame.iconWindowClassName,
        level: NSWindow.Level = .statusBar, isVisible: Bool = true,
    ) -> MenuBarIconFrame.Candidate {
        MenuBarIconFrame.Candidate(className: className, level: level, frame: frame, isVisible: isVisible)
    }

    func testFindsTheIconWindowPreferringTheOneOnTheMenuBarScreen() {
        let panel = window(CGRect(x: 1000, y: 900, width: 340, height: 120), className: "NSPanel")
        let windows = [panel, window(secondIcon), window(mainIcon)]

        XCTAssertEqual(MenuBarIconFrame.frame(among: windows, menuBarScreen: mainScreen), mainIcon)
        XCTAssertEqual(MenuBarIconFrame.frame(among: windows, menuBarScreen: nil), secondIcon)
    }

    /// The notch overflow: the main screen's window sits behind the notch.
    func testAnIconWindowThatIsNotVisibleIsSkipped() {
        let windows = [window(CGRect(x: 782, y: 1084, width: 32, height: 33), isVisible: false), window(secondIcon)]

        XCTAssertEqual(MenuBarIconFrame.frame(among: windows, menuBarScreen: mainScreen), secondIcon)
        XCTAssertNil(MenuBarIconFrame.frame(among: [windows[0]], menuBarScreen: mainScreen))
    }

    @MainActor
    func testNoIconWindowAmongTheAppsOwnWindows() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: true,
        )
        panel.level = .statusBar
        let real = MenuBarIconFrame.Candidate(panel)
        XCTAssertEqual(real.className, "NSPanel")
        XCTAssertEqual(real.level, .statusBar)

        let windows = [
            window(mainIcon, className: real.className),
            window(mainIcon, level: .floating),
        ]
        XCTAssertNil(MenuBarIconFrame.frame(among: windows, menuBarScreen: mainScreen))
        XCTAssertNil(MenuBarIconFrame.frame(among: [], menuBarScreen: mainScreen))
        XCTAssertNil(MenuBarIconFrame.frame(in: nil, menuBarScreen: mainScreen))
    }

    /// Where an item that is not inserted keeps its window.
    func testAnEmptyFrameReadsAsNoIcon() {
        XCTAssertNil(MenuBarIconFrame.frame(among: [window(CGRect(x: 0, y: 0, width: 32, height: 0))], menuBarScreen: nil))
    }
}
