import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// How a detected meeting's recording ends, split out of `WatchLoop.swift` to
/// keep that file under the line cap.
///
/// A missing signal used to stop the recording silently after the end grace
/// period. The signal can drop while the call goes on (hold, a device switch, a
/// hand-off to the phone), and then the meeting was split in two or its rest
/// lost. Now the person is asked, and the recording runs on while they decide:
/// "Keep recording" keeps it, "Stop now" or no answer within the countdown ends
/// it, and a returning signal takes the question back. An end that comes out of
/// the question is cut back to where the silent stop used to end it, so the
/// minutes of room audio recorded while asking are neither kept nor
/// transcribed: people still in the room after a meeting did not agree to
/// being recorded.
extension WatchLoop {
    /// How long the question stays open: fixed, with no setting.
    static let meetingEndQuestionCountdown: TimeInterval = 120

    /// Poll until the meeting ends, and return where its saved audio has to
    /// end, nil to keep everything recorded.
    ///
    /// Cancellation (Stop Watching) is an end like any other rather than an
    /// error, so the caller finalizes the recording instead of losing it; an
    /// earlier version let the `CancellationError` escape and discarded the
    /// whole recording. Stopped while the question is open, the recording ends
    /// as an unanswered question would, cut back. Every way out of here takes
    /// the open question back.
    @discardableResult
    func waitForMeetingEnd(_ meeting: DetectedMeeting) async throws -> Date? {
        let startTime = nowProvider()
        let config = WatchLoopEndConfig(
            maxDuration: maxDuration,
            endGracePeriod: endGracePeriod,
            countdown: meetingEndCountdown,
        )
        var phase = MeetingEndPhase.listening(signalLostAt: nil)
        defer { withdrawMeetingEndQuestion() }

        do {
            while !Task.isCancelled {
                let poll = MeetingEndPoll(
                    now: nowProvider(),
                    meetingActive: detector.isMeetingActive(meeting),
                    answer: takeMeetingEndAnswer(),
                )
                let decision = WatchLoopEndPolicy.step(config: config, startTime: startTime, phase: phase, poll: poll)
                switch decision {
                case let .continuePolling(next):
                    phase = next

                case let .askToEnd(pending):
                    phase = .askingToEnd(pending)
                    askToEnd(meeting)

                case let .withdrawQuestion(next):
                    withdrawMeetingEndQuestion()
                    phase = next

                case let .stop(stop):
                    diagnostics.notice(stop.reason.logLine(trigger: .auto, signalAbsentFor: stop.signalAbsentFor))
                    return stop.cutAt
                }
                try await sleepProvider(pollInterval)
            }
        } catch is CancellationError {}
        logger.info("Watch cancelled mid-recording — finalizing in-flight recording")
        return WatchLoopEndPolicy.cutWhenWatchingStops(phase: phase, answer: takeMeetingEndAnswer())
    }

    /// Cut the stopped recording back to `cutAt`, every track at the same
    /// point, and return it with `recordedUntil` saying where its audio now
    /// ends. `startedAt` and `stoppedAt` are when capture was running and when
    /// it was stopped, on the loop's clock, which is how `cutAt` is placed on
    /// the audio's own timeline (`RecordingCut.keptSeconds`). A failed cut
    /// returns the recording uncut, never lost: as recorded, or, when an
    /// original could not be put back on its path, pointing at it where it is.
    func cutBack(_ recording: RecordingResult, to cutAt: Date, startedAt: Date, stoppedAt: Date) -> RecordingResult {
        let seconds = RecordingCut.keptSeconds(
            cutAt: cutAt,
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            mixDuration: RecordingCut.duration(of: recording.mixPath),
        )
        do {
            try RecordingCut.apply(to: recording, keepingFirst: seconds)
        } catch let RecordingCut.CutError.rollbackIncomplete(uncut) {
            diagnostics.warning("recording_cut_failed rollback_incomplete tracks_moved=\(uncut.count)")
            return RecordingCut.redirect(recording, to: uncut)
        } catch {
            // Domain and code only: a file error's description names the path.
            let nsError = error as NSError
            diagnostics.warning("recording_cut_failed domain=\(nsError.domain) code=\(nsError.code)")
            return recording
        }
        diagnostics.notice("recording_cut kept_s=\(Int(seconds.rounded()))")
        var cut = recording
        cut.recordedUntil = recording.recordingStartDate.addingTimeInterval(seconds)
        return cut
    }

    /// Ask the person, under a fresh id, so an answer to an earlier question
    /// can be told apart from one to this.
    private func askToEnd(_ meeting: DetectedMeeting) {
        let id = UUID().uuidString
        meetingEndQuestionID = id
        meetingEndAnswer = nil
        let app = meeting.pattern.appName
        let appLabel = app.isEmpty ? meeting.ownerName : app
        // In whole minutes: the app's countdown is a fixed two, and only tests
        // inject a shorter one.
        let minutes = Int((meetingEndCountdown / 60).rounded())
        notifier.askBeforeEndingRecording(
            id: id,
            title: "Meeting seems to have ended",
            body: "No sign of the \(appLabel) call. The recording ends in \(minutes) minutes.",
        ) { [weak self] answer in
            self?.receiveMeetingEndAnswer(answer, forQuestion: id)
        }
    }

    /// Park an answer for the next poll, if it belongs to the question that is
    /// open now. An answer to a withdrawn question, or one arriving after the
    /// recording ended, changes nothing.
    private func receiveMeetingEndAnswer(_ answer: MeetingEndAnswer, forQuestion id: String) {
        guard id == meetingEndQuestionID else {
            logger.info("Answer to a meeting-end question that is no longer open — ignored")
            return
        }
        meetingEndAnswer = ReceivedMeetingEndAnswer(answer: answer, receivedAt: nowProvider())
    }

    private func takeMeetingEndAnswer() -> ReceivedMeetingEndAnswer? {
        defer { meetingEndAnswer = nil }
        return meetingEndAnswer
    }

    private func withdrawMeetingEndQuestion() {
        guard let id = meetingEndQuestionID else { return }
        notifier.withdrawMeetingEndQuestion(id: id)
        meetingEndQuestionID = nil
        meetingEndAnswer = nil
    }
}
