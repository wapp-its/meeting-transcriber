@testable import MeetingTranscriber
import XCTest

/// Every arm of the menu bar's Output entry. Its wiring is
/// `MenuBarOutputTests`; the dropdown's own behaviour is manual QA.
final class OutputMenuStateTests: XCTestCase {
    private typealias Item = OutputMenuState.Item
    private let speakers = OutputDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
    private let headset = OutputDevice(uid: "HeadsetUID", name: "Headset")
    private let teams = OutputDevice(uid: OutputRoutingWarning.teamsLoopbackUID, name: "Microsoft Teams Audio")
    private let blackHole = OutputDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch")

    func testTheEntryNamesTheCurrentOutputAndChecksIt() {
        let menu = OutputMenuState.resolve(devices: [speakers, headset], current: headset)

        XCTAssertEqual(menu.title, "Output: Headset")
        XCTAssertTrue(menu.isEnabled)
        XCTAssertEqual(menu.items, [
            Item(uid: "BuiltInSpeakerDevice", label: "MacBook Pro Speakers", isEnabled: true),
            Item(uid: "HeadsetUID", label: "Headset", isEnabled: true),
        ])
        XCTAssertEqual(menu.checkedUID, "HeadsetUID")
        XCTAssertNil(menu.hint)
        XCTAssertFalse(menu.warning)
    }

    func testAnUnreadableDefaultReadsUnknownWithNoCheckmarkAndStillListsTheOutputs() {
        let menu = OutputMenuState.resolve(devices: [speakers, headset], current: nil)

        XCTAssertEqual(menu.title, "Output: Unknown")
        XCTAssertTrue(menu.isEnabled)
        XCTAssertEqual(menu.items.map(\.uid), ["BuiltInSpeakerDevice", "HeadsetUID"])
        XCTAssertEqual(menu.checkedUID, "")
        XCTAssertFalse(menu.warning)
    }

    func testNoOutputFoundIsOneDisabledLine() {
        let menu = OutputMenuState.resolve(devices: [], current: nil)

        XCTAssertEqual(menu.title, "Output: None available")
        XCTAssertFalse(menu.isEnabled)
        XCTAssertEqual(menu.items, [])
        XCTAssertNil(menu.hint)
    }

    /// The Mac does not offer the Teams device as an output, so it is not
    /// among `devices`; it still gets an item, disabled, so the checkmark
    /// shows where the Mac is.
    func testTheTeamsDeviceCarriesTheMarkTheHintAndADisabledItemForItsCheckmark() {
        let menu = OutputMenuState.resolve(devices: [speakers, headset], current: teams)

        XCTAssertEqual(menu.title, "⚠️ Output: Microsoft Teams Audio")
        XCTAssertTrue(menu.warning)
        XCTAssertEqual(menu.hint, "Meeting audio may not be recorded. Choose your speakers or headset.")
        XCTAssertEqual(menu.items.last, Item(uid: OutputRoutingWarning.teamsLoopbackUID, label: "Microsoft Teams Audio", isEnabled: false))
        XCTAssertEqual(menu.items.count, 3)
        XCTAssertEqual(menu.checkedUID, OutputRoutingWarning.teamsLoopbackUID)
    }

    func testAnotherVirtualOutputCarriesNoMarkAndNoHint() {
        let menu = OutputMenuState.resolve(devices: [speakers, blackHole], current: blackHole)

        XCTAssertEqual(menu.title, "Output: BlackHole 2ch")
        XCTAssertFalse(menu.warning)
        XCTAssertNil(menu.hint)
        XCTAssertEqual(menu.items.count, 2, "an offered current output is not listed twice")
    }
}
