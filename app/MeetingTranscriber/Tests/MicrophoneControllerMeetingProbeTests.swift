import AudioTapLib
import CoreAudio
@testable import MeetingTranscriber
import XCTest

/// The meeting-app microphone probe as `MicrophoneController` runs it: when the
/// reader is called, that its result comes back by a main-actor hop and only
/// for the recording it was started for, and what reaches the log, the
/// notification and the menu hint. The reader is injected, so nothing here
/// asks Core Audio.
///
/// The controller's own once-a-second tick loop runs beside the test's
/// `tick()` calls. Each test drives its ticks synchronously and finishes well
/// inside the five seconds that loop would need to reach a due probe on its own.
@MainActor
final class MicrophoneControllerMeetingProbeTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var settings: AppSettings!
    private var suiteName: String!
    private var notifier: RecordingNotifier!
    private var log: RecordingDiagnostics!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "MicrophoneControllerMeetingProbeTests-\(getpid())-\(UUID().uuidString)"
        settings = try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: suiteName)))
        settings.verboseDiagnostics = false
        notifier = RecordingNotifier()
        log = RecordingDiagnostics()
    }

    override func tearDown() async throws {
        settings = nil
        notifier = nil
        log = nil
        DefaultsSuite.remove(suiteName)
        suiteName = nil
        try await super.tearDown()
    }

    private static let recorded = MicInputDevice(uid: "AnnasAirPodsUID-7F3A", name: "Anna's AirPods Pro")
    private static let usbMic = MeetingInputDevice(
        objectID: 81, uid: .value("DeskUSBMicUID-91C2"), name: .value("Desk USB Microphone"),
        transport: .value(kAudioDeviceTransportTypeUSB),
    )
    private static let airPods = MeetingInputDevice(
        objectID: 73, uid: .value("AnnasAirPodsUID-7F3A"), name: .value("Anna's AirPods Pro"),
        transport: .value(kAudioDeviceTransportTypeBluetooth),
    )
    private static let mismatching = capturing([usbMic])
    private static let matching = capturing([airPods])

    private static func capturing(_ devices: [MeetingInputDevice]) -> [MeetingInputProcess] {
        [MeetingInputProcess(pid: 4242, executableName: "MSTeams", isRunningInput: .value(true), inputDevices: .value(devices))]
    }

    /// The injected reader: answers with `processes`, records each call and
    /// whether it ran on the main thread, and waits after `block()` until
    /// `unblock()`. Called on the controller's probe queue.
    private final class ScriptedReader: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var script: [MeetingInputProcess] = []
        private var pidsPerCall: [[pid_t]] = []
        private var ranOnMain = false
        private var blocked = false

        var processes: [MeetingInputProcess] {
            get { lock.withLock { script } }
            set { lock.withLock { script = newValue } }
        }

        var calls: [[pid_t]] {
            lock.withLock { pidsPerCall }
        }

        var ranOnMainThread: Bool {
            lock.withLock { ranOnMain }
        }

        func block() {
            lock.withLock { blocked = true }
        }

        func unblock() {
            let wasBlocked = lock.withLock {
                defer { blocked = false }
                return blocked
            }
            if wasBlocked { gate.signal() }
        }

        func read(_ pids: [pid_t]) -> [MeetingInputProcess] {
            let (mustWait, answer) = lock.withLock {
                pidsPerCall.append(pids)
                ranOnMain = ranOnMain || Thread.isMainThread
                return (blocked, script)
            }
            if mustWait { gate.wait() }
            return answer
        }
    }

    private func makeController(_ reader: ScriptedReader) -> MicrophoneController {
        MicrophoneController(settings: settings, notifier: notifier, log: log) { reader.read($0) }
    }

    /// A recording of Teams with two tapped processes and a running microphone
    /// track on `recorded`.
    private func meetingRecorder() -> MockRecorder {
        let recorder = MockRecorder()
        recorder.tappedPIDs = [4242, 4243]
        recorder.microphoneTrackActive = true
        recorder.micInputDevice = Self.recorded
        return recorder
    }

    private func attach(_ controller: MicrophoneController, _ recorder: MockRecorder) {
        controller.recordingStarted(source: .appAndMic(pid: 4242), meetingAppName: "Microsoft Teams") { recorder }
        addTeardownBlock { await controller.recordingStopped() }
    }

    /// Tick until a read starts, at most one probe interval.
    private func startProbe(_ controller: MicrophoneController, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0 ..< MeetingMicrophoneWarningPolicy.Limits.production.probeEveryTicks
            where !controller.meetingProbe.readInFlight {
            controller.tick()
        }
        XCTAssertTrue(controller.meetingProbe.readInFlight, "no read started within one probe interval", file: file, line: line)
    }

    /// Start a read and wait until its result has come back.
    private func probeOnce(_ controller: MicrophoneController, file: StaticString = #filePath, line: UInt = #line) async {
        startProbe(controller, file: file, line: line)
        await waitFor(!controller.meetingProbe.readInFlight, timeout: .seconds(2))
    }

    // MARK: - When the reader runs

    /// Off the main thread, with the process ids the recording tapped, and the
    /// fifth tick returns without waiting for it.
    func testTheReaderRunsOnEveryFifthTickOffTheMainThread() async {
        let reader = ScriptedReader()
        reader.processes = Self.matching
        let controller = makeController(reader)
        attach(controller, meetingRecorder())

        for _ in 1 ... 4 {
            controller.tick()
        }
        XCTAssertFalse(controller.meetingProbe.readInFlight, "ticks 1 to 4")
        controller.tick()
        XCTAssertTrue(controller.meetingProbe.readInFlight, "tick 5")
        await waitFor(!controller.meetingProbe.readInFlight, timeout: .seconds(2))

        XCTAssertEqual(reader.calls, [[4242, 4243]])
        XCTAssertFalse(reader.ranOnMainThread)
    }

    /// A microphone-only recording taps nothing, and a microphone that failed
    /// to start leaves the recording app-only with nothing to compare.
    func testNoReadWithoutATappedAppOrARunningMicrophoneTrack() {
        let cases: [(String, (MockRecorder) -> Void)] = [
            ("no tapped process", { $0.tappedPIDs = [] }),
            ("microphone failed to start", { $0.microphoneTrackActive = false }),
        ]
        for (name, configure) in cases {
            let reader = ScriptedReader()
            let controller = makeController(reader)
            let recorder = meetingRecorder()
            configure(recorder)
            attach(controller, recorder)

            for _ in 1 ... 10 {
                controller.tick()
            }
            XCTAssertFalse(controller.meetingProbe.readInFlight, name)
            controller.recordingStopped()
            XCTAssertEqual(reader.calls, [], name)
        }
        XCTAssertEqual(log.lines.map(\.line), [], "nothing came due, so not even a stop line")
    }

    func testProbingStopsWhenTheMicrophoneTrackGivesUp() async {
        let reader = ScriptedReader()
        reader.processes = Self.matching
        let controller = makeController(reader)
        let recorder = meetingRecorder()
        attach(controller, recorder)
        await probeOnce(controller)

        recorder.microphoneTrackActive = false
        await waitFor(!controller.meetingProbe.readInFlight)
        let callsBeforeGiveUp = reader.calls.count
        for _ in 1 ... 10 {
            controller.tick()
        }

        XCTAssertFalse(controller.meetingProbe.readInFlight)
        XCTAssertEqual(reader.calls.count, callsBeforeGiveUp)
        XCTAssertGreaterThan(callsBeforeGiveUp, 0, "precondition")
    }

    /// A mismatch already counted, the second read out when the track gives
    /// up: that read's mismatch must not warn about a microphone no longer
    /// recorded, and the earlier hint goes with the track.
    func testAResultStillOutWhenTheMicrophoneTrackGivesUpIsDropped() async {
        let reader = ScriptedReader()
        reader.processes = Self.mismatching
        let controller = makeController(reader)
        let recorder = meetingRecorder()
        attach(controller, recorder)
        await probeOnce(controller)
        XCTAssertNotNil(controller.meetingAppHint, "precondition: one mismatch")
        reader.block()
        addTeardownBlock { reader.unblock() }
        startProbe(controller)

        recorder.microphoneTrackActive = false
        controller.tick()
        XCTAssertNil(controller.meetingAppHint, "the hint goes with the track")
        reader.unblock()
        await waitFor(!controller.meetingProbe.readInFlight, timeout: .seconds(2))

        XCTAssertFalse(controller.meetingProbe.readInFlight, "the read came back")
        XCTAssertEqual(notifier.calls.count, 0, "the second mismatch came back after the give-up")
        XCTAssertNil(controller.meetingAppHint)
    }

    /// The main thread goes on ticking while the read is stuck; the probe due
    /// meanwhile is skipped and counted, never queued behind it.
    func testAProbeDueWhileAReadIsOutstandingIsSkippedAndCounted() async {
        let reader = ScriptedReader()
        reader.processes = Self.mismatching
        reader.block()
        addTeardownBlock { reader.unblock() }
        let controller = makeController(reader)
        attach(controller, meetingRecorder())

        for _ in 1 ... 10 {
            controller.tick()
        }
        XCTAssertTrue(controller.meetingProbe.readInFlight, "precondition: the first read is still out")
        reader.unblock()
        await waitFor(!controller.meetingProbe.readInFlight, timeout: .seconds(2))
        controller.recordingStopped()

        XCTAssertEqual(reader.calls.count, 1)
        XCTAssertEqual(
            log.lines(.notice, startingWith: "Meeting app microphone at stop"),
            ["Meeting app microphone at stop: lastVerdict=mismatch probes=1 skippedProbes=1 warned=false"],
        )
    }

    /// The read started for one recording comes back while the next is
    /// already attached: neither the stopped recording nor the new one takes it.
    func testAResultArrivingAfterItsRecordingStoppedChangesNothing() async {
        let reader = ScriptedReader()
        reader.processes = Self.mismatching
        reader.block()
        addTeardownBlock { reader.unblock() }
        let controller = makeController(reader)
        let recorder = meetingRecorder()
        attach(controller, recorder)
        for _ in 1 ... 5 {
            controller.tick()
        }
        XCTAssertTrue(controller.meetingProbe.readInFlight, "precondition")

        controller.recordingStopped()
        controller.recordingStarted(source: .appAndMic(pid: 4242), meetingAppName: "Microsoft Teams") { recorder }
        reader.unblock()
        await waitFor(!controller.meetingProbe.readInFlight, timeout: .seconds(2))

        XCTAssertFalse(controller.meetingProbe.readInFlight, "the read came back")
        XCTAssertNil(controller.meetingAppHint)
        XCTAssertEqual(notifier.calls.count, 0)
        XCTAssertEqual(
            log.lines.map(\.line),
            ["Meeting app microphone at stop: lastVerdict=none probes=1 skippedProbes=0 warned=false"],
            "the stopped recording's summary counts the read still out, and its result writes no entry",
        )
    }

    // MARK: - What a result does

    func testTwoMismatchingProbesPostOneTimeSensitiveNotificationAndShowTheHint() async throws {
        let reader = ScriptedReader()
        reader.processes = Self.mismatching
        let controller = makeController(reader)
        attach(controller, meetingRecorder())

        await probeOnce(controller)
        XCTAssertEqual(notifier.calls.count, 0, "one mismatch")
        XCTAssertEqual(controller.meetingAppHint, "Microsoft Teams uses Desk USB Microphone")
        await probeOnce(controller)
        await probeOnce(controller)

        XCTAssertEqual(notifier.calls.count, 1)
        let call = try XCTUnwrap(notifier.calls.first)
        XCTAssertEqual(call.title, "Microphone differs from Microsoft Teams")
        XCTAssertEqual(
            call.body,
            "Recording from Anna's AirPods Pro, but Microsoft Teams uses Desk USB Microphone. "
                + "Choose the microphone in the menu bar under Microphone.",
        )
        XCTAssertEqual(call.urgency, .timeSensitive)
        XCTAssertEqual(controller.meetingAppHint, "Microsoft Teams uses Desk USB Microphone")
    }

    func testTheHintClearsAtAMatchAndAtTheRecordingsEnd() async {
        let reader = ScriptedReader()
        reader.processes = Self.mismatching
        let controller = makeController(reader)
        attach(controller, meetingRecorder())
        await probeOnce(controller)
        XCTAssertNotNil(controller.meetingAppHint, "precondition")

        reader.processes = Self.matching
        await probeOnce(controller)
        XCTAssertNil(controller.meetingAppHint, "a match")

        reader.processes = Self.mismatching
        await probeOnce(controller)
        XCTAssertNotNil(controller.meetingAppHint, "precondition")
        controller.recordingStopped()
        XCTAssertNil(controller.meetingAppHint, "the recording's end")
    }

    /// The capture runs, but on a device it cannot name.
    func testAMicrophoneWithoutAUIDIsJudgedRecordedMicrophoneUnknown() async {
        let reader = ScriptedReader()
        reader.processes = Self.mismatching
        let controller = makeController(reader)
        let recorder = meetingRecorder()
        recorder.micInputDevice = MicInputDevice(uid: nil, name: "Anna's AirPods Pro")
        attach(controller, recorder)

        await probeOnce(controller)

        XCTAssertEqual(
            log.lines(.notice, startingWith: "Meeting app microphone verdict"),
            ["Meeting app microphone verdict (first): undetermined(recordedMicrophoneUnknown) processesWithAudioObject=1/2 capturingInput=1"],
        )
        XCTAssertNil(controller.meetingAppHint)
    }

    // MARK: - The [debug] line

    func testTheDebugLineIsWrittenOnlyWithVerboseAudioLogging() async {
        let reader = ScriptedReader()
        reader.processes = Self.mismatching
        let controller = makeController(reader)
        attach(controller, meetingRecorder())

        await probeOnce(controller)
        XCTAssertEqual(log.lines(.warning, startingWith: "Meeting app microphone verdict (first)").count, 1, "precondition")
        XCTAssertEqual(log.lines(.notice, startingWith: "[debug]"), [], "verbose off")

        settings.verboseDiagnostics = true
        reader.processes = Self.matching
        await probeOnce(controller)

        XCTAssertEqual(
            log.lines(.notice, startingWith: "[debug]"),
            ["[debug] Meeting app microphone devices: 73 name=Anna's AirPods Pro transport=Bluetooth"],
        )
    }

    /// Through the probe's own reads, with only the name read failing.
    func testAFailedNameReadReachesTheDebugLineAsItsStatus() async {
        settings.verboseDiagnostics = true
        let reads = MeetingMicrophoneProbe.RawReads(
            processObject: { AudioObjectID($0) },
            uint32: { _, selector, _ in
                selector == kAudioProcessPropertyIsRunningInput ? .value(1) : .value(kAudioDeviceTransportTypeUSB)
            },
            objectIDs: { _, _, _ in .value([81]) },
            string: { _, selector in
                selector == kAudioObjectPropertyName ? .failed(2_003_332_927) : .value("DeskUSBMicUID-91C2")
            },
        )
        let controller = MicrophoneController(settings: settings, notifier: notifier, log: log) { pids in
            MeetingMicrophoneProbe.read(pids: pids, reads: reads)
        }
        attach(controller, meetingRecorder())

        await probeOnce(controller)

        XCTAssertEqual(
            log.lines(.notice, startingWith: "[debug]"),
            ["[debug] Meeting app microphone devices: 81 name=?(2003332927) transport=USB"],
        )
    }
}
