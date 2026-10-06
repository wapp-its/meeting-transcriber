import Foundation

/// Where the wait for a detected meeting's end stands between two polls of
/// `WatchLoop.waitForMeetingEnd`.
///
/// A lost signal no longer ends the recording on its own: once it has been
/// missing for the end grace period the person is asked, and the recording
/// runs on while the question is open. A signal can drop while the call goes
/// on (hold, a device switch, a hand-off to the phone), and a silent stop then
/// split the meeting in two or lost the rest of it.
enum MeetingEndPhase: Equatable {
    /// The call's signal is there (`signalLostAt == nil`), or has been missing
    /// since `signalLostAt` for less than the end grace period.
    case listening(signalLostAt: Date?)
    /// The grace period ran out and the person was asked. The recording ends
    /// at the deadline unless they answer or the signal comes back.
    case askingToEnd(PendingMeetingEnd)
    /// The person chose "Keep recording": nothing more is asked while the
    /// signal stays away, and the recording runs until it is stopped by hand
    /// or reaches the duration cap.
    case kept(signalLostAt: Date)
}

/// An end the person was asked about and has not settled yet.
struct PendingMeetingEnd: Equatable {
    /// The first poll that found the signal missing.
    let signalLostAt: Date
    /// Where the automatic stop used to end the recording: the signal loss
    /// plus the end grace period. A stop out of the question cuts the saved
    /// audio back to here, so a real meeting end keeps exactly the audio it
    /// always did and the room after the meeting is not kept.
    let cutAt: Date
    /// When the recording ends if nobody answers.
    let deadline: Date
}

/// The two answers to "the meeting seems to have ended". A dismissal is not
/// one of them: it leaves the countdown running, exactly like a notification
/// that was never seen.
enum MeetingEndAnswer: Equatable {
    case keepRecording
    case stopNow
}

/// An answer and when it arrived. The time matters because a poll can come up
/// to a poll interval after the tap, and only an answer given before the
/// deadline may change what the deadline does.
struct ReceivedMeetingEndAnswer: Equatable {
    let answer: MeetingEndAnswer
    let receivedAt: Date
}

/// Why a recording ended without the person stopping it by hand. The raw value
/// is what the diagnostic log line names.
enum AutoStopReason: String {
    case countdownExpired = "countdown_expired"
    case stopNow = "stop_now"
    case maxDuration = "max_duration"
    case appExited = "app_exited"

    /// The diagnostic line for an automatic stop. Carries no meeting title,
    /// participant or transcript, because the line is unconditional and lands
    /// in the log file the user exports: the trigger, the reason, how long the
    /// signal had been missing (whole seconds) and, for an app that quit, its
    /// process id.
    func logLine(
        trigger: RecordingSidecar.Trigger,
        signalAbsentFor: TimeInterval? = nil,
        pid: pid_t? = nil,
    ) -> String {
        var line = "recording_auto_stop trigger=\(trigger.rawValue) reason=\(rawValue)"
        if let signalAbsentFor {
            line += " signal_absent_s=\(Int(signalAbsentFor.rounded()))"
        }
        if let pid {
            line += " pid=\(pid)"
        }
        return line
    }
}

/// How a detected meeting's recording stops.
struct MeetingEndStop: Equatable {
    let reason: AutoStopReason
    /// Where the saved audio ends, on the loop's clock. Nil keeps everything
    /// that was recorded.
    let cutAt: Date?
    /// How long the signal had been missing when the recording stopped. Nil
    /// while the signal was there.
    let signalAbsentFor: TimeInterval?
}

/// Decision returned by `WatchLoopEndPolicy.step` on each poll of
/// `WatchLoop.waitForMeetingEnd`.
enum WatchLoopEndDecision: Equatable {
    /// Keep polling from `phase`.
    case continuePolling(MeetingEndPhase)
    /// The grace period ran out: ask the person, and keep polling from
    /// `.askingToEnd(pending)`.
    case askToEnd(PendingMeetingEnd)
    /// The open question is settled without a stop (the signal came back, or
    /// the person chose "Keep recording"): take it back, and keep polling from
    /// `then`.
    case withdrawQuestion(then: MeetingEndPhase)
    /// End the recording.
    case stop(MeetingEndStop)
}

/// What one poll of `WatchLoop.waitForMeetingEnd` saw.
struct MeetingEndPoll: Equatable {
    /// The current time on the loop's clock.
    let now: Date
    /// Whether the meeting's signal is there right now.
    let meetingActive: Bool
    /// The answer to the open question, if one arrived since the last poll.
    /// The caller passes only answers to the question that is open now, so an
    /// answer to a withdrawn one never reaches the policy.
    var answer: ReceivedMeetingEndAnswer?
}

/// Static configuration for `WatchLoopEndPolicy.step`, re-used across every
/// poll.
struct WatchLoopEndConfig: Equatable {
    let maxDuration: TimeInterval
    let endGracePeriod: TimeInterval
    /// How long the question stays open before the recording ends anyway.
    let countdown: TimeInterval
}

