import AudioTapLib
import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// `MicrophoneController` hands a changed microphone choice to the recording it
/// is attached to, and publishes the device that recording reports.
@MainActor
final class MicrophoneControllerTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!

    private let headset = MicInputDevice(uid: "HeadsetUID", name: "Headset")
    private let builtIn = MicInputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let headsetEntry = MicrophoneDevice(uid: "HeadsetUID", name: "Headset")
    private let builtInEntry = MicrophoneDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "MicrophoneControllerTests-\(getpid())-\(UUID().uuidString)"
        settings = try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: suiteName)))
    }

    override func tearDown() async throws {
        settings = nil
        DefaultsSuite.remove(suiteName)
        suiteName = nil
        try await super.tearDown()
    }

    /// A controller on this test's settings, attached to a recording of
    /// `source` whose recorder is `recorder`, and detached again at teardown so
    /// no tick loop outlives the test.
    @discardableResult
    private func attachedController(source: RecordingSource, recorder: MockRecorder) -> MicrophoneController {
        let controller = MicrophoneController(settings: settings)
        controller.recordingStarted(source: source, meetingAppName: "Microsoft Teams") { recorder }
        addTeardownBlock { await controller.recordingStopped() }
        return controller
    }

    // MARK: - A changed choice

    /// Settings → Audio and the menu write the same setting, so this is the
    /// switch from either. System Default is stored as the empty string and
    /// reaches the recorder as nil, which is what the capture library takes it
    /// to mean.
    func testAChoiceChangedDuringARecordingReachesItsRecorderOncePerChange() async {
        let recorder = MockRecorder()
        attachedController(source: .appAndMic(pid: 4242), recorder: recorder)

        settings.micDeviceUID = "HeadsetUID"
        await waitFor(recorder.selectMicrophoneCalls.count == 1)
        settings.micDeviceUID = ""
        await waitFor(recorder.selectMicrophoneCalls.count == 2)

        XCTAssertEqual(recorder.selectMicrophoneCalls, ["HeadsetUID", nil])
    }

    /// A stopped recording and one with no microphone track have nothing to
    /// switch. The choice still applies from the next recording, which reads
    /// the setting when it starts.
    func testAChoiceReachesNoRecordingThatHasStoppedOrRecordsNoMicrophone() async {
        let stopped = MockRecorder()
        let stoppedController = MicrophoneController(settings: settings)
        stoppedController.recordingStarted(source: .micOnly, meetingAppName: nil) { stopped }
        stoppedController.recordingStopped()
        let appOnly = MockRecorder()
        attachedController(source: .appOnly(pid: 4242), recorder: appOnly)
        // The control: without it a controller that passes nothing anywhere
        // would satisfy both assertions below.
        let live = MockRecorder()
        attachedController(source: .micOnly, recorder: live)

        settings.micDeviceUID = "HeadsetUID"
        await waitFor(live.selectMicrophoneCalls.count == 1)
        // All three controllers queued their main-actor hop on the same change,
        // before this test's own continuation, so they have all run by now.

        XCTAssertEqual(live.selectMicrophoneCalls, ["HeadsetUID"], "control")
        XCTAssertEqual(stopped.selectMicrophoneCalls, [], "a stopped recording was restarted")
        XCTAssertEqual(appOnly.selectMicrophoneCalls, [], "a recording without a microphone was restarted")
    }

    // MARK: - The recorded device

    func testTheRecordedDeviceIsTheRecordersUntilTheRecordingStops() {
        let recorder = MockRecorder()
        let controller = attachedController(source: .micOnly, recorder: recorder)
        recorder.micInputDevice = headset

        controller.tick()
        XCTAssertEqual(controller.recordedDevice, headset)

        controller.recordingStopped()
        XCTAssertNil(controller.recordedDevice)
        // Nothing can bring it back after the stop, a stray tick included.
        controller.tick()
        XCTAssertNil(controller.recordedDevice)
    }

    /// The menu names the device a recording is capturing from, so a fallback
    /// to the system default, or a switch, has to show up without anyone asking.
    func testTheRecordedDeviceFollowsTheRecorderOnItsOwnWhileAttached() async {
        let recorder = MockRecorder()
        recorder.micInputDevice = builtIn
        let controller = attachedController(source: .micOnly, recorder: recorder)

        await waitFor(controller.recordedDevice == builtIn, timeout: .seconds(2))
        XCTAssertEqual(controller.recordedDevice, builtIn)
        recorder.micInputDevice = headset
        await waitFor(controller.recordedDevice == headset, timeout: .seconds(3))
        XCTAssertEqual(controller.recordedDevice, headset)
    }

    // MARK: - The device list

    /// What the providers report when asked; the test changes it between asks.
    private final class DeviceSource {
        var devices: [MicrophoneDevice] = []
        var defaultInputName: String?
    }

    /// A controller reading its list from `source`, observing `center` rather
    /// than the process-wide one, so posting a device notification here
    /// reaches no other controller in the process.
    private func listingController(_ source: DeviceSource, center: NotificationCenter) -> MicrophoneController {
        MicrophoneController(
            settings: settings,
            listDevices: { source.devices },
            readDefaultInputName: { source.defaultInputName },
            notificationCenter: center,
        )
    }

    func testRefreshDevicesPublishesTheListAndTheDefaultInputNameTheProvidersReport() {
        let source = DeviceSource()
        source.devices = [builtInEntry]
        source.defaultInputName = "MacBook Pro Microphone"
        let controller = listingController(source, center: NotificationCenter())
        XCTAssertEqual(controller.devices, [builtInEntry], "read at init")
        XCTAssertEqual(controller.defaultInputName, "MacBook Pro Microphone", "read at init")

        source.devices = [builtInEntry, headsetEntry]
        source.defaultInputName = "Headset"
        controller.refreshDevices()

        XCTAssertEqual(controller.devices, [builtInEntry, headsetEntry])
        XCTAssertEqual(controller.defaultInputName, "Headset")
    }

    /// A device plugged in or pulled out shows up without restarting the app,
    /// and a recording starts from a fresh list. (The macOS default input
    /// changing is a Core Audio listener on the real system object, which a
    /// test cannot fire without changing the user's default input.)
    func testTheListIsRefreshedAtRecordingStartAndWhenADeviceConnectsOrDisconnects() async {
        let source = DeviceSource()
        let center = NotificationCenter()
        let controller = listingController(source, center: center)
        addTeardownBlock { await controller.recordingStopped() }

        source.devices = [builtInEntry]
        controller.recordingStarted(source: .micOnly, meetingAppName: nil) { nil }
        XCTAssertEqual(controller.devices, [builtInEntry], "recording start")

        source.devices = [builtInEntry, headsetEntry]
        center.post(name: AVCaptureDevice.wasConnectedNotification, object: nil)
        await waitFor(controller.devices == [builtInEntry, headsetEntry])
        XCTAssertEqual(controller.devices, [builtInEntry, headsetEntry], "connect")

        source.devices = [headsetEntry]
        center.post(name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        await waitFor(controller.devices == [headsetEntry])
        XCTAssertEqual(controller.devices, [headsetEntry], "disconnect")
    }

    // MARK: - Wiring

    /// `WatchingController` attaches the controller on the recording transition,
    /// with a provider that reaches the loop's recorder, and detaches it on the
    /// transition that ends the recording.
    ///
    /// The controller observes this test's settings rather than the
    /// controller's: the factory builds those itself, after this controller
    /// has to exist. AppState hands both the same instance.
    func testAMicrophoneRecordingAttachesTheControllerAndStoppingItDetachesIt() async throws {
        let microphone = MicrophoneController(settings: settings)
        let recorder = makeMockRecorder()
        let logDir = try makeTempDirectory(prefix: "MicrophoneControllerTests")
        let controller = makeWatchingController(
            // One line, as in `WatchingControllerManualRecordingTests`: a
            // trailing closure would bind to `makeDetector`.
            // swiftlint:disable:next trailing_closure
            logDir: logDir, permissionHealth: .allHealthy, microphone: microphone, makeRecorder: { recorder },
        )
        addTeardownBlock { await controller.stopManualRecording() }

        let start = try XCTUnwrap(controller.beginManualRecording(.microphone))
        let started = await start.value
        XCTAssertEqual(started, .started, "precondition")

        XCTAssertEqual(microphone.attachment?.source, .micOnly)
        XCTAssertEqual(microphone.attachment?.meetingAppName, ManualRecordingInfo.microphoneAppName)
        settings.micDeviceUID = "HeadsetUID"
        await waitFor(recorder.selectMicrophoneCalls.count == 1)
        XCTAssertEqual(recorder.selectMicrophoneCalls, ["HeadsetUID"], "the provider reaches the loop's recorder")

        controller.stopManualRecording()

        XCTAssertNil(microphone.attachment)
    }
}
