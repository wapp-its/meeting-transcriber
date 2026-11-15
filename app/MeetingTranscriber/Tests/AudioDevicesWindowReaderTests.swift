import CoreAudio
@testable import MeetingTranscriber
import XCTest

/// The Audio Devices window's reader, through injected Core Audio reads: no
/// hardware is asked and none needs to be present.
@MainActor
final class AudioDevicesWindowReaderTests: XCTestCase {
    /// The reads the reader runs: counted, where they ran recorded, and held
    /// until the test lets go while `hold()` is on.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var held = false
        private var askedStorage: [[pid_t]] = []
        private var onMainStorage: [Bool] = []
        private var readingStorage = AudioDeviceStatusReading(running: ["MicUID": true], selfRunningInput: false, meetingApp: nil)

        var asked: [[pid_t]] {
            lock.withLock { askedStorage }
        }

        var ranOnMain: [Bool] {
            lock.withLock { onMainStorage }
        }

        var count: Int {
            asked.count
        }

        var reading: AudioDeviceStatusReading {
            get { lock.withLock { readingStorage } }
            set { lock.withLock { readingStorage = newValue } }
        }

        func hold() {
            lock.withLock { held = true }
        }

        /// Lets a held read return; one is out at most.
        func release() {
            let wasHeld = lock.withLock {
                defer { held = false }
                return held
            }
            if wasHeld { gate.signal() }
        }

