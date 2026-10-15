@testable import MeetingTranscriber
import XCTest

/// The start dialog's start decision, exercised as a value so the view test can
/// stay a single wiring assertion.
final class AppPickerStartStateTests: XCTestCase {
    private let app = StartRecordingSource.app(RunningApp(id: 100, name: "Chrome", bundleIdentifier: nil, icon: nil))

    func testReadyForAnAppAndForTheMicrophone() {
        XCTAssertEqual(AppPickerStartState.resolve(source: app, noMic: false, startWouldBeRefused: false), .ready)
        XCTAssertEqual(AppPickerStartState.resolve(source: .microphone, noMic: false, startWouldBeRefused: false), .ready)
    }

    /// "No Microphone" decides only whether an app recording also takes the
    /// microphone, so an app stays startable with it set.
    func testAnAppStaysReadyWithNoMicrophoneSet() {
        XCTAssertEqual(AppPickerStartState.resolve(source: app, noMic: true, startWouldBeRefused: false), .ready)
    }

    func testNoSelectionBlocks() {
        XCTAssertEqual(AppPickerStartState.resolve(source: nil, noMic: false, startWouldBeRefused: false), .noSelection)
    }

    func testMicrophoneOnlyIsBlockedWhileNoMicrophoneIsSet() {
        let state = AppPickerStartState.resolve(source: .microphone, noMic: true, startWouldBeRefused: false)

        XCTAssertEqual(state, .microphoneBlockedByNoMic)
        XCTAssertEqual(state.explanation, MicrophoneRecordingAvailability.blockedByNoMicSetting.disabledReason)
    }

    /// True for both halves of the controller's predicate: a start still in
    /// flight and a loop already recording. Both are reachable, because the menu
    /// gates opening this window, not its persistence.
    func testARefusedStartBlocks() {
        XCTAssertEqual(AppPickerStartState.resolve(source: app, noMic: false, startWouldBeRefused: true), .manualRecordingActive)
    }

    /// Precedence, not an accident: with other blockers present, telling the
    /// user to pick a source or change a setting would send them the wrong way,
    /// since neither helps while a recording owns the loop.
    func testARefusedStartOutranksEveryOtherBlocker() {
        XCTAssertEqual(AppPickerStartState.resolve(source: nil, noMic: false, startWouldBeRefused: true), .manualRecordingActive)
        XCTAssertEqual(
            AppPickerStartState.resolve(source: .microphone, noMic: true, startWouldBeRefused: true), .manualRecordingActive,
        )
    }

    func testOnlyReadyAllowsStart() {
        XCTAssertTrue(AppPickerStartState.ready.allowsStart)
        XCTAssertFalse(AppPickerStartState.noSelection.allowsStart)
        XCTAssertFalse(AppPickerStartState.manualRecordingActive.allowsStart)
        XCTAssertFalse(AppPickerStartState.microphoneBlockedByNoMic.allowsStart)
    }

    /// Every disabled Start says why (R5): the missing selection in the
    /// dialog's own words, a recording running behind the dialog and a setting
    /// made elsewhere in theirs. Only a ready Start says nothing.
    func testEveryBlockerExplainsItself() {
        XCTAssertNil(AppPickerStartState.ready.explanation)
        XCTAssertEqual(AppPickerStartState.noSelection.explanation, "Choose what to record: the microphone only, or one of the running apps.")
        XCTAssertNotNil(AppPickerStartState.manualRecordingActive.explanation)
        XCTAssertNotNil(AppPickerStartState.microphoneBlockedByNoMic.explanation)
    }
}
