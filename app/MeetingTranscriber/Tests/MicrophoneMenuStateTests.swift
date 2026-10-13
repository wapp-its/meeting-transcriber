import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Every arm of the menu bar's Microphone entry. The dropdown itself is manual
/// QA, so the titles, items and checkmark are pinned here, strings included.
final class MicrophoneMenuStateTests: XCTestCase {
    private static let headset = MicrophoneDevice(uid: "HeadsetUID", name: "Headset")
    private static let builtIn = MicrophoneDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")

    private func resolve(
        noMic: Bool = false,
        selectedUID: String = "",
        devices: [MicrophoneDevice] = [builtIn, headset],
        defaultInputName: String? = "MacBook Pro Microphone",
        recordedDevice: MicInputDevice? = nil,
        meetingAppHint: String? = nil,
    ) -> MicrophoneMenuState {
        .resolve(
            noMic: noMic,
            selectedUID: selectedUID,
            devices: devices,
            defaultInputName: defaultInputName,
            recordedDevice: recordedDevice,
            meetingAppHint: meetingAppHint,
        )
    }

    // MARK: - Title

    /// The device the capture reports, not the configured one: a refused pin
    /// records on the system default, and naming the headset there would hide
    /// exactly that.
    func testARecordingNamesTheDeviceItsCaptureReports() {
        let state = resolve(
            selectedUID: "HeadsetUID",
            recordedDevice: MicInputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
        )

        XCTAssertEqual(state.title, "Microphone: MacBook Pro Microphone")
    }

    func testIdleNamesTheChosenDeviceWhenItIsConnected() {
        XCTAssertEqual(resolve(selectedUID: "HeadsetUID").title, "Microphone: Headset")
    }

    func testIdleOnSystemDefaultNamesTheMacOSDefaultInput() {
        XCTAssertEqual(resolve(selectedUID: "").title, "Microphone: System Default (MacBook Pro Microphone)")
    }

    /// A recording whose microphone track failed or gave up reports no device,
    /// and one whose device cannot be named reports no name: both fall back to
    /// the device the next recording would use.
    func testARecordingWhoseCaptureNamesNoDeviceFallsBackToTheIdleTitle() {
        for recorded in [nil, MicInputDevice(uid: "BuiltInMicrophoneDevice", name: nil)] {
            XCTAssertEqual(
                resolve(selectedUID: "HeadsetUID", recordedDevice: recorded).title,
                "Microphone: Headset",
                "recorded device \(String(describing: recorded))",
            )
        }
    }

    /// Idle, the title names the system default the next recording falls back
    /// to; recording, the device the fallback actually opened. Either way it
    /// says the chosen one is missing, and the submenu keeps the stored choice
    /// checked on an item that cannot be chosen.
    func testAChosenDeviceThatIsNotConnectedIsNamedMissingAndStaysChecked() {
        let cases: [(recorded: MicInputDevice?, title: String)] = [
            (nil, "Microphone: System Default (MacBook Pro Microphone) — selected microphone not connected"),
            (
                MicInputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
                "Microphone: MacBook Pro Microphone — selected microphone not connected",
            ),
        ]
        for (recorded, title) in cases {
            let state = resolve(selectedUID: "GoneUID", recordedDevice: recorded)

            XCTAssertEqual(state.title, title)
            XCTAssertEqual(
                state.items.last,
                MicrophoneMenuState.Item(uid: "GoneUID", label: "Selected microphone (not connected)", isEnabled: false),
            )
            XCTAssertEqual(state.checkedUID, "GoneUID")
        }
    }

    func testNoInputDeviceSaysNoMicrophoneIsAvailable() {
        let state = resolve(devices: [], defaultInputName: nil)

        XCTAssertEqual(state.title, "Microphone: None available")
        XCTAssertTrue(state.isEnabled, "System Default stays choosable for a device plugged in later")
    }

    func testNoMicIsOneDisabledOffLineWithoutItems() {
        let state = resolve(noMic: true, selectedUID: "HeadsetUID")

        XCTAssertEqual(state.title, "Microphone: Off (app audio only)")
        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.items, [])
    }

    // MARK: - Items

    /// System Default first, then the Settings list in its own order, which is
    /// deliberately not alphabetical here so a sort would show.
    func testTheItemsAreSystemDefaultThenTheSettingsListInOrder() {
        XCTAssertEqual(resolve(devices: [Self.headset, Self.builtIn]).items, [
            MicrophoneMenuState.Item(uid: "", label: "System Default (MacBook Pro Microphone)", isEnabled: true),
            MicrophoneMenuState.Item(uid: "HeadsetUID", label: "Headset", isEnabled: true),
            MicrophoneMenuState.Item(uid: "BuiltInMicrophoneDevice", label: "MacBook Pro Microphone", isEnabled: true),
        ])
    }

    func testTheCheckedItemIsTheStoredChoice() {
        for selectedUID in ["", "HeadsetUID"] {
            XCTAssertEqual(resolve(selectedUID: selectedUID).checkedUID, selectedUID)
        }
    }

    // MARK: - Hint

    func testTheMeetingAppHintPassesThroughUnchanged() {
        XCTAssertNil(resolve().hint)
        XCTAssertEqual(resolve(meetingAppHint: "Microsoft Teams uses Headset").hint, "Microsoft Teams uses Headset")
    }
}
