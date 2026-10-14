@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// The microphone tap block's write path: cut the frames captured inside a
/// pause, then convert, gap fill, write and forward what is left. Extracted to
/// a sibling file so `MicCaptureHandler.swift` stays under the 600-line lint
/// cap, the same pattern as `+Timeline`.
extension MicCaptureHandler {
    /// Write the frames of `buffer` captured outside every pause. `when` is the
    /// buffer's hardware presentation time (jitter-free), falling back to the
    /// callback clock if the host time is invalid. A buffer no pause touches
    /// goes through whole; one a pause boundary crosses is split, and each
    /// piece is converted on its own. Paused frames never reach the converter,
    /// so its state carries across the cut and its latency stays what it was.
    ///
    /// `converter` and `resampleRatio` belong to the session whose tap block
    /// calls this (issue #589), which is why they are passed in rather than
    /// read from the handler.
    func writeUnpausedFrames(
        of buffer: AVAudioPCMBuffer, at when: AVAudioTime, converter: AVAudioConverter?, resampleRatio: Double,
    ) {
        let timeline = pauseGate.timeline
        let hostTicks = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
        let startSeconds = machTicksToSeconds(hostTicks)
        let frameCount = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let kept = timeline.keptFrameRanges(bufferStartSeconds: startSeconds, frameCount: frameCount, sampleRate: rate)
        guard !kept.isEmpty else {
            // Nothing to write, but a first buffer still starts the track's timeline.
            timelineAnchor.anchorIfUnset(hostSeconds: timeline.recordingSeconds(atHostSeconds: startSeconds))
            return
        }
        guard kept.first != 0 ..< frameCount else {
            write(
                buffer, recordingSeconds: timeline.recordingSeconds(atHostSeconds: startSeconds),
                converter: converter, resampleRatio: resampleRatio,
            )
            return
        }
        for range in kept {
            guard let piece = Self.copy(frames: range, of: buffer) else { continue }
            write(
                piece, recordingSeconds: timeline.recordingSeconds(atHostSeconds: startSeconds + Double(range.lowerBound) / rate),
                converter: converter, resampleRatio: resampleRatio,
            )
        }
    }

    /// Convert → gap fill → write → live sink for one run of unpaused frames.
    /// `recordingSeconds` is its first frame on the session's pause-free
    /// recording clock.
    private func write(
        _ buffer: AVAudioPCMBuffer, recordingSeconds: Double, converter: AVAudioConverter?, resampleRatio: Double,
    ) {
        do {
            if let converter {
                let outputFrames = resampleOutputCapacity(
                    inputFrames: buffer.frameLength, ratio: resampleRatio,
                )
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: converter.outputFormat,
                    frameCapacity: outputFrames,
                ) else { return }
                var error: NSError?
                let feed = FeedOnce(buffer: buffer)
                converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    feed.next(outStatus)
                }
                if let error {
                    logger.warning("Mic resample error: \(error.localizedDescription, privacy: .public)")
                } else {
                    fillTimelineGap(atRecordingSeconds: recordingSeconds, outputFrames: Int(outputBuffer.frameLength))
                    try outputFile?.write(from: outputBuffer)
                    forwardToLiveSink(buffer: outputBuffer)
                }
            } else {
                fillTimelineGap(atRecordingSeconds: recordingSeconds, outputFrames: Int(buffer.frameLength))
                try outputFile?.write(from: buffer)
                forwardToLiveSink(buffer: buffer)
            }
        } catch {
            logger.warning("Mic write error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A new buffer in `buffer`'s format holding the frames in `range`. Copied
    /// buffer by buffer at the format's bytes per frame, so it holds for
    /// interleaved and deinterleaved, float and integer formats alike.
    private static func copy(frames range: Range<Int>, of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let piece = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(range.count))
        else { return nil }
        piece.frameLength = AVAudioFrameCount(range.count)
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(piece.mutableAudioBufferList)
        for (from, into) in zip(source, destination) {
            guard let fromData = from.mData, let intoData = into.mData else { continue }
            intoData.copyMemory(from: fromData + range.lowerBound * bytesPerFrame, byteCount: range.count * bytesPerFrame)
        }
        return piece
    }
}
