/// One track's cut of the paused frames out of its buffers.
///
/// `CapturePauseTimeline` says which frames lie inside a pause. A cut removes
/// those whole frames, while the recording clock leaves out the exact paused
/// time, so every pause boundary leaves up to one input frame of difference
/// between what the track wrote and what the clock allows for it. Left alone,
/// these differences add up over repeated pauses: when the boundaries fall at
/// the same phase between two frames each time, every pause shifts the track
/// the same way, by almost a frame. `TimelineAnchor` cannot correct a track
/// that wrote too much (it only inserts silence), and the live sink gets no
/// gap fill at all.
///
/// So the cutter carries the difference from cut to cut and settles it in
/// whole frames at the next piece it hands out. A track that wrote a frame
/// too much leaves out the first frame of that piece; a track that wrote a
/// frame too little writes that frame twice. Both happen only at the seam a
/// cut left, never to a paused frame, and they keep the track within half an
/// input frame of the recording clock however many pauses it has. The file and
/// the live sink get the same pieces. A track that never pauses has nothing to
/// carry and gets every buffer whole.
///
/// Not thread-safe: one per track, driven from the context that writes that
/// track, like its `TimelineAnchor`.
struct CapturePauseCutter {
    /// A run of one buffer's frames to write.
    struct Piece: Equatable {
        /// The buffer's frames to write, in order.
        let frames: Range<Int>
        /// How many copies of the first of `frames` to write before them, to
        /// make up for cuts that removed more frames than their paused time.
        let leadingRepeats: Int
        /// The first written frame's position on the pause-free recording clock.
        let recordingSeconds: Double

        /// Whether this is the whole buffer of `frameCount` frames, as it came.
        func isWhole(of frameCount: Int) -> Bool {
            frames == 0 ..< frameCount && leadingRepeats == 0
        }
    }

    /// The frames written minus the frames the recording clock allows for
    /// them, in seconds: positive when the cuts removed less than the paused
    /// time. Changes only where a buffer overlaps a pause.
    private var surplusSeconds = 0.0

    /// The pieces to write of a buffer whose frame `i` was captured at
    /// `bufferStartSeconds + i / sampleRate`, in order: the whole buffer when
    /// no pause touches it and nothing is left to settle, none when every
    /// frame of it lies inside a pause.
    mutating func pieces(
        of timeline: CapturePauseTimeline, bufferStartSeconds start: Double, frameCount: Int, sampleRate: Double,
    ) -> [Piece] {
        let kept = timeline.keptFrameRanges(bufferStartSeconds: start, frameCount: frameCount, sampleRate: sampleRate)
        guard !timeline.pauses.isEmpty, sampleRate.isFinite, sampleRate > 0 else {
            let recordingSeconds = timeline.recordingSeconds(atHostSeconds: start)
            return kept.map { Piece(frames: $0, leadingRepeats: 0, recordingSeconds: recordingSeconds) }
        }

        func seconds(atFrame frame: Int) -> Double {
            start + Double(frame) / sampleRate
        }
        var surplus = surplusSeconds
        // Add the paused time in frames `from ..< to` and take off the frames cut there.
        func account(from: Int, to: Int, cut: Int) {
            surplus += timeline.pausedSeconds(from: seconds(atFrame: from), to: seconds(atFrame: to))
            surplus -= Double(cut) / sampleRate
        }

        var pieces: [Piece] = []
        var next = 0
        for range in kept {
            account(from: next, to: range.lowerBound, cut: range.lowerBound - next)
            let settle = Int((surplus * sampleRate).rounded())
            let dropped = min(max(settle, 0), range.count)
            let repeats = max(-settle, 0)
            let shift = Double(dropped - repeats) / sampleRate
            surplus -= shift
            if dropped < range.count {
                pieces.append(Piece(
                    frames: range.lowerBound + dropped ..< range.upperBound,
                    leadingRepeats: repeats,
                    recordingSeconds: timeline.recordingSeconds(atHostSeconds: seconds(atFrame: range.lowerBound)) + shift,
                ))
            }
            // A pause shorter than a frame cuts nothing here, but the clock still leaves it out.
            account(from: range.lowerBound, to: range.upperBound, cut: 0)
            next = range.upperBound
        }
        account(from: next, to: frameCount, cut: frameCount - next)
        surplusSeconds = surplus
        return pieces
    }
}
