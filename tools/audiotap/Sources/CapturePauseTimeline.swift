import Darwin
import os

/// The pauses of one capture session on the host clock (mach ticks in
/// seconds, the clock `AudioTimeStamp.mHostTime` and `AVAudioTime.hostTime`
/// use), and the two questions every captured buffer asks of them: which of
/// my frames lie outside every pause, and where is an instant on the
/// pause-free recording clock.
///
/// Both tracks ask the same timeline, so they remove the same host-time span
/// whatever their buffer sizes, and each feeds its `TimelineAnchor` recording
/// clock positions, so a pause is written as no gap at all. The recording
/// clock is host time minus every paused second before the instant; it stands
/// still inside a pause, and without a pause it is host time exactly.
struct CapturePauseTimeline: Sendable, Equatable {
    /// One pause in host seconds; `end` is nil while it is still open.
    struct Pause: Sendable, Equatable {
        let start: Double
        let end: Double?
    }

    /// In order and disjoint, at most the last one open. An empty pause (a
    /// resume at the pause instant) stays in the list: it cuts nothing, but
    /// the caller counted it as a pause.
    private(set) var pauses: [Pause] = []

    /// How far below an exact frame position a boundary may fall and still
    /// count as on it. Host seconds near a long uptime carry about 1e-10 s of
    /// rounding, which at 48 kHz is a few millionths of a frame; without this,
    /// a pause starting exactly on a frame could leave that frame unpaused.
    private static let boundaryToleranceFrames = 1e-3

    var hasOpenPause: Bool {
        pauses.last.map { $0.end == nil } ?? false
    }

    /// Start a pause at `seconds`. Does nothing while a pause is open. An
    /// instant before the previous pause's end starts at that end instead.
    mutating func pause(atHostSeconds seconds: Double) {
        guard !hasOpenPause else { return }
        let start = max(seconds, pauses.last?.end ?? seconds)
        pauses.append(Pause(start: start, end: nil))
    }

    /// End the open pause at `seconds`, or at its start when `seconds` is
    /// earlier. Does nothing while no pause is open.
    mutating func resume(atHostSeconds seconds: Double) {
        guard let open = pauses.last, open.end == nil else { return }
        pauses[pauses.count - 1] = Pause(start: open.start, end: max(seconds, open.start))
    }

    /// True on `[start, end)` of a closed pause and from the start of an open one.
    func isPaused(atHostSeconds seconds: Double) -> Bool {
        pauses.contains { seconds >= $0.start && seconds < ($0.end ?? .infinity) }
    }

    /// `seconds` minus all paused time before it.
    func recordingSeconds(atHostSeconds seconds: Double) -> Double {
        var paused = 0.0
        for pause in pauses where pause.start < seconds {
            paused += min(seconds, pause.end ?? seconds) - pause.start
        }
        return seconds - paused
    }

    /// The frame ranges of a buffer, frame `i` captured at
    /// `bufferStartSeconds + i / sampleRate`, that lie outside every pause, in
    /// order: the whole buffer when no pause touches it, none when it lies
    /// inside one, two when a pause sits inside it.
    func keptFrameRanges(bufferStartSeconds: Double, frameCount: Int, sampleRate: Double) -> [Range<Int>] {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return isPaused(atHostSeconds: bufferStartSeconds) ? [] : [0 ..< frameCount]
        }
        func firstFrame(atOrAfter seconds: Double) -> Int {
            let position = (seconds - bufferStartSeconds) * sampleRate - Self.boundaryToleranceFrames
            return Int(min(max(position, 0), Double(frameCount)).rounded(.up))
        }

        var kept: [Range<Int>] = []
        var next = 0
        var cut = false
        for pause in pauses {
            let from = firstFrame(atOrAfter: pause.start)
            let upTo = pause.end.map(firstFrame(atOrAfter:)) ?? frameCount
            guard from < upTo else { continue }
            cut = true
            if from > next { kept.append(next ..< from) }
            next = max(next, upTo)
        }
        guard cut else { return [0 ..< frameCount] }
        if next < frameCount { kept.append(next ..< frameCount) }
        return kept
    }
}

/// The session's one pause timeline, shared by its app-audio and microphone
/// handlers. Written only by pause and resume, read once per buffer on the
/// capture threads, under the same short unfair lock pattern the capture code
/// already uses there (`runningLock`, `actualSampleRateLock`).
///
/// Nothing is allocated while the lock is held: a write builds the new
/// timeline from a copy outside it and only swaps it in under it, retrying if
/// another write got there first.
final class CapturePauseGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: CapturePauseTimeline())

    var timeline: CapturePauseTimeline {
        state.withLock { $0 }
    }

    /// Whether a pause is open.
    var isPaused: Bool {
        state.withLock { $0.hasOpenPause }
    }

    func pause() {
        pause(atHostSeconds: machTicksToSeconds(mach_absolute_time()))
    }

    func resume() {
        resume(atHostSeconds: machTicksToSeconds(mach_absolute_time()))
    }

    /// `pause()` at a chosen instant, so a test can place a pause against the
    /// host times it gives its buffers.
    func pause(atHostSeconds seconds: Double) {
        update { $0.pause(atHostSeconds: seconds) }
    }

    /// `resume()` at a chosen instant; see `pause(atHostSeconds:)`.
    func resume(atHostSeconds seconds: Double) {
        update { $0.resume(atHostSeconds: seconds) }
    }

    private func update(_ change: (inout CapturePauseTimeline) -> Void) {
        while true {
            let current = timeline
            var changed = current
            change(&changed)
            let replacement = changed
            // `current` still holds the replaced storage, so the swap frees nothing under the lock either.
            let swapped = state.withLock { stored in
                guard stored == current else { return false }
                stored = replacement
                return true
            }
            if swapped { return }
        }
    }
}
