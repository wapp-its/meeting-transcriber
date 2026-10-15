import CoreAudio
@testable import MeetingTranscriber
import XCTest

/// `OutputDeviceController` warns a recording about the Teams output routing
/// at its start and on each change during it, tints the icon while the routing
/// holds, and switches the Mac's default output for the menu. Core Audio is a
/// fake here: `FakeOutputs` answers the reads, and its `change` is the handler
/// the controller installed, fired the way Core Audio fires its listener.
@MainActor
final class OutputDeviceControllerTests: XCTestCase {
    private let speakers = OutputDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
    private let headset = OutputDevice(uid: "HeadsetUID", name: "Headset")
    private let blackHole = OutputDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
    private let teams = OutputDevice(uid: OutputRoutingWarning.teamsLoopbackUID, name: "Microsoft Teams Audio")
    private let appRecording = RecordingSource.appAndMic(pid: 4242)

    /// The Core Audio stand-in.
    private final class FakeOutputs {
        var devices: [OutputDevice] = []
        var current: OutputDevice?
        var setStatus: OSStatus = noErr
        var setCalls: [String] = []
        var change: (@MainActor () -> Void)?
    }

    private func makeController(
        _ fake: FakeOutputs,
        notifier: RecordingNotifier,
        log: RecordingDiagnostics = RecordingDiagnostics(),
        indicatorEnabled: Bool = true,
    ) -> OutputDeviceController {
        OutputDeviceController(
            notifier: notifier,
            log: log,
            indicatorEnabled: { indicatorEnabled },
            listDevices: { fake.devices },
            readDefault: { fake.current },
            setDefault: { uid in
                fake.setCalls.append(uid)
                if fake.setStatus == noErr { fake.current = fake.devices.first { $0.uid == uid } }
                return fake.setStatus
            },
            observeChanges: { fake.change = $0 },
        )
    }

    /// The Mac's default output becomes `device`, and Core Audio says so.
    private func switchOutput(_ fake: FakeOutputs, to device: OutputDevice?) {
        fake.current = device
        fake.change?()
    }

    private func warnings(_ notifier: RecordingNotifier) -> [(title: String, body: String, urgency: NotificationUrgency)] {
        notifier.calls.filter { $0.title == OutputRoutingWarning.notificationTitle }
    }

    private func routingLines(_ log: RecordingDiagnostics) -> [String] {
        log.lines(.warning, startingWith: "Output routing:")
    }

    private func fake(current: OutputDevice?) -> FakeOutputs {
        let fake = FakeOutputs()
        fake.devices = [speakers, headset, blackHole]
        fake.current = current
        return fake
    }

    // MARK: - Recording start

