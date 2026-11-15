import CoreGraphics
@testable import MeetingTranscriber
import XCTest

/// Where the prompt window goes (issue #99, R8), with a notched main screen
/// (1728 × 1117, a 33 pt menu bar) and a wide second screen above it, whose
/// menu bar is 30 pt.
final class PromptWindowPlacementTests: XCTestCase {
    private let size = CGSize(width: 340, height: 120)
    private let menuBarHeight: CGFloat = 33
    private let main = CaptionScreen(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 81, width: 1728, height: 1003),
    )
    private let second = CaptionScreen(
        frame: CGRect(x: -856, y: 1117, width: 3440, height: 1440),
        visibleFrame: CGRect(x: -856, y: 1117, width: 3440, height: 1440),
    )
    /// The window's origin at the top right of the main screen: 6 pt off
    /// its right edge, its top edge 6 pt below the 33 pt menu bar.
    private let topRight = CGPoint(x: 1728 - 6 - 340, y: 1117 - 33 - 6 - 120)

    private func origin(icon: CGRect?, screens: [CaptionScreen]) -> CGPoint? {
        PromptWindowPlacement.origin(iconFrame: icon, screens: screens, size: size, menuBarHeight: menuBarHeight)
    }

    func testIconInTheMiddleOfTheMenuBarCentresTheWindowBelowIt() {
        let icon = CGRect(x: 1034, y: 1084, width: 32, height: 33)

        XCTAssertEqual(origin(icon: icon, screens: [main, second]), CGPoint(x: 1050 - 170, y: 1084 - 6 - 120))
    }

    func testIconNearTheRightEdgeKeepsTheWindowInsideTheScreen() {
        let icon = CGRect(x: 1690, y: 1084, width: 32, height: 33)

        XCTAssertEqual(origin(icon: icon, screens: [main]), CGPoint(x: 1728 - 6 - 340, y: 1084 - 6 - 120))
    }

    func testNoIconFramePutsTheWindowAtTheTopRightBelowTheMenuBar() {
        XCTAssertEqual(origin(icon: nil, screens: [main, second]), topRight)
    }

    /// Where an item that is not inserted keeps its window.
    func testIconFrameOnNoScreenFallsBackToTheTopRight() {
        let icon = CGRect(x: 0, y: -22, width: 32, height: 22)

        XCTAssertEqual(origin(icon: icon, screens: [main, second]), topRight)
    }

    func testIconOnTheSecondScreenPutsTheWindowOnTheSecondScreen() {
        let icon = CGRect(x: 2065, y: 2527, width: 32, height: 30)

        XCTAssertEqual(origin(icon: icon, screens: [main, second]), CGPoint(x: 2081 - 170, y: 2527 - 6 - 120))
    }

    func testScreensAndIconFramesThatAreNotFiniteAreIgnored() {
        let broken = CaptionScreen(frame: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), visibleFrame: .zero)
        let icon = CGRect(x: CGFloat.nan, y: 1084, width: 32, height: 33)

        XCTAssertEqual(origin(icon: icon, screens: [broken, main]), topRight)
        XCTAssertNil(origin(icon: nil, screens: [broken]))
        XCTAssertNil(origin(icon: nil, screens: []))
    }
}
