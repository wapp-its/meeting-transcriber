import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Channel health while the recording is paused: nothing captured then is
/// saved, so nothing is judged, and after the resume every window runs from
/// the resume. Driven through `applyTick` with a `MockRecorder` whose
/// `isPaused` the test sets, one tick per second against the harness's 30 s
/// window.
@MainActor
final class ChannelHealthPauseTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let window: TimeInterval = 30

    /// Inputs that raise one of the three warnings in an unpaused recording.
    private struct Scenario {
        let name: String
        let micDBFS: Double
        let appDBFS: Double
        let micAges: ChannelSignalAges
        let raised: @MainActor (ChannelHealthController, RecordingNotifier) -> Bool
    }

    private static let tint = Scenario(
        name: "tint", micDBFS: -120, appDBFS: -20, micAges: .deliveringSignalNow,
    ) { controller, _ in
        controller.micSilentActive
    }

    private static let silentRecording = Scenario(
        name: "silent recording", micDBFS: -120, appDBFS: -120, micAges: .deliveringSignalNow,
    ) { controller, notifier in
        controller.recordingSilentActive && notifier.calls.map(\.title) == ["Recording Appears Silent"]
    }

    private static let captureFault = Scenario(
        name: "capture fault", micDBFS: -30, appDBFS: -30, micAges: ChannelHealthHarness.stoppedDelivering,
    ) { controller, notifier in
        controller.micFault == .noBuffers && notifier.calls.map(\.title) == ["Capture Channel Silent"]
    }

    private func make(_ scenario: Scenario) -> (ChannelHealthController, MockRecorder, RecordingNotifier) {
        let (controller, recorder, notifier, _) = ChannelHealthHarness.make(for: self)
        recorder.micLevelDBFS = scenario.micDBFS
        recorder.appLevelDBFS = scenario.appDBFS
        recorder.micSignalAges = scenario.micAges
        return (controller, recorder, notifier)
    }

    private func tick(
        _ controller: ChannelHealthController, _ recorder: MockRecorder, from start: TimeInterval, through end: TimeInterval,
    ) {
        for offset in stride(from: start, through: end, by: 1) {
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }
    }

    private func nothingRaised(_ controller: ChannelHealthController, _ notifier: RecordingNotifier) -> Bool {
        !controller.micSilentActive && !controller.appSilentActive && !controller.recordingSilentActive
            && controller.micFault == nil && controller.appFault == nil && notifier.calls.isEmpty
    }

    /// Twenty seconds unpaused (under the window), a 300 s pause, then the
    /// resume: nothing during the pause, nothing until the window has passed
    /// from the resume, and then the warning. The lead-in is what would trip
    /// a monitor or clock that kept counting from before the pause.
    func testNothingIsRaisedWhilePausedNorUntilTheWindowHasPassedFromTheResume() {
        for scenario in [Self.tint, Self.silentRecording, Self.captureFault] {
            let (controller, recorder, notifier) = make(scenario)

            tick(controller, recorder, from: 0, through: 20)
            recorder.isPaused = true
            tick(controller, recorder, from: 21, through: 320)
            XCTAssertTrue(nothingRaised(controller, notifier), "\(scenario.name): raised while paused")

            recorder.isPaused = false
            let resume: TimeInterval = 321
            tick(controller, recorder, from: resume, through: resume + window - 1)
            XCTAssertTrue(nothingRaised(controller, notifier), "\(scenario.name): raised inside the window after the resume")

            tick(controller, recorder, from: resume + window, through: resume + window)
            XCTAssertTrue(scenario.raised(controller, notifier), "\(scenario.name): not raised once the window passed")
        }
    }

    /// A tint or silent flag raised before the pause clears when it begins,
    /// and the warning is not posted again during it.
    func testAPauseClearsTheFlagsAlreadyRaised() {
        for scenario in [Self.tint, Self.silentRecording] {
            let (controller, recorder, notifier) = make(scenario)
            tick(controller, recorder, from: 0, through: 40)
            XCTAssertTrue(scenario.raised(controller, notifier), "\(scenario.name): precondition")
            let postedBefore = notifier.calls.count

            recorder.isPaused = true
            tick(controller, recorder, from: 41, through: 340)

            XCTAssertFalse(controller.micSilentActive || controller.recordingSilentActive, scenario.name)
            XCTAssertEqual(notifier.calls.count, postedBefore, scenario.name)
        }
    }

    func testAFaultReportedBeforeThePauseIsNotReportedAgain() {
        let (controller, recorder, notifier) = make(Self.captureFault)
        tick(controller, recorder, from: 0, through: 30)
        XCTAssertTrue(Self.captureFault.raised(controller, notifier), "precondition")

        recorder.isPaused = true
        tick(controller, recorder, from: 31, through: 330)
        recorder.isPaused = false
        tick(controller, recorder, from: 331, through: 331 + 4 * window)

        XCTAssertEqual(notifier.calls.map(\.title), ["Capture Channel Silent"], "reported once, before the pause")
        XCTAssertEqual(controller.micFault, .noBuffers)
    }

    /// The give-up is terminal and does not wait for a window, so the first
    /// tick after the resume reports it.
    func testAGiveUpDuringThePauseIsReportedOnTheFirstTickAfterIt() {
        let healthy = Scenario(name: "healthy", micDBFS: -30, appDBFS: -30, micAges: .deliveringSignalNow) { _, _ in false }
        let (controller, recorder, notifier) = make(healthy)
        tick(controller, recorder, from: 0, through: 10)
        recorder.isPaused = true
        tick(controller, recorder, from: 11, through: 20)
        recorder.micCaptureGaveUp = true
        tick(controller, recorder, from: 21, through: 300)
        XCTAssertTrue(nothingRaised(controller, notifier), "a give-up is not reported while paused")

        recorder.isPaused = false
        tick(controller, recorder, from: 301, through: 301)

        XCTAssertEqual(notifier.calls.map(\.title), ["Capture Channel Lost"])
        XCTAssertEqual(controller.micFault, .gaveUp)
    }

    // MARK: - A pause between two ticks

    /// The poll reads `isPaused` once per tick, so a short pause can begin and
    /// end between two reads. Silence observed through 29 s, then a pause and
    /// a resume before the 30 s tick: nothing at 30 s, where the window from
    /// before the pause would have ended, and the warning once the window has
    /// passed from the resume.
    func testAPauseBetweenTwoTicksStillRestartsTheWindows() {
        for scenario in [Self.tint, Self.silentRecording, Self.captureFault] {
            let (controller, recorder, notifier) = make(scenario)
            tick(controller, recorder, from: 0, through: window - 1)

            recorder.pause()
            recorder.resume()
            tick(controller, recorder, from: window, through: 2 * window - 1)
            XCTAssertTrue(nothingRaised(controller, notifier), "\(scenario.name): raised on the window from before the pause")

            tick(controller, recorder, from: 2 * window, through: 2 * window)
            XCTAssertTrue(scenario.raised(controller, notifier), "\(scenario.name): not raised once the window passed from the resume")
        }
    }
}