/// Pure decision logic for `WatchLoop.waitForMeetingEnd`, separated so every
/// transition can be asserted without driving the async poll loop.
enum WatchLoopEndPolicy {
    /// Decide what the meeting-end poller does next.
    ///
    /// - Parameters:
    ///   - config: Duration cap, end grace period and countdown.
    ///   - startTime: When the poller first started waiting for the end.
    ///   - phase: Where the previous poll left off.
    ///   - poll: What this poll saw.
    static func step(
        config: WatchLoopEndConfig,
        startTime: Date,
        phase: MeetingEndPhase,
        poll: MeetingEndPoll,
    ) -> WatchLoopEndDecision {
        let now = poll.now
        if now.timeIntervalSince(startTime) > config.maxDuration {
            return .stop(capStop(phase: phase, poll: poll))
        }
        switch phase {
        case let .listening(signalLostAt):
            return listen(config: config, now: now, signalLostAt: signalLostAt, meetingActive: poll.meetingActive)

        case let .askingToEnd(pending):
            return ask(pending: pending, poll: poll)

        case .kept:
            // Back to listening once the signal returns, so the next loss is
            // asked about again; until then the person's answer stands.
            return .continuePolling(poll.meetingActive ? .listening(signalLostAt: nil) : phase)
        }
    }

    /// Where the saved audio ends when watching stops during the wait, before
    /// another poll. Only an open question cuts, as an unanswered one would:
    /// the recording ran past the point where it used to stop, and those extra
    /// minutes are not the meeting's. An answer that arrived in time but that
    /// no poll has seen yet has already settled the question, so a Keep
    /// recording keeps the whole recording; a late one counts for nothing.
    static func cutWhenWatchingStops(phase: MeetingEndPhase, answer: ReceivedMeetingEndAnswer?) -> Date? {
        guard case let .askingToEnd(pending) = phase else { return nil }
        if let answer, answer.answer == .keepRecording, answer.receivedAt < pending.deadline {
            return nil
        }
        return pending.cutAt
    }

    /// The duration cap stays a hard stop in every phase. It cuts only when it
    /// lands on a question that is still open: one this poll ends anyway keeps
    /// its own reason, and one the signal or a Keep has just settled ends uncut,
    /// because the audio after the cut point is the meeting again.
    private static func capStop(phase: MeetingEndPhase, poll: MeetingEndPoll) -> MeetingEndStop {
        let signalLostAt: Date? = switch phase {
        case let .listening(lost): lost
        case let .askingToEnd(pending): pending.signalLostAt
        case let .kept(lost): lost
        }
        var cutAt: Date?
        if case let .askingToEnd(pending) = phase {
            switch ask(pending: pending, poll: poll) {
            case let .stop(stop): return stop
            case .continuePolling: cutAt = pending.cutAt
            case .askToEnd, .withdrawQuestion: cutAt = nil
            }
        }
        return MeetingEndStop(
            reason: .maxDuration,
            cutAt: cutAt,
            signalAbsentFor: poll.meetingActive ? nil : signalLostAt.map { poll.now.timeIntervalSince($0) },
        )
    }

    private static func listen(
        config: WatchLoopEndConfig,
        now: Date,
        signalLostAt: Date?,
        meetingActive: Bool,
    ) -> WatchLoopEndDecision {
        if meetingActive {
            return .continuePolling(.listening(signalLostAt: nil))
        }
        guard let lost = signalLostAt else {
            return .continuePolling(.listening(signalLostAt: now))
        }
        guard now.timeIntervalSince(lost) >= config.endGracePeriod else {
            return .continuePolling(.listening(signalLostAt: lost))
        }
        return .askToEnd(PendingMeetingEnd(
            signalLostAt: lost,
            cutAt: lost.addingTimeInterval(config.endGracePeriod),
            deadline: now.addingTimeInterval(config.countdown),
        ))
    }

    /// Only what happened before the deadline counts: an answer that arrived in
    /// time, a signal this poll saw in time. Once the two minutes are up the
    /// recording ends, unless the person answered within them. A signal seen in
    /// time outranks "Stop now": the tap may have come while the call was
    /// coming back, and the cut would then discard the resumed meeting.
    private static func ask(pending: PendingMeetingEnd, poll: MeetingEndPoll) -> WatchLoopEndDecision {
        let inTime = poll.now < pending.deadline
        if inTime, poll.meetingActive {
            return .withdrawQuestion(then: .listening(signalLostAt: nil))
        }
        let absentFor: TimeInterval? = poll.meetingActive ? nil : poll.now.timeIntervalSince(pending.signalLostAt)
        let answer = poll.answer.flatMap { $0.receivedAt < pending.deadline ? $0.answer : nil }
        switch answer {
        case .stopNow:
            return .stop(MeetingEndStop(reason: .stopNow, cutAt: pending.cutAt, signalAbsentFor: absentFor))

        case .keepRecording:
            return .withdrawQuestion(
                then: poll.meetingActive ? .listening(signalLostAt: nil) : .kept(signalLostAt: pending.signalLostAt),
            )

        case nil:
            break
        }
        guard inTime else {
            return .stop(MeetingEndStop(reason: .countdownExpired, cutAt: pending.cutAt, signalAbsentFor: absentFor))
        }
        return .continuePolling(.askingToEnd(pending))
    }
}
