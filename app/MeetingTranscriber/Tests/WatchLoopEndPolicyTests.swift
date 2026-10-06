@testable import MeetingTranscriber
import XCTest

/// Pure-function tests for the decision policy that drives
/// `WatchLoop.waitForMeetingEnd`. These cover each transition without an async
/// timer loop, so the grace / question / countdown / cap interactions are
/// deterministic.
final class WatchLoopEndPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private static let defaultConfig = WatchLoopEndConfig(maxDuration: 1000, endGracePeriod: 10, countdown: 120)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    /// `answeredAt` is when the answer arrived; by default at this poll.
    private func step(
        _ phase: MeetingEndPhase,
        meetingActive: Bool,
        at seconds: TimeInterval,
        answer: MeetingEndAnswer? = nil,
        answeredAt: TimeInterval? = nil,
        config: WatchLoopEndConfig = defaultConfig,
    ) -> WatchLoopEndDecision {
        WatchLoopEndPolicy.step(
            config: config,
            startTime: t0,
            phase: phase,
            poll: MeetingEndPoll(
                now: at(seconds),
                meetingActive: meetingActive,
                answer: answer.map { ReceivedMeetingEndAnswer(answer: $0, receivedAt: at(answeredAt ?? seconds)) },
            ),
        )
    }

    /// Signal lost at 5 s, grace 10 s, asked at 16 s.
    private var pending: PendingMeetingEnd {
        PendingMeetingEnd(signalLostAt: at(5), cutAt: at(15), deadline: at(136))
    }

    // MARK: - Listening (unchanged grace behaviour)

    func testActiveMeetingClearsGraceOrContinuesWithoutOne() {
        for lost in [at(2), nil] {
            XCTAssertEqual(
                step(.listening(signalLostAt: lost), meetingActive: true, at: 5),
                .continuePolling(.listening(signalLostAt: nil)),
            )
        }
    }

    func testInactiveMeetingStartsGraceWhenNoneRunning() {
        XCTAssertEqual(
            step(.listening(signalLostAt: nil), meetingActive: false, at: 5),
            .continuePolling(.listening(signalLostAt: at(5))),
        )
    }

    func testInactiveMeetingStaysInGraceWhenNotYetExpired() {
        XCTAssertEqual(
            step(.listening(signalLostAt: at(5)), meetingActive: false, at: 14),
            .continuePolling(.listening(signalLostAt: at(5))),
        )
    }

    // MARK: - R1: grace expiry asks instead of stopping

    /// The deadline runs from the question, the cut point from the loss: the
    /// cut is where the silent stop used to end the recording.
    func testGraceExpiryAsksWithCutAtLossPlusGraceAndDeadlineFromNow() {
        XCTAssertEqual(
            step(.listening(signalLostAt: at(5)), meetingActive: false, at: 16),
            .askToEnd(pending),
        )
    }

    func testGraceExpiryUsesGreaterThanOrEqual() {
        XCTAssertEqual(
            step(.listening(signalLostAt: at(0)), meetingActive: false, at: 10),
            .askToEnd(PendingMeetingEnd(signalLostAt: at(0), cutAt: at(10), deadline: at(130))),
        )
    }

    // MARK: - While asking

    func testUnansweredQuestionKeepsPollingBeforeTheDeadline() {
        XCTAssertEqual(
            step(.askingToEnd(pending), meetingActive: false, at: 135),
            .continuePolling(.askingToEnd(pending)),
        )
    }

    /// R2 / R5: no answer by the deadline ends the recording, cut back.
    func testDeadlineStopsCutBackToLossPlusGrace() {
        XCTAssertEqual(
            step(.askingToEnd(pending), meetingActive: false, at: 136),
            .stop(MeetingEndStop(reason: .countdownExpired, cutAt: at(15), signalAbsentFor: 131)),
        )
    }

    /// R2: "Stop now" stops at once, cut back the same way.
    func testStopNowStopsCutBack() {
        XCTAssertEqual(
            step(.askingToEnd(pending), meetingActive: false, at: 40, answer: .stopNow),
            .stop(MeetingEndStop(reason: .stopNow, cutAt: at(15), signalAbsentFor: 35)),
        )
    }

    /// R3: a returning signal takes the question back and listens afresh.
    func testReturningSignalWithdrawsTheQuestion() {
        XCTAssertEqual(
            step(.askingToEnd(pending), meetingActive: true, at: 40),
            .withdrawQuestion(then: .listening(signalLostAt: nil)),
        )
    }

    /// R2 / R3: once the two minutes are up the recording ends, so a signal
    /// first seen at or after the deadline no longer cancels the stop.
    func testASignalFirstSeenAtOrAfterTheDeadlineDoesNotCancelTheStop() {
        for seconds in [136.0, 137.0] {
            XCTAssertEqual(
                step(.askingToEnd(pending), meetingActive: true, at: seconds),
                .stop(MeetingEndStop(reason: .countdownExpired, cutAt: at(15), signalAbsentFor: nil)),
                "seen at \(seconds) s",
            )
        }
    }

    /// R3: a signal seen in time outranks a Stop now tapped while the call was
    /// coming back; the cut would discard the resumed meeting.
    func testAReturningSignalOutranksStopNow() {
        XCTAssertEqual(
            step(.askingToEnd(pending), meetingActive: true, at: 40, answer: .stopNow, answeredAt: 39),
            .withdrawQuestion(then: .listening(signalLostAt: nil)),
        )
    }

    /// R2: only an answer given before the deadline counts, even when the poll
    /// that sees it comes after it.
    func testOnlyAnAnswerGivenBeforeTheDeadlineCounts() {
        let expired = WatchLoopEndDecision.stop(
            MeetingEndStop(reason: .countdownExpired, cutAt: at(15), signalAbsentFor: 132),
        )
        let cases: [(answer: MeetingEndAnswer, answeredAt: TimeInterval, expected: WatchLoopEndDecision)] = [
            (.keepRecording, 135.9, .withdrawQuestion(then: .kept(signalLostAt: at(5)))),
            (.stopNow, 135.9, .stop(MeetingEndStop(reason: .stopNow, cutAt: at(15), signalAbsentFor: 132))),
            (.keepRecording, 136, expired),
            (.keepRecording, 137, expired),
        ]
        for (answer, answeredAt, expected) in cases {
            XCTAssertEqual(
                step(.askingToEnd(pending), meetingActive: false, at: 137, answer: answer, answeredAt: answeredAt),
                expected,
                "\(answer) at \(answeredAt) s",
            )
        }
    }

    /// R4: "Keep recording" keeps the recording and asks nothing more while
    /// the signal stays away; with the signal already back it just listens.
    func testKeepRecordingWithdrawsAndKeeps() {
        let cases: [(active: Bool, then: MeetingEndPhase)] = [
            (false, .kept(signalLostAt: at(5))),
            (true, .listening(signalLostAt: nil)),
        ]
        for (active, then) in cases {
            XCTAssertEqual(
                step(.askingToEnd(pending), meetingActive: active, at: 40, answer: .keepRecording),
                .withdrawQuestion(then: then),
                "signal active: \(active)",
            )
        }
    }

    // MARK: - Kept

    /// No deadline and no second question while the signal stays away, however
    /// long; a returning signal goes back to listening, so the next loss asks.
    func testKeptStaysKeptUntilTheSignalReturns() {
        XCTAssertEqual(
            step(.kept(signalLostAt: at(5)), meetingActive: false, at: 900),
            .continuePolling(.kept(signalLostAt: at(5))),
        )
        XCTAssertEqual(
            step(.kept(signalLostAt: at(5)), meetingActive: true, at: 900),
            .continuePolling(.listening(signalLostAt: nil)),
        )
    }

    // MARK: - Watching stops

    /// R6 / R4: stopping watching cuts only an open question, and an answer
    /// that arrived before the deadline but before any poll saw it has already
    /// settled that question.
    func testStoppingWatchingCutsOnlyAQuestionNoTimelyKeepHasSettled() {
        let cases: [(phase: MeetingEndPhase, answer: MeetingEndAnswer?, answeredAt: TimeInterval, cut: Date?)] = [
            (.askingToEnd(pending), nil, 0, at(15)),
            (.askingToEnd(pending), .keepRecording, 40, nil),
            (.askingToEnd(pending), .keepRecording, 136, at(15)), // after the deadline: no answer
            (.askingToEnd(pending), .stopNow, 40, at(15)),
            (.listening(signalLostAt: at(5)), nil, 0, nil),
            (.kept(signalLostAt: at(5)), nil, 0, nil),
        ]
        for (phase, answer, answeredAt, cut) in cases {
            XCTAssertEqual(
                WatchLoopEndPolicy.cutWhenWatchingStops(
                    phase: phase,
                    answer: answer.map { ReceivedMeetingEndAnswer(answer: $0, receivedAt: at(answeredAt)) },
                ),
                cut,
                "\(phase), \(answer.map(String.init(describing:)) ?? "no answer") at \(answeredAt) s",
            )
        }
    }

    // MARK: - Duration cap

    /// The cap is a hard stop in every phase. It cuts only when it lands on a
    /// question that is still open; one whose countdown also ran out keeps
    /// that reason.
    func testCapStopsInEveryPhaseAndCutsOnlyAnOpenQuestion() {
        // Lost at 950, asked at 960, deadline after the cap.
        let open = PendingMeetingEnd(signalLostAt: at(950), cutAt: at(960), deadline: at(1080))
        let cases: [(phase: MeetingEndPhase, active: Bool, expected: MeetingEndStop)] = [
            (.listening(signalLostAt: nil), true, MeetingEndStop(reason: .maxDuration, cutAt: nil, signalAbsentFor: nil)),
            (.listening(signalLostAt: at(995)), false, MeetingEndStop(reason: .maxDuration, cutAt: nil, signalAbsentFor: 6)),
            (.askingToEnd(open), false, MeetingEndStop(reason: .maxDuration, cutAt: at(960), signalAbsentFor: 51)),
            (.askingToEnd(open), true, MeetingEndStop(reason: .maxDuration, cutAt: nil, signalAbsentFor: nil)),
            (.askingToEnd(pending), false, MeetingEndStop(reason: .countdownExpired, cutAt: at(15), signalAbsentFor: 996)),
            (.kept(signalLostAt: at(5)), false, MeetingEndStop(reason: .maxDuration, cutAt: nil, signalAbsentFor: 996)),
        ]
        for (phase, active, expected) in cases {
            XCTAssertEqual(step(phase, meetingActive: active, at: 1001), .stop(expected), "\(phase), active: \(active)")
        }
    }

    // MARK: - Sequences

    /// Inactive (grace starts) → active (grace clears) → inactive (fresh
    /// grace) → asked only once the fresh grace has run its full length.
    func testGraceResetsWhenMeetingResumesThenEnds() {
        var phase = MeetingEndPhase.listening(signalLostAt: nil)
        for (seconds, active) in [(1.0, false), (2.0, true), (3.0, false), (12.0, false)] {
            guard case let .continuePolling(next) = step(phase, meetingActive: active, at: seconds) else {
                XCTFail("expected to keep polling at \(seconds) s")
                return
            }
            phase = next
        }
        // The first grace started at 1 s and would have expired at 11 s.
        XCTAssertEqual(phase, .listening(signalLostAt: at(3)))
        XCTAssertEqual(
            step(phase, meetingActive: false, at: 13),
            .askToEnd(PendingMeetingEnd(signalLostAt: at(3), cutAt: at(13), deadline: at(133))),
        )
    }

    // MARK: - Log line (R7)

    func testLogLineNamesTriggerReasonAndAbsenceOnly() {
        XCTAssertEqual(
            AutoStopReason.countdownExpired.logLine(trigger: .auto, signalAbsentFor: 134.6),
            "recording_auto_stop trigger=auto reason=countdown_expired signal_absent_s=135",
        )
        XCTAssertEqual(
            AutoStopReason.appExited.logLine(trigger: .manual, pid: 42),
            "recording_auto_stop trigger=manual reason=app_exited pid=42",
        )
        XCTAssertEqual(
            AutoStopReason.maxDuration.logLine(trigger: .manual),
            "recording_auto_stop trigger=manual reason=max_duration",
        )
    }
}