        /// Never holds on the main thread: a read there would deadlock the
        /// test, which then hangs instead of failing on `ranOnMain`.
        func read(_ pids: [pid_t]) -> AudioDeviceStatusReading {
            let onMain = Thread.isMainThread
            let wait = lock.withLock {
                askedStorage.append(pids)
                onMainStorage.append(onMain)
                return held && !onMain
            }
            if wait { gate.wait() }
            return reading
        }
    }

    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func advance(_ seconds: TimeInterval) {
            now += seconds
        }
    }

    private final class Levels {
        var mic: Double? = -120
        var app: Double? = -120
        var samples = 0
    }

    private let teamsDevices = MeetingAppDevices(
        inputUIDs: ["MicUID"], outputUIDs: ["SpeakerUID"], inputComplete: true, outputComplete: true,
    )

    private func makeReader(
        _ reads: Reads, clock: Clock = Clock(), levels: Levels = Levels(), recorder: MockRecorder? = nil,
    ) -> AudioDevicesWindowReader {
        let reader = AudioDevicesWindowReader(
            read: { reads.read($0) },
            levels: {
                levels.samples += 1
                return (levels.mic, levels.app)
            },
            recorder: { recorder },
            now: { clock.now },
        )
        addTeardownBlock { @MainActor in
            reader.windowClosed()
            reads.release()
        }
        return reader
    }

    // MARK: - Off the main thread, one at a time

    func testReadingsRunOffTheMainThreadAndOneAtATime() async throws {
        let reads = Reads()
        reads.hold()
        let clock = Clock()
        let reader = makeReader(reads, clock: clock)

        reader.windowOpened()
        await waitFor(reads.count == 1, timeout: .seconds(2))
        for _ in 0 ..< 3 {
            clock.advance(0.6)
            reader.tick()
        }
        XCTAssertEqual(reads.count, 1, "a reading due while one is out waits for it")

        reads.release()
        await waitFor(reader.status.running != nil, timeout: .seconds(2))
        XCTAssertEqual(reader.status.running, ["MicUID": true])
        XCTAssertFalse(try XCTUnwrap(reader.selfRunningInput))
        XCTAssertEqual(reads.ranOnMain, [false])
    }

    /// Two seconds without an answer: the rows it would answer read unknown,
    /// the window's own state keeps updating, and the late answer is dropped
    /// for the next reading's.
    func testAReadingHeldPastTwoSecondsTurnsTheRowsUnknownUntilALaterOneReturns() async {
        let reads = Reads()
        let clock = Clock()
        let levels = Levels()
        let reader = makeReader(reads, clock: clock, levels: levels)
        reader.windowOpened()
        await waitFor(reader.status.running != nil, timeout: .seconds(2))

        reads.hold()
        clock.advance(1)
        reader.tick()
        await waitFor(reads.count == 2, timeout: .seconds(2))
        clock.advance(1.5)
        reader.tick()
        XCTAssertEqual(reader.status.running, ["MicUID": true], "not late yet")

        clock.advance(0.5)
        reader.tick()
        XCTAssertEqual(reader.status, .unknown)
        XCTAssertNil(reader.selfRunningInput)
        levels.mic = -30
        reader.tick()
        XCTAssertEqual(reader.micLitSegments, 6, "the levels still sample while a reading is late")

        reads.reading = AudioDeviceStatusReading(running: ["MicUID": false], selfRunningInput: false, meetingApp: nil)
        reads.release()
        await waitFor(reader.status.running == ["MicUID": false], timeout: .seconds(2))
        XCTAssertEqual(reader.status.running, ["MicUID": false])
        XCTAssertEqual(reads.count, 3, "the late answer was dropped and a later reading answered")
    }

    /// A reading that returns past the deadline before any tick marked it
    /// late is late all the same: its answer is dropped, and the next
    /// reading's is shown.
    func testAReadingReturningPastTheDeadlineBeforeATickIsDroppedAsLate() async {
        let reads = Reads()
        let clock = Clock()
        let reader = makeReader(reads, clock: clock)
        reader.windowOpened()
        await waitFor(reader.status.running != nil, timeout: .seconds(2))

        reads.hold()
        clock.advance(1)
        reader.tick()
        await waitFor(reads.count == 2, timeout: .seconds(2))
        reads.reading = AudioDeviceStatusReading(running: ["MicUID": false], selfRunningInput: true, meetingApp: nil)
        clock.advance(2.01)
        reads.release()
        await waitFor(reader.status.running == ["MicUID": false], timeout: .seconds(2))

        XCTAssertEqual(reader.status.running, ["MicUID": false])
        XCTAssertEqual(reads.count, 3, "the overdue answer was dropped and a later reading answered")
    }

    // MARK: - Only while the window is open

    func testNothingIsReadWhileTheWindowIsClosedAndClosingItStopsTheReads() async throws {
        let reads = Reads()
        let clock = Clock()
        let reader = makeReader(reads, clock: clock)
        clock.advance(10)
        reader.tick()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(reads.count, 0, "never opened")

        reader.windowOpened()
        await waitFor(reader.status.running != nil, timeout: .seconds(2))
        reader.windowClosed()
        XCTAssertEqual(reader.status, .unknown)
        XCTAssertNil(reader.selfRunningInput)
        clock.advance(10)
        reader.tick()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(reads.count, 1, "closed")
    }

    /// The window reads two values the recording already holds and calls
    /// nothing on the recorder: no start, stop, pause, resume or switch.
    func testOpeningAndClosingTheWindowDuringARecordingCallsNothingOnTheRecorder() async {
        let reads = Reads()
        let recorder = MockRecorder()
        recorder.microphoneTrackActive = true
        recorder.tappedPIDs = [42]
        let reader = makeReader(reads, recorder: recorder)

        reader.windowOpened()
        await waitFor(reader.status.running != nil, timeout: .seconds(2))
        XCTAssertTrue(reader.microphoneTrackActive)
        reader.windowClosed()

        XCTAssertEqual(reads.asked.first, [42], "the reading asked about the tapped processes")
        XCTAssertEqual(recorder.calls, [])
        XCTAssertEqual(recorder.selectMicrophoneCalls, [])
        XCTAssertEqual(recorder.pauseCallCount, 0)
        XCTAssertEqual(recorder.resumeCallCount, 0)
    }

    // MARK: - The meeting app's devices

    /// Asked at once for a recording's taps, then every five seconds; an
    /// answer is kept only while the recording still taps what it asked about.
    func testTheTappedProcessesAreAskedAboutEveryFiveSecondsWhileTheyAreTapped() async {
        let reads = Reads()
        reads.reading = AudioDeviceStatusReading(running: ["MicUID": true], selfRunningInput: false, meetingApp: teamsDevices)
        let clock = Clock()
        let recorder = MockRecorder()
        recorder.tappedPIDs = [42]
        let reader = makeReader(reads, clock: clock, recorder: recorder)

        reader.windowOpened()
        await waitFor(reader.status.meetingApp != nil, timeout: .seconds(2))
        XCTAssertEqual(reader.status.meetingApp, teamsDevices)
        clock.advance(1)
        reader.tick()
        await waitFor(reads.count == 2, timeout: .seconds(2))
        clock.advance(4)
        reader.tick()
        await waitFor(reads.count == 3, timeout: .seconds(2))
        XCTAssertEqual(reads.asked, [[42], [], [42]])

        await waitFor(reader.status.meetingApp != nil, timeout: .seconds(2))
        reads.hold()
        clock.advance(5)
        reader.tick()
        await waitFor(reads.count == 4, timeout: .seconds(2))
        recorder.tappedPIDs = []
        reader.tick()
        reads.reading = AudioDeviceStatusReading(running: ["MicUID": false], selfRunningInput: false, meetingApp: teamsDevices)
        reads.release()
        await waitFor(reader.status.running == ["MicUID": false], timeout: .seconds(2))

        XCTAssertEqual(reader.status.running, ["MicUID": false], "the held reading was adopted")
        XCTAssertNil(reader.status.meetingApp, "the recording ended while the read was out")
    }

    // MARK: - Level sampling

    /// At least ten times a second while the window is open, never while it
    /// is closed; a bar follows the level within a couple of samples.
    func testTheLevelsAreSampledEveryHundredMillisecondsOnlyWhileTheWindowIsOpen() async throws {
        XCTAssertLessThanOrEqual(AudioDevicesWindowReader.sampleInterval, .milliseconds(100))
        let levels = Levels()
        let reader = makeReader(Reads(), levels: levels)

        reader.windowOpened()
        levels.mic = -30
        levels.app = 0
        await waitFor(reader.micLitSegments == 6 && reader.appLitSegments == 12, timeout: .milliseconds(300))
        XCTAssertEqual(reader.micLitSegments, 6)
        XCTAssertEqual(reader.appLitSegments, 12)
        try await Task.sleep(for: .milliseconds(450))
        let whileOpen = levels.samples
        XCTAssertGreaterThanOrEqual(whileOpen, 4)

        reader.windowClosed()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(levels.samples, whileOpen)
        XCTAssertEqual(reader.micLitSegments, 0)
    }

    // MARK: - The hardware side

    /// Selectors the probe may read: property reads only.
    private static let readSelectors: Set<AudioObjectPropertySelector> = [
        kAudioHardwarePropertyDevices, kAudioDevicePropertyDeviceUID, kAudioDevicePropertyDeviceIsRunningSomewhere,
        kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyDevices,
    ]

    private final class SelectorLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Set<AudioObjectPropertySelector> = []
        var selectors: Set<AudioObjectPropertySelector> {
            lock.withLock { storage }
        }

        func note(_ selector: AudioObjectPropertySelector) {
            _ = lock.withLock { storage.insert(selector) }
        }
    }

    /// Devices 10 and 11 answer; 12's UID and 13's running flag fail and are
    /// left out. This app is process 990; pid 42 is process 420, which uses
    /// device 10 for input and 11 and 14 for output, 14's UID failing; pid 7
    /// has no process object, and pid 8's translation fails.
    func testTheProbeReportsWhatItCouldReadAndLeavesOutWhatItCouldNot() throws {
        let log = SelectorLog()
        let reads = MeetingMicrophoneProbe.RawReads(
            processObject: { pid in pid == 8 ? .failed(2_003_332_927) : .value([99: 990, 42: 420][pid]) },
            uint32: { object, selector, _ in
                log.note(selector)
                return switch (object, selector) {
                case (10, kAudioDevicePropertyDeviceIsRunningSomewhere), (12, kAudioDevicePropertyDeviceIsRunningSomewhere): .value(1)
                case (11, kAudioDevicePropertyDeviceIsRunningSomewhere): .value(0)
                case (990, kAudioProcessPropertyIsRunningInput): .value(0)
                default: .failed(-50)
                }
            },
            objectIDs: { object, selector, scope in
                log.note(selector)
                return switch (object, scope) {
                case (AudioObjectID(kAudioObjectSystemObject), _): .value([10, 11, 12, 13])
                case (420, kAudioObjectPropertyScopeInput): .value([10])
                case (420, kAudioObjectPropertyScopeOutput): .value([11, 14])
                default: .failed(-1)
                }
            },
            string: { object, selector in
                log.note(selector)
                return switch object {
                case 10: .value("MicUID")
                case 11: .value("SpeakerUID")
                case 13: .value("BusyUID")
                default: .failed(1_852_797_029)
                }
            },
        )

        let reading = AudioDeviceStatusProbe.read(tappedPIDs: [7, 42], ownPID: 99, reads: reads)

        XCTAssertEqual(reading.running, ["MicUID": true, "SpeakerUID": false])
        XCTAssertFalse(try XCTUnwrap(reading.selfRunningInput))
        XCTAssertEqual(reading.meetingApp, MeetingAppDevices(
            inputUIDs: ["MicUID"], outputUIDs: ["SpeakerUID"], inputComplete: true, outputComplete: false,
        ))
        XCTAssertEqual(AudioDeviceStatusProbe.read(tappedPIDs: [8, 42], ownPID: 99, reads: reads).meetingApp, MeetingAppDevices(
            inputUIDs: ["MicUID"], outputUIDs: ["SpeakerUID"], inputComplete: false, outputComplete: false,
        ), "a failed translation leaves both sides incomplete")
        XCTAssertNil(AudioDeviceStatusProbe.read(tappedPIDs: [], ownPID: 99, reads: reads).meetingApp)
        XCTAssertNil(AudioDeviceStatusProbe.read(tappedPIDs: [], ownPID: 5, reads: reads).selfRunningInput)
        XCTAssertNil(AudioDeviceStatusProbe.read(tappedPIDs: [], ownPID: 8, reads: reads).selfRunningInput)
        XCTAssertTrue(log.selectors.isSubset(of: Self.readSelectors), "\(log.selectors)")
    }
}
