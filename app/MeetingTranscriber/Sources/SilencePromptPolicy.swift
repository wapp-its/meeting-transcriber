import Foundation

/// What the channel-health poll knows about speech in the recording in
/// progress: the silence clock the long-silence question reads.
///
/// Speech is a poll tick at or above `ChannelHealthMonitor.speechThresholdDBFS`
/// on a channel the recording opened. Not `SilentRecordingMonitor`'s episode:
/// that one opens only while both channels sit at or below -60 dBFS, so a room
/// whose noise sits between -60 and -50 dBFS would never count as silent.
struct SpeechActivity: Equatable {
    /// The first channel-health tick of this recording.
    let observedSince: Date
    /// The latest tick that heard speech; nil while none has.
    let lastSpeechAt: Date?

    /// Where the current silence began: the last speech, or the start of the
    /// observation when nothing has been heard yet.
    var silentSince: Date {
        lastSpeechAt ?? observedSince
    }
}

/// The silence question currently in Notification Center.
struct OpenSilenceQuestion: Equatable {
    let askedAt: Date
    /// The silence it asks about. A newer value in the activity means speech
    /// was heard since the question went up.
    let silentSince: Date
}

/// What `SilencePromptPolicy.step` carries from one poll to the next.
struct SilencePromptState: Equatable {
    var open: OpenSilenceQuestion?
    /// The moment from which silence counts towards the next question: the
    /// last ask, a "Keep recording", or the last poll of a hold. Nil until one
    /// of those happened, so the whole silence counts.
    var countFrom: Date?
}

/// Why an open silence question is taken back. The raw value is what the
/// diagnostic log line names. `replaced` and `ended` are the watch loop's own
/// reasons (a fresh question supersedes it, the recording ended); the policy
/// never returns them.
enum SilencePromptWithdrawReason: String {
    case speech
    case kept
    case held
    case off
    case replaced
    case ended
}

/// What one poll of the long-silence question does.
enum SilencePromptAction: Equatable {
    case none // swiftlint:disable:this discouraged_none_name
    /// Post the question. With one already open this is its replacement,
    /// which the loop withdraws before posting.
    case ask(silentFor: TimeInterval)
    case withdraw(SilencePromptWithdrawReason)
    /// End the recording. `cutAt` is where the saved audio ends on the
    /// loop's clock; nil keeps everything that was recorded.
    case stop(cutAt: Date?, silentFor: TimeInterval)
}

/// Pure decision logic for "Nothing heard for 5 minutes. Stop the
/// recording?", separated so every transition can be asserted without driving
/// a poll loop. Mirrors `WatchLoopEndPolicy`.
enum SilencePromptPolicy {
    /// How much of the silence after the last speech a stop keeps: absorbs
    /// the cut anchor being read after capture starts, the poll granularity,
    /// and a soft last word below the speech threshold.
    static let cutMargin: TimeInterval = 10

    static let questionBody = "Stop the recording? Without an answer, it keeps recording."

    /// "Nothing heard for 5 minutes": whole minutes rounded down, never fewer
    /// than one.
    static func questionTitle(silentFor: TimeInterval) -> String {
        let minutes = max(1, Int((silentFor / 60).rounded(.down)))
        return "Nothing heard for \(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    /// Decide what this poll does. The first rule that applies decides.
    /// The six inputs stay separate arguments, over the parameter-count
    /// limit, so a call site names each of them.
    ///
    /// - Parameters:
    ///   - after: How long a silence has to last before the question is
    ///     asked; nil while the question is switched off.
    ///   - now: The current time on the loop's clock.
    ///   - activity: The silence clock; nil before the poll observed the
    ///     recording.
    ///   - held: Another question is open (or the recording is paused), so
    ///     this one must not be.
    ///   - answer: The answer to the open question, if one arrived since the
    ///     last poll.
    ///   - state: Where the previous poll left off.
    static func step( // swiftlint:disable:this function_parameter_count
        after: TimeInterval?,
        now: Date,
        activity: SpeechActivity?,
        held: Bool,
        answer: MeetingEndAnswer?,
        state: SilencePromptState,
    ) -> (action: SilencePromptAction, state: SilencePromptState) {
        // Only an answer to an open question counts: one to a withdrawn
        // question changes nothing.
        if let open = state.open, let answer {
            return answered(answer, open: open, now: now, activity: activity)
        }
        let withdrawn = SilencePromptState(open: nil, countFrom: state.countFrom)
        guard let after else {
            return (state.open == nil ? .none : .withdraw(.off), withdrawn)
        }
        if held {
            // Every held poll moves the count, so it restarts when the hold ends.
            return (state.open == nil ? .none : .withdraw(.held), SilencePromptState(open: nil, countFrom: now))
        }
        guard let activity else { return (.none, state) }
        let silentSince = activity.silentSince
        if let open = state.open, silentSince != open.silentSince {
            return (.withdraw(.speech), withdrawn)
        }
        let countedFrom = max(silentSince, state.countFrom ?? .distantPast)
        guard now.timeIntervalSince(countedFrom) >= after else { return (.none, state) }
        return (
            .ask(silentFor: now.timeIntervalSince(silentSince)),
            SilencePromptState(open: OpenSilenceQuestion(askedAt: now, silentSince: silentSince), countFrom: now),
        )
    }

    /// An explicit answer wins over a hold, the switch and returning speech.
    /// The cut is taken from the current activity, so speech heard after the
    /// question went up is kept.
    private static func answered(
        _ answer: MeetingEndAnswer,
        open: OpenSilenceQuestion,
        now: Date,
        activity: SpeechActivity?,
    ) -> (action: SilencePromptAction, state: SilencePromptState) {
        switch answer {
        case .keepRecording:
            return (.withdraw(.kept), SilencePromptState(open: nil, countFrom: now))

        case .stopNow:
            let silentSince = activity?.silentSince ?? open.silentSince
            let cutAt = cutPoint(lastSpeechAt: activity?.lastSpeechAt, now: now)
            return (.stop(cutAt: cutAt, silentFor: now.timeIntervalSince(silentSince)), SilencePromptState())
        }
    }

    /// Ten seconds after the last speech, and only when that is earlier than
    /// the stop: a cut at or past it would make the cut report audio the
    /// files do not hold, and the record-only sidecar claim a stop time after
    /// the real end. Nil, too, when nothing was ever heard: there is nothing
    /// to trim towards.
    private static func cutPoint(lastSpeechAt: Date?, now: Date) -> Date? {
        guard let cutAt = lastSpeechAt?.addingTimeInterval(cutMargin), cutAt < now else { return nil }
        return cutAt
    }
}
