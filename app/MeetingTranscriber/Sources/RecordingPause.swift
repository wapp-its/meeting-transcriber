import Foundation

/// One stretch of a recording during which nothing was captured.
///
/// Two clocks, because the two readers differ. The wall-clock times are what
/// the transcript marker shows the reader. `offsetSeconds` is where the pause
/// sits on the saved tracks' timeline, which leaves paused time out, and so it
/// is where the marker goes. Neither can be derived from the other once an
/// earlier pause or a sleeping Mac has moved the two clocks apart.
struct RecordingPause: Codable, Equatable, Sendable {
    var startedAt: Date
    var endedAt: Date
    var offsetSeconds: TimeInterval

    /// `[Pause 14:05–14:20]`: start and end in 24-hour minutes, joined by an
    /// en dash. The POSIX locale is what keeps a 12-hour user locale from
    /// turning `HH` into `2 PM`.
    func markerLine(in timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter.filenameStamp("HH:mm")
        formatter.timeZone = timeZone
        return "[Pause \(formatter.string(from: startedAt))\u{2013}\(formatter.string(from: endedAt))]"
    }
}

/// The pause and resume times of the running recording, in the order they
/// happened, turned into `RecordingPause` values at the stop.
///
/// Wall-clock only. Where each pause sits on the saved tracks is measured by
/// the capture, which sees the audio; this pairs those positions with its
/// times and only computes positions itself when there are none to pair.
struct RecordingPauseLog {
    /// When the open pause began, or nil while the recording runs.
    private(set) var pausedSince: Date?
    private var closed: [(startedAt: Date, endedAt: Date)] = []

    /// Opens a pause. Returns false and changes nothing when one is already
    /// open.
    mutating func pause(at date: Date) -> Bool {
        guard pausedSince == nil else { return false }
        pausedSince = date
        return true
    }

    /// Closes the open pause and returns how long it lasted, or returns nil
    /// and changes nothing when no pause is open.
    mutating func resume(at date: Date) -> TimeInterval? {
        guard let start = pausedSince else { return nil }
        closed.append((startedAt: start, endedAt: date))
        pausedSince = nil
        return max(0, date.timeIntervalSince(start))
    }

    /// Every pause of the recording, a pause still open ending at `stop`.
    ///
    /// `capturedOffsets` are the positions the capture measured, one per pause
    /// in order, and are used exactly when their count matches. Otherwise each
    /// position is estimated from the wall clock: time since `origin` minus the
    /// pauses before it, clamped at zero. The two cannot be told apart in the
    /// result, so a caller that logs the fallback compares the counts itself.
    func pauses(
        endingAt stop: Date, recordingStartedAt origin: Date, capturedOffsets: [TimeInterval],
    ) -> [RecordingPause] {
        var spans = closed
        if let open = pausedSince {
            spans.append((startedAt: open, endedAt: stop))
        }
        if capturedOffsets.count == spans.count {
            return zip(spans, capturedOffsets).map { span, offset in
                RecordingPause(startedAt: span.startedAt, endedAt: span.endedAt, offsetSeconds: offset)
            }
        }
        var pausedBefore: TimeInterval = 0
        return spans.map { span in
            let offset = max(0, span.startedAt.timeIntervalSince(origin) - pausedBefore)
            pausedBefore += max(0, span.endedAt.timeIntervalSince(span.startedAt))
            return RecordingPause(startedAt: span.startedAt, endedAt: span.endedAt, offsetSeconds: offset)
        }
    }
}

/// Conversions between the wall clock and the pause-free saved timeline. One
/// place for them, because every estimate of a position from wall-clock times
/// has to leave out the paused time inside the interval it spans, and a cut
/// that forgets to lands in the wrong place.
extension [RecordingPause] {
    /// The paused time inside `from...to`. A pause reaching past either end
    /// counts only its part inside.
    func pausedDuration(from start: Date, to end: Date) -> TimeInterval {
        reduce(0) { total, pause in
            let overlapStart = Swift.max(pause.startedAt, start)
            let overlapEnd = Swift.min(pause.endedAt, end)
            return total + Swift.max(0, overlapEnd.timeIntervalSince(overlapStart))
        }
    }

    /// Where the wall-clock `date` lies on the saved timeline: the time since
    /// `origin` without the paused time before it, clamped at zero. It stands
    /// still inside a pause, since nothing was recorded there.
    func timelineOffset(of date: Date, recordingStartedAt origin: Date) -> TimeInterval {
        Swift.max(0, date.timeIntervalSince(origin) - pausedDuration(from: origin, to: date))
    }

    /// The pauses that still belong to a recording cut back to `cut`: one
    /// starting at or after the cut is dropped, one spanning it ends there.
    /// Positions stay, since a pause's start did not move.
    func clipped(at cut: Date) -> [RecordingPause] {
        compactMap { pause in
            guard pause.startedAt < cut else { return nil }
            var kept = pause
            kept.endedAt = Swift.min(pause.endedAt, cut)
            return kept
        }
    }
}
