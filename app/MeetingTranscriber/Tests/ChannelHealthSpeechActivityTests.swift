@testable import MeetingTranscriber
import XCTest

/// The silence clock the long-silence question reads: when the
/// channel-health poll first observed the recording, and when it last heard
/// speech on a channel the recording opened. Driven through `applyTick`, the
/// seam the 10 Hz poll calls.
@MainActor
final class ChannelHealthSpeechActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ second: TimeInterval) -> Date {
        t0.addingTimeInterval(second)
    }

    /// One tick at `second` with the given levels.
    private func tick(
        _ controller: ChannelHealthController,
        _ recorder: MockRecorder,
        at second: TimeInterval,
        mic: Double = -120,
        app: Double = -120,
    ) {
        recorder.micLevelDBFS = mic
        recorder.appLevelDBFS = app
        controller.applyTick(recorder: recorder, now: at(second))
    }

    func testNilBeforeTheFirstTick() {
        let (controller, _, _, _) = ChannelHealthHarness.make(for: self)
        controller.simulateStartForTests()
        XCTAssertNil(controller.speechActivity)
    }

    func testObservedSinceIsTheFirstTick() {
        let (controller, recorder, _, _) = ChannelHealthHarness.make(for: self)
        controller.simulateStartForTests()
        tick(controller, recorder, at: 0)
        tick(controller, recorder, at: 5)
        XCTAssertEqual(controller.speechActivity, SpeechActivity(observedSince: t0, lastSpeechAt: nil))
        XCTAssertEqual(controller.speechActivity?.silentSince, t0)
    }

    func testLastSpeechFollowsTheLatestSpeechTickOnEitherChannelOfADualRecording() {
        let (controller, recorder, _, _) = ChannelHealthHarness.make(for: self)
        controller.simulateStartForTests(channels: .micAndApp)
        tick(controller, recorder, at: 0)
        tick(controller, recorder, at: 1, mic: -30)
        tick(controller, recorder, at: 2)
        XCTAssertEqual(controller.speechActivity?.lastSpeechAt, at(1))

        tick(controller, recorder, at: 3, app: -30)
        XCTAssertEqual(controller.speechActivity?.lastSpeechAt, at(3))

        // The speech threshold counts as speech; anything below it does not.
        tick(controller, recorder, at: 4, mic: -50)
        tick(controller, recorder, at: 5, mic: -50.1, app: -55)
        XCTAssertEqual(controller.speechActivity?.lastSpeechAt, at(4))
        XCTAssertEqual(controller.speechActivity?.silentSince, at(4))
        XCTAssertEqual(controller.speechActivity?.observedSince, t0)
    }

    private struct ChannelRow {
        let name: String
        let channels: CapturedChannels
        let mic: Double
        let app: Double
        let heard: Bool
    }

    func testOnlyTheChannelsTheRecordingOpenedCount() {
        // Levels are whatever a test sets: in production an unopened channel
        // reads -120 dBFS, which the filter must not depend on.
        let rows: [ChannelRow] = [
            ChannelRow(name: "mic-only ignores app speech", channels: .micOnly, mic: -120, app: -30, heard: false),
            ChannelRow(name: "mic-only hears the mic", channels: .micOnly, mic: -30, app: -120, heard: true),
            ChannelRow(name: "app-only ignores mic speech", channels: .appOnly, mic: -30, app: -120, heard: false),
            ChannelRow(name: "app-only hears the app", channels: .appOnly, mic: -120, app: -30, heard: true),
        ]
        for row in rows {
            let (controller, recorder, _, _) = ChannelHealthHarness.make(for: self)
            controller.simulateStartForTests(channels: row.channels)
            tick(controller, recorder, at: 0)
            tick(controller, recorder, at: 1, mic: row.mic, app: row.app)
            XCTAssertEqual(
                controller.speechActivity,
                SpeechActivity(observedSince: t0, lastSpeechAt: row.heard ? at(1) : nil),
                row.name,
            )
        }
    }

    func testStopClearsIt() {
        let (controller, recorder, _, _) = ChannelHealthHarness.make(for: self)
        controller.simulateStartForTests()
        tick(controller, recorder, at: 0, mic: -30)
        XCTAssertNotNil(controller.speechActivity)

        controller.stop()
        XCTAssertNil(controller.speechActivity)
    }
}
