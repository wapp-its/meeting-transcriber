import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// The long-silence question as one `WatchLoop` runs it: what it reads on
/// every poll and where it stands. One stored property on the loop, because
/// `WatchLoop.swift` sits at the line cap.
struct SilencePromptRuntime {
    /// The silence clock: what the channel-health poll heard in the recording
    /// in progress, nil before it observed one.
    let speechActivity: () -> SpeechActivity?
    /// How long a silence lasts before the question is asked, nil while it is
    /// switched off.
    let after: () -> TimeInterval?

    /// Where the policy left off at the last poll.
    var policy = SilencePromptState()
    /// The question in Notification Center, with the trigger of the recording
    /// it asks about for its log lines.
    var question: (id: String, trigger: RecordingSidecar.Trigger)?
    /// An answer to that question, parked for the next poll.
    var answer: MeetingEndAnswer?
    /// When the loop saw a manual recording's capture running: where its cut
    /// is measured from. Set at every manual start and read at the stop, so
    /// ending the question leaves it alone.
    var manualStartedAt: Date?
}

/// A "Stop now" to the silence question: where the saved audio ends (nil
/// keeps everything recorded) and how long nothing had been heard.
struct SilenceStop: Equatable {
    let cutAt: Date?
    let silentFor: TimeInterval
}

/// "Nothing heard for 5 minutes. Stop the recording?", split out of
/// `WatchLoop.swift` to keep that file under the line cap.
///
/// The decision is `SilencePromptPolicy`'s; this runs it once per poll of the
/// loop that owns the recording and carries out what it returns. The question
/// goes through the meeting-end question's notification calls, so it offers
/// the same "Keep recording" / "Stop now" and its answer arrives out of band
/// the same way: parked by question id and acted on at the next poll, never
/// from the notification's callback.
extension WatchLoop {
    /// Run the policy for this poll and act on it. Returns the stop when the
    /// person chose "Stop now"; the caller ends the recording and logs it.
    ///
    /// - Parameters:
    ///   - held: Another question is open, so this one must not be.
    ///   - trigger: Which kind of recording is asked about, for the log.
    func stepSilencePrompt(held: Bool, trigger: RecordingSidecar.Trigger) -> SilenceStop? {
        let answer = silencePrompt.answer
        silencePrompt.answer = nil
        let (action, state) = SilencePromptPolicy.step(
            after: silencePrompt.after(),
            now: nowProvider(),
            activity: silencePrompt.speechActivity(),
            held: held,
            answer: answer,
            state: silencePrompt.policy,
        )
        silencePrompt.policy = state
        switch action {
        case .none:
            return nil

        case let .ask(silentFor):
            withdrawSilenceQuestion(.replaced)
            askAboutSilence(silentFor: silentFor, trigger: trigger)
            return nil

        case let .withdraw(reason):
            withdrawSilenceQuestion(reason)
            return nil

        case let .stop(cutAt, silentFor):
            // Answered, so there is nothing left to take back.
            silencePrompt.question = nil
            return SilenceStop(cutAt: cutAt, silentFor: silentFor)
        }
    }

    /// Take an open question back and forget everything about it: on every
    /// way a recording ends, so a later answer to it changes nothing.
    func endSilencePrompt() {
        withdrawSilenceQuestion(.ended)
        silencePrompt.policy = SilencePromptState()
        silencePrompt.answer = nil
    }

    /// Stop a manual recording's capture, its silence question taken back
    /// first, and cut every track back to `cutAt` when the question's "Stop
    /// now" gave one. Every other stop passes nil and keeps all of it. The cut
    /// is placed from when the loop saw the capture running, as a detected
    /// meeting's is; a stored cut record exists only for the meeting-end
    /// question, so `cutBack` finds none to update here.
    func stopManualCapture(_ recorder: any RecordingProvider, cutAt: Date?) throws -> RecordingResult {
        let startedAt = silencePrompt.manualStartedAt
        endSilencePrompt()
        let stoppedAt = nowProvider()
        let recording = try recorder.stop()
        guard let cutAt, let startedAt else { return recording }
        return cutBack(recording, to: cutAt, startedAt: startedAt, stoppedAt: stoppedAt, recorder: recorder)
    }

    /// Post the question under a fresh id, so an answer to an earlier one can
    /// be told apart from an answer to this.
    private func askAboutSilence(silentFor: TimeInterval, trigger: RecordingSidecar.Trigger) {
        let id = UUID().uuidString
        silencePrompt.question = (id, trigger)
        diagnostics.notice("silence_question_posted trigger=\(trigger.rawValue) silent_s=\(Int(silentFor.rounded()))")
        notifier.askBeforeEndingRecording(
            id: id,
            title: SilencePromptPolicy.questionTitle(silentFor: silentFor),
            body: SilencePromptPolicy.questionBody,
        ) { [weak self] answer in
            self?.receiveSilenceAnswer(answer, forQuestion: id)
        }
    }

    /// Park an answer for the next poll, if it belongs to the question that is
    /// open now. An answer to a withdrawn or replaced question, or one arriving
    /// after the recording ended, changes nothing.
    private func receiveSilenceAnswer(_ answer: MeetingEndAnswer, forQuestion id: String) {
        guard id == silencePrompt.question?.id else {
            logger.info("Answer to a silence question that is no longer open — ignored")
            return
        }
        silencePrompt.answer = answer
    }

    private func withdrawSilenceQuestion(_ reason: SilencePromptWithdrawReason) {
        guard let question = silencePrompt.question else { return }
        notifier.withdrawMeetingEndQuestion(id: question.id)
        silencePrompt.question = nil
        diagnostics.notice("silence_question_withdrawn trigger=\(question.trigger.rawValue) reason=\(reason.rawValue)")
    }
}
