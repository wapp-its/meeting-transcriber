@testable import MeetingTranscriber
import XCTest

/// The per-poll decision behind "Nothing heard for 5 minutes. Stop the
/// recording?", driven with explicit dates and no sleeping. Every
/// case starts from a recording the poll first observed at `t0` and asks
/// after five minutes, unless it says otherwise.
final class SilencePromptPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct TimedAction: Equatable {
        let second: TimeInterval
        let action: SilencePromptAction
    }

    private func at(_ second: TimeInterval) -> Date {
        t0.addingTimeInterval(second)
    }

    /// One poll at `second`, with the last speech heard at `lastSpeech`
    /// seconds into the recording (nil: none yet).
    private func step(
        _ state: SilencePromptState,
        at second: TimeInterval,
        lastSpeech: TimeInterval? = nil,
        held: Bool = false,
        answer: MeetingEndAnswer? = nil,
        after: TimeInterval? = 300,
    ) -> (action: SilencePromptAction, state: SilencePromptState) {
        SilencePromptPolicy.step(
            after: after,
            now: at(second),
            activity: SpeechActivity(observedSince: t0, lastSpeechAt: lastSpeech.map(at)),
            held: held,
            answer: answer,
            state: state,
        )
    }

    /// Polls once a second over `seconds`, as the watch loop would, carrying
    /// the state, and returns every action other than `.none` with its time.
    private func poll(
        _ state: inout SilencePromptState,
        over seconds: ClosedRange<Int>,
        lastSpeech: TimeInterval? = nil,
        held: Bool = false,
        after: TimeInterval? = 300,
    ) -> [TimedAction] {
        var actions: [TimedAction] = []
        for second in seconds {
            let result = step(state, at: TimeInterval(second), lastSpeech: lastSpeech, held: held, after: after)
            state = result.state
            if result.action != .none {
                actions.append(TimedAction(second: TimeInterval(second), action: result.action))
            }
        }
        return actions
    }

    // MARK: - Asking (R1)

    func testNoQuestionBeforeTheConfiguredTimeAndOneAtExactlyIt() {
        XCTAssertEqual(step(SilencePromptState(), at: 299.9).action, .none)

        var state = SilencePromptState()
        XCTAssertEqual(poll(&state, over: 0 ... 300), [TimedAction(second: 300, action: .ask(silentFor: 300))])
        XCTAssertEqual(state.open?.askedAt, at(300))
        XCTAssertEqual(state.open?.silentSince, t0)
        XCTAssertEqual(state.countFrom, at(300))

        // Before the poll has observed the recording there is no clock to read.
        let unobserved = SilencePromptPolicy.step(
            after: 300, now: at(3600), activity: nil, held: false, answer: nil, state: SilencePromptState(),
        )
        XCTAssertEqual(unobserved.action, .none)
    }

    func testTheTitleCountsWholeMinutesRoundedDownAndTheSingular() {
        let rows: [(silentFor: TimeInterval, title: String)] = [
            (300, "Nothing heard for 5 minutes"),
            (359, "Nothing heard for 5 minutes"),
            (600, "Nothing heard for 10 minutes"),
            (60, "Nothing heard for 1 minute"),
            (119, "Nothing heard for 1 minute"),
            // Never "0 minutes", whatever the configured time.
            (30, "Nothing heard for 1 minute"),
        ]
        for row in rows {
            XCTAssertEqual(SilencePromptPolicy.questionTitle(silentFor: row.silentFor), row.title, "silentFor=\(row.silentFor)")
        }
        XCTAssertEqual(SilencePromptPolicy.questionBody, "Stop the recording? Without an answer, it keeps recording.")
    }

    // MARK: - Speech, Keep recording, no answer (R3, R4)

    func testSpeechWithdrawsTheQuestionAndTheNextComesAFullPeriodAfterIt() {
        var state = SilencePromptState()
        XCTAssertEqual(poll(&state, over: 0 ... 300), [TimedAction(second: 300, action: .ask(silentFor: 300))])

        let heard = step(state, at: 320, lastSpeech: 320)
        XCTAssertEqual(heard.action, .withdraw(.speech))
        XCTAssertNil(heard.state.open)

        state = heard.state
        XCTAssertEqual(
            poll(&state, over: 321 ... 620, lastSpeech: 320),
            [TimedAction(second: 620, action: .ask(silentFor: 300))],
        )
    }

    func testKeepRecordingWithdrawsAndTheNextQuestionComesAFullPeriodAfterTheAnswer() {
        var state = SilencePromptState()
        XCTAssertEqual(poll(&state, over: 0 ... 300), [TimedAction(second: 300, action: .ask(silentFor: 300))])

        let kept = step(state, at: 400, answer: .keepRecording)
        XCTAssertEqual(kept.action, .withdraw(.kept))
        XCTAssertNil(kept.state.open)

        state = kept.state
        // Counted from the answer, but the title states the whole silence,
        // which began when the recording did.
        XCTAssertEqual(poll(&state, over: 401 ... 700), [TimedAction(second: 700, action: .ask(silentFor: 700))])
    }

    func testAnUnansweredQuestionIsReplacedAfterAnotherFullPeriodStatingTheLongerSilence() {
        var state = SilencePromptState()
        XCTAssertEqual(
            poll(&state, over: 0 ... 600),
            [
                TimedAction(second: 300, action: .ask(silentFor: 300)),
                TimedAction(second: 600, action: .ask(silentFor: 600)),
            ],
        )
        XCTAssertEqual(state.open?.askedAt, at(600))
        XCTAssertEqual(state.open?.silentSince, t0)
    }

    func testAnAnswerWithNoOpenQuestionChangesNothing() {
        // The loop matches answers to the open question by id, so this is the
        // policy's half of "an answer to a withdrawn question changes nothing".
        let idle = SilencePromptState(open: nil, countFrom: at(100))
        for answer in [MeetingEndAnswer.stopNow, .keepRecording] {
            let result = step(idle, at: 200, answer: answer)
            XCTAssertEqual(result.action, .none, "answer=\(answer)")
            XCTAssertEqual(result.state, idle, "answer=\(answer)")
        }
    }

    // MARK: - Stop now (R2)

    private struct StopRow {
        let name: String
        let state: SilencePromptState
        let lastSpeech: TimeInterval?
        let stopAt: TimeInterval
        var held = false
        var after: TimeInterval? = 300
        let expected: SilencePromptAction
    }

    func testStopNowCutsTenSecondsAfterTheLastSpeechHeard() {
        // Asked at 400 about the silence since the speech at 100.
        let askedAfterSpeech = SilencePromptState(
            open: OpenSilenceQuestion(askedAt: at(400), silentSince: at(100)), countFrom: at(400),
        )
        // Asked at 300 about a recording in which nothing was ever heard.
        let askedWithoutSpeech = SilencePromptState(
            open: OpenSilenceQuestion(askedAt: at(300), silentSince: t0), countFrom: at(300),
        )
        let rows: [StopRow] = [
            StopRow(
                name: "silence since the last speech", state: askedAfterSpeech, lastSpeech: 100, stopAt: 450,
                expected: .stop(cutAt: at(110), silentFor: 350),
            ),
            StopRow(
                name: "no speech ever heard: nothing to cut towards", state: askedWithoutSpeech, lastSpeech: nil,
                stopAt: 310, expected: .stop(cutAt: nil, silentFor: 310),
            ),
            StopRow(
                name: "speech came back after the ask: cut from the newer speech", state: askedAfterSpeech,
                lastSpeech: 430, stopAt: 460, expected: .stop(cutAt: at(440), silentFor: 30),
            ),
            StopRow(
                name: "less than 10 s after the last speech", state: askedAfterSpeech, lastSpeech: 455, stopAt: 460,
                expected: .stop(cutAt: nil, silentFor: 5),
            ),
            StopRow(
                name: "exactly 10 s after: the cut would be the stop itself", state: askedAfterSpeech,
                lastSpeech: 450, stopAt: 460, expected: .stop(cutAt: nil, silentFor: 10),
            ),
            StopRow(
                name: "10.1 s after", state: askedAfterSpeech, lastSpeech: 449.9, stopAt: 460,
                expected: .stop(cutAt: at(449.9).addingTimeInterval(10), silentFor: at(460).timeIntervalSince(at(449.9))),
            ),
            // An explicit answer wins over a hold and over the switch.
            StopRow(
                name: "held", state: askedAfterSpeech, lastSpeech: 100, stopAt: 450, held: true,
                expected: .stop(cutAt: at(110), silentFor: 350),
            ),
            StopRow(
                name: "switched off", state: askedAfterSpeech, lastSpeech: 100, stopAt: 450, after: nil,
                expected: .stop(cutAt: at(110), silentFor: 350),
            ),
        ]
        for row in rows {
            let result = step(
                row.state, at: row.stopAt, lastSpeech: row.lastSpeech, held: row.held, answer: .stopNow, after: row.after,
            )
            XCTAssertEqual(result.action, row.expected, row.name)
            XCTAssertEqual(result.state, SilencePromptState(), row.name)
        }
    }

    // MARK: - Switched off, held (R6, R7)

    func testSwitchedOffWithdrawsTheQuestionAndNeverAsks() {
        var state = SilencePromptState()
        XCTAssertEqual(poll(&state, over: 0 ... 300), [TimedAction(second: 300, action: .ask(silentFor: 300))])
        XCTAssertEqual(poll(&state, over: 301 ... 3600, after: nil), [TimedAction(second: 301, action: .withdraw(.off))])
        XCTAssertNil(state.open)

        var neverOn = SilencePromptState()
        XCTAssertEqual(poll(&neverOn, over: 0 ... 3600, after: nil), [])
    }

    func testHeldWithdrawsNeverAsksAndTheCountRestartsAtTheLastHeldPoll() {
        var state = SilencePromptState()
        XCTAssertEqual(poll(&state, over: 0 ... 300), [TimedAction(second: 300, action: .ask(silentFor: 300))])
        XCTAssertEqual(poll(&state, over: 301 ... 500, held: true), [TimedAction(second: 301, action: .withdraw(.held))])
        XCTAssertNil(state.open)
        XCTAssertEqual(state.countFrom, at(500))
        XCTAssertEqual(poll(&state, over: 501 ... 800), [TimedAction(second: 800, action: .ask(silentFor: 800))])

        var heldThroughout = SilencePromptState()
        XCTAssertEqual(poll(&heldThroughout, over: 0 ... 3600, held: true), [])
    }
}