    func testARecordingThatStartsOnTheTeamsDeviceIsWarnedWithOneLogLine() {
        let notifier = RecordingNotifier()
        let log = RecordingDiagnostics()
        let controller = makeController(fake(current: teams), notifier: notifier, log: log)

        controller.recordingStarted(source: appRecording)

        let sent = warnings(notifier)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.urgency, .timeSensitive)
        XCTAssertEqual(sent.first?.body, OutputRoutingWarning.notificationBody(deviceName: "Microsoft Teams Audio"))
        XCTAssertEqual(routingLines(log), [OutputRoutingWarning.logLine(trigger: .start, uid: teams.uid)])
        XCTAssertTrue(controller.routingWarningActive)
        XCTAssertTrue(controller.appChannelOverlay)
    }

    func testOtherOutputsAndAnUnreadableOneAtTheStartWarnNothing() {
        for current in [speakers, blackHole, nil] {
            let notifier = RecordingNotifier()
            let log = RecordingDiagnostics()
            let controller = makeController(fake(current: current), notifier: notifier, log: log)

            controller.recordingStarted(source: appRecording)

            XCTAssertTrue(warnings(notifier).isEmpty, "\(String(describing: current))")
            XCTAssertTrue(routingLines(log).isEmpty, "\(String(describing: current))")
            XCTAssertFalse(controller.routingWarningActive, "\(String(describing: current))")
        }
    }

    // MARK: - Changes during a recording

    /// The change arrives through the controller's own listener: no capture
    /// callback is involved, so a capture restart cannot hide it.
    func testAChangeToTheTeamsDeviceDuringARecordingWarnsOnceForThatChange() {
        let notifier = RecordingNotifier()
        let log = RecordingDiagnostics()
        let outputs = fake(current: speakers)
        let controller = makeController(outputs, notifier: notifier, log: log)
        controller.recordingStarted(source: appRecording)
        XCTAssertTrue(warnings(notifier).isEmpty, "precondition")

        switchOutput(outputs, to: teams)

        XCTAssertEqual(warnings(notifier).count, 1)
        XCTAssertEqual(routingLines(log), [OutputRoutingWarning.logLine(trigger: .outputChange, uid: teams.uid)])
        XCTAssertTrue(controller.routingWarningActive)
    }

    /// Tap rebuilds create and destroy the app's private aggregate devices, so
    /// Core Audio reports device-list changes while the default output stays
    /// where it is. None of them warns again.
    func testFurtherReportsOnAnUnchangedRoutingPostNothingMore() {
        let notifier = RecordingNotifier()
        let outputs = fake(current: teams)
        let controller = makeController(outputs, notifier: notifier)
        controller.recordingStarted(source: appRecording)

        for _ in 0 ..< 3 {
            switchOutput(outputs, to: teams)
        }

        XCTAssertEqual(warnings(notifier).count, 1)
        XCTAssertTrue(controller.routingWarningActive)
    }

    func testChangingAwayAndBackWarnsAgainAndTheTintFollows() {
        let notifier = RecordingNotifier()
        let outputs = fake(current: teams)
        let controller = makeController(outputs, notifier: notifier)
        controller.recordingStarted(source: appRecording)

        switchOutput(outputs, to: speakers)
        XCTAssertFalse(controller.routingWarningActive)
        XCTAssertFalse(controller.appChannelOverlay)
        XCTAssertEqual(warnings(notifier).count, 1)

        switchOutput(outputs, to: teams)
        XCTAssertEqual(warnings(notifier).count, 2)
        XCTAssertTrue(controller.appChannelOverlay)
    }

    /// An unreadable output in between proves nothing, so coming back to a
    /// readable Teams routing is not a new one.
    func testAnUnreadableReadingInBetweenDoesNotWarnAgain() {
        let notifier = RecordingNotifier()
        let outputs = fake(current: teams)
        let controller = makeController(outputs, notifier: notifier)
        controller.recordingStarted(source: appRecording)

        switchOutput(outputs, to: nil)
        switchOutput(outputs, to: teams)

        XCTAssertEqual(warnings(notifier).count, 1)
    }

    func testChangesBetweenOtherOutputsWarnNothing() {
        let notifier = RecordingNotifier()
        let outputs = fake(current: speakers)
        let controller = makeController(outputs, notifier: notifier)
        controller.recordingStarted(source: appRecording)

        switchOutput(outputs, to: blackHole)
        switchOutput(outputs, to: headset)

        XCTAssertTrue(warnings(notifier).isEmpty)
        XCTAssertFalse(controller.routingWarningActive)
    }

    func testARecordingWithoutAnAppTrackIsNeverWarnedOrTinted() {
        let notifier = RecordingNotifier()
        let outputs = fake(current: teams)
        let controller = makeController(outputs, notifier: notifier)

        controller.recordingStarted(source: .micOnly)
        switchOutput(outputs, to: speakers)
        switchOutput(outputs, to: teams)

        XCTAssertTrue(warnings(notifier).isEmpty)
        XCTAssertFalse(controller.routingWarningActive)
        XCTAssertFalse(controller.appChannelOverlay)
    }

    func testAnAppOnlyRecordingIsWarned() {
        let notifier = RecordingNotifier()
        let controller = makeController(fake(current: teams), notifier: notifier)

        controller.recordingStarted(source: .appOnly(pid: 4242))

        XCTAssertEqual(warnings(notifier).count, 1)
    }

    // MARK: - Recording stop

    func testStoppingClearsTheTintAndAChangeAfterwardsChangesNothing() {
        let notifier = RecordingNotifier()
        let outputs = fake(current: teams)
        let controller = makeController(outputs, notifier: notifier)
        controller.recordingStarted(source: appRecording)
        XCTAssertTrue(controller.routingWarningActive, "precondition")

        controller.recordingStopped()
        XCTAssertFalse(controller.routingWarningActive)

        switchOutput(outputs, to: speakers)
        switchOutput(outputs, to: teams)
        XCTAssertEqual(warnings(notifier).count, 1, "only the warning from the recording")
        XCTAssertFalse(controller.routingWarningActive)
        XCTAssertEqual(controller.current, teams, "the menu still follows the change")
    }

    func testTheNextRecordingStartsWithAFreshMemory() {
        let notifier = RecordingNotifier()
        let controller = makeController(fake(current: teams), notifier: notifier)
        controller.recordingStarted(source: appRecording)
        controller.recordingStopped()

        controller.recordingStarted(source: appRecording)

        XCTAssertEqual(warnings(notifier).count, 2)
    }

    // MARK: - Icon setting

    func testTheTintFollowsThePerChannelIndicatorSettingAndTheWarningDoesNot() {
        let notifier = RecordingNotifier()
        let controller = makeController(fake(current: teams), notifier: notifier, indicatorEnabled: false)

        controller.recordingStarted(source: appRecording)

        XCTAssertTrue(controller.routingWarningActive)
        XCTAssertFalse(controller.appChannelOverlay)
        XCTAssertEqual(warnings(notifier).count, 1)
    }

    // MARK: - Menu

    func testTheMenuStateFollowsChangesMadeElsewhere() {
        let outputs = fake(current: speakers)
        let controller = makeController(outputs, notifier: RecordingNotifier())
        XCTAssertEqual(controller.devices, [speakers, headset, blackHole])

        outputs.devices = [speakers]
        switchOutput(outputs, to: teams)

        XCTAssertEqual(controller.devices, [speakers])
        XCTAssertEqual(controller.current, teams)
    }

    func testChoosingAnOutputMakesItTheMacsDefault() {
        let outputs = fake(current: speakers)
        let log = RecordingDiagnostics()
        let controller = makeController(outputs, notifier: RecordingNotifier(), log: log)

        controller.select(uid: headset.uid)

        XCTAssertEqual(outputs.setCalls, [headset.uid])
        XCTAssertEqual(controller.current, headset)
        XCTAssertTrue(log.lines.isEmpty)
    }

    func testARefusedChoiceKeepsTheActualDeviceAndLogsTheStatus() {
        let outputs = fake(current: speakers)
        outputs.setStatus = kAudioHardwareBadDeviceError
        let log = RecordingDiagnostics()
        let controller = makeController(outputs, notifier: RecordingNotifier(), log: log)

        controller.select(uid: headset.uid)

        XCTAssertEqual(controller.current, speakers)
        XCTAssertEqual(log.lines(.warning, startingWith: "Output device not set"), [
            "Output device not set: status \(kAudioHardwareBadDeviceError)",
        ])
    }

    // MARK: - Attached by WatchingController

    /// `WatchingController` attaches the controller on the recording
    /// transition, with the recording's source, and detaches it on the
    /// transition that ends the recording.
    func testAnAppRecordingAttachesTheControllerAndStoppingItDetachesIt() async throws {
        let notifier = RecordingNotifier()
        let output = makeController(fake(current: teams), notifier: notifier)
        let recorder = makeMockRecorder()
        let logDir = try makeTempDirectory(prefix: "OutputDeviceControllerTests")
        let controller = makeWatchingController(
            // One line: a trailing closure would bind to `makeDetector`.
            // swiftlint:disable:next trailing_closure
            logDir: logDir, permissionHealth: .allHealthy, output: output, makeRecorder: { recorder },
        )
        addTeardownBlock { await controller.stopManualRecording() }

        // This process, so the target is alive for the whole test.
        controller.startManualRecording(pid: getpid(), appName: "Chrome", title: "Standup")
        await waitFor(controller.watchLoop?.state == .recording, timeout: .seconds(2))
        XCTAssertEqual(controller.watchLoop?.state, .recording, "precondition: the recording must have started")

        XCTAssertEqual(warnings(notifier).count, 1)
        XCTAssertTrue(output.routingWarningActive)

        controller.stopManualRecording()

        XCTAssertFalse(output.routingWarningActive)
    }

    func testAMicrophoneRecordingIsAttachedWithoutAnAppTrack() async throws {
        let notifier = RecordingNotifier()
        let output = makeController(fake(current: teams), notifier: notifier)
        let recorder = makeMockRecorder()
        let logDir = try makeTempDirectory(prefix: "OutputDeviceControllerTests")
        let controller = makeWatchingController(
            // swiftlint:disable:next trailing_closure
            logDir: logDir, permissionHealth: .allHealthy, output: output, makeRecorder: { recorder },
        )
        addTeardownBlock { await controller.stopManualRecording() }

        let start = try XCTUnwrap(controller.beginManualRecording(.microphone))
        let started = await start.value
        XCTAssertEqual(started, .started, "precondition")

        XCTAssertTrue(warnings(notifier).isEmpty)
        XCTAssertFalse(output.routingWarningActive)
    }
}
