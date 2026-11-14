@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// The microphone tap block's write path: cut the frames captured inside a
/// pause, then convert, zero while muted, gap fill, write and forward what is
/// left. Extracted to
/// a sibling file so `MicCaptureHandler.swift` stays under the 600-line lint
/// cap, the same pattern as `+Timeline`.
extension MicCaptureHandler {
    /// Write the frames of `buffer` captured outside every pause. `when` is the
    /// buffer's hardware presentation time (jitter-free), falling back to the
    /// callback clock if the host time is invalid. A buffer no pause touches
    /// goes through whole; one a pause boundary crosses is split, and each
    /// piece is converted on its own. Paused frames never reach the converter,
    /// so its state carries across the cut and its latency stays what it was.
    /// The pieces come from `pauseCutter`, which also settles the fraction of
    /// a frame each cut leaves, so repeated pauses do not move the track.
    ///
    /// `converter` and `resampleRatio` belong to the session whose tap block
    /// calls this (issue #589), which is why they are passed in rather than
    /// read from the handler.
    func writeUnpausedFrames(
        of buffer: AVAudioPCMBuffer, at when: AVAudioTime, converter: AVAudioConverter?, resampleRatio: Double,
    ) {
        // Read once per tap buffer, so every piece of one buffer is muted or
        // none is, and applied before anything is written, so neither the file
        // nor the live captions ever receive muted speech.
        let isMuted = muteTimeline.withLock { $0.isMuted }
        let timeline = pauseGate.timeline
        let hostTicks = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
        let startSeconds = machTicksToSeconds(hostTicks)
        let frameCount = Int(buffer.frameLength)
        let pieces = pauseCutter.pieces(
            of: timeline, bufferStartSeconds: startSeconds, frameCount: frameCount, sampleRate: buffer.format.sampleRate,
        )
        guard !pieces.isEmpty else {
            // Nothing to write, but a first buffer still starts the track's timeline.
            timelineAnchor.anchorIfUnset(hostSeconds: timeline.recordingSeconds(atHostSeconds: startSeconds))
            return
        }
        // When the buffer arrived, on the same pause-free clock, for a
        // revival's bridge (`TimelineAnchor.bridgeNextGap`).
        let arrivedAt = timeline.recordingSeconds(atHostSeconds: machTicksToSeconds(mach_absolute_time()))
        // Each run of unpaused frames: convert, then mute, gap fill, write and
        // live sink (`writeCaptured`). `piece.recordingSeconds` is its first
        // frame on the session's pause-free recording clock.
        for piece in pieces {
            guard let part = piece.isWhole(of: frameCount) ? buffer : Self.copy(piece, of: buffer),
                  let output = converted(part, converter: converter, resampleRatio: resampleRatio)
            else { continue }
            do {
                try writeCaptured(output, recordingSeconds: piece.recordingSeconds, arrivedAt: arrivedAt, isMuted: isMuted)
            } catch {
                logger.warning("Mic write error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// `buffer` in the track's format: through `converter` when the session
    /// has one, as it came otherwise. Nil when the conversion fails, which is
    /// logged, and the piece is then not written.
    private func converted(
        _ buffer: AVAudioPCMBuffer, converter: AVAudioConverter?, resampleRatio: Double,
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let outputFrames = resampleOutputCapacity(inputFrames: buffer.frameLength, ratio: resampleRatio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outputFrames)
        else { return nil }
        var error: NSError?
        let feed = FeedOnce(buffer: buffer)
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            feed.next(outStatus)
        }
        if let error {
            logger.warning("Mic resample error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return outputBuffer
    }

    /// A new buffer in `buffer`'s format holding a piece: the first of its
    /// frames `leadingRepeats` extra times, then its frames. Copied buffer by
    /// buffer at the format's bytes per frame, so it holds for interleaved and
    /// deinterleaved, float and integer formats alike.
    private static func copy(_ piece: CapturePauseCutter.Piece, of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let length = piece.leadingRepeats + piece.frames.count
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(length))
        else { return nil }
        copy.frameLength = AVAudioFrameCount(length)
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, into) in zip(source, destination) {
            guard let fromData = from.mData, let intoData = into.mData else { continue }
            let first = fromData + piece.frames.lowerBound * bytesPerFrame
            for index in 0 ..< piece.leadingRepeats {
                (intoData + index * bytesPerFrame).copyMemory(from: first, byteCount: bytesPerFrame)
            }
            (intoData + piece.leadingRepeats * bytesPerFrame)
                .copyMemory(from: first, byteCount: piece.frames.count * bytesPerFrame)
        }
        return copy
    }
}
