@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Capture-time resampling for `AppAudioCapture`. Folds each CATap buffer to
/// 16 kHz mono before the file write (issue #379 follow-up) so a mid-recording
/// output-device rate change can't time-warp the track the way a single
/// post-hoc resample did. Extracted to a sibling file so `AppAudioCapture.swift`
/// stays under the 600-line lint cap — same pattern as
/// `AppAudioCapture+LiveSink.swift`.
@available(macOS 14.2, *)
public extension AppAudioCapture {
    /// Format of the data actually written to the output fd: 16 kHz mono when
    /// the resampler is active (the normal case), else the raw device input
    /// (`actualSampleRate`/`actualChannels`) as a fallback. Read by
    /// `AudioCaptureSession` to describe the produced file.
    var outputSampleRate: Int {
        resampler != nil ? Int(speechSampleRate) : actualSampleRate
    }

    var outputChannels: Int {
        resampler != nil ? 1 : actualChannels
    }

    /// The buffer's hardware presentation time in mach ticks, for wall-clock
    /// gap-filling. Falls back to the callback clock if the IOProc didn't mark
    /// the host time valid.
    internal static func hostTicks(from time: UnsafePointer<AudioTimeStamp>) -> UInt64 {
        let stamp = time.pointee
        return stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
    }

    /// Resample + downmix one interleaved CATap buffer to 16 kHz mono and write
    /// it to `fd`, also forwarding the resampled buffer to the live sink. The
    /// converter is rebuilt on a mid-recording rate change. The resampler buffers
    /// internally, so a buffer that yields no output yet (converter priming) is
    /// simply not written — its samples emerge on a later call, no data lost.
    /// Falls back to the raw native-rate write *and* raw-format live-sink forward
    /// only if no resampler was built (not expected for a 16 kHz target).
    /// `hostTicks` is the buffer's hardware presentation time, used to cut the
    /// frames captured inside a pause and to fill device-restart gaps with
    /// silence so the track stays aligned to the recording clock.
    /// Runs on `writeQueue`.
    internal func writeCapturedBuffer(
        fd: Int32, data: UnsafeMutableRawPointer, byteCount: Int, hostTicks: UInt64,
    ) {
        guard resampler != nil else {
            writeRawUnpausedFrames(fd: fd, data: data, byteCount: byteCount, hostTicks: hostTicks)
            return
        }
        let floatCount = byteCount / MemoryLayout<Float>.size
        let channels = max(actualChannels, 1)
        // A rate change is followed from the buffer that confirms it, not from
        // the next one, which is why this hands back the rate to use here.
        // Every buffer, paused or not, so the rate tracking sees the device
        // continuously.
        let inputRate = adoptDeliveredRate(frames: floatCount / channels, hostTicks: hostTicks)
        let interleaved = Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self), count: floatCount,
        ))
        resampleForwardAndWrite(
            fd: fd, interleaved: interleaved,
            inputRate: inputRate, inputChannels: channels,
            hostTicks: hostTicks,
        )
    }

    /// Core of `writeCapturedBuffer`, parameterised on the input rate/channels so
    /// it's drivable without a live CATap. Cuts the frames captured inside a
    /// pause, then for each run of frames left resamples to 16 kHz mono, fills
    /// any device-restart gap with silence (file only — the live path doesn't
    /// need gap-fill), writes the resampled samples to `fd`, and forwards those
    /// same samples to the live sink. A buffer no pause touches takes that path
    /// once, whole. Paused frames never enter the resampler, so its state
    /// carries across the cut and its latency stays what it was. The pieces
    /// come from `pauseCutter`, which also settles the fraction of a frame
    /// each cut leaves, so repeated pauses do not move the track. Caller
    /// guarantees `resampler != nil`.
    internal func resampleForwardAndWrite(
        fd: Int32, interleaved: [Float], inputRate: Int, inputChannels: Int, hostTicks: UInt64,
    ) {
        let timeline = pauseGate.timeline
        let startSeconds = machTicksToSeconds(hostTicks)
        let channels = max(inputChannels, 1)
        let frameCount = interleaved.count / channels
        let pieces = pauseCutter.pieces(
            of: timeline, bufferStartSeconds: startSeconds, frameCount: frameCount, sampleRate: Double(inputRate),
        )
        guard !pieces.isEmpty else {
            // Nothing to write, but a first buffer still starts the track's timeline.
            timelineAnchor.anchorIfUnset(hostSeconds: timeline.recordingSeconds(atHostSeconds: startSeconds))
            return
        }
        for piece in pieces {
            writeKeptFrames(
                fd: fd,
                interleaved: piece.isWhole(of: frameCount)
                    ? interleaved : Self.samples(of: piece, in: interleaved, channels: channels),
                inputRate: inputRate, inputChannels: inputChannels,
                recordingSeconds: piece.recordingSeconds,
            )
        }
    }

    /// A piece's interleaved samples: its first frame `leadingRepeats` extra
    /// times, then its frames.
    private static func samples(
        of piece: CapturePauseCutter.Piece, in interleaved: [Float], channels: Int,
    ) -> [Float] {
        let first = piece.frames.lowerBound * channels
        var samples: [Float] = []
        samples.reserveCapacity((piece.leadingRepeats + piece.frames.count) * channels)
        for _ in 0 ..< piece.leadingRepeats {
            samples += interleaved[first ..< first + channels]
        }
        samples += interleaved[first ..< piece.frames.upperBound * channels]
        return samples
    }

    /// One run of unpaused frames through resample → gap fill → write → live
    /// sink. `recordingSeconds` is the run's first frame on the session's
    /// pause-free recording clock.
    private func writeKeptFrames(
        fd: Int32, interleaved: [Float], inputRate: Int, inputChannels: Int, recordingSeconds: Double,
    ) {
        guard let resampler else { return }
        let mono16k = resampler.process(
            interleaved, inputRate: inputRate, inputChannels: inputChannels,
        )
        guard !mono16k.isEmpty else { return }
        fillTimelineGap(fd: fd, recordingSeconds: recordingSeconds, outputFrames: mono16k.count)
        Self.writeFloats(mono16k, to: fd)
        forwardToLiveSink(monoSamples: mono16k)
    }

    /// The fallback without a resampler: the raw device-format bytes, minus the
    /// frames captured inside a pause, to the file and the live sink.
    private func writeRawUnpausedFrames(fd: Int32, data: UnsafeMutableRawPointer, byteCount: Int, hostTicks: UInt64) {
        let bytesPerFrame = MemoryLayout<Float>.size * max(actualChannels, 1)
        let frameCount = byteCount / bytesPerFrame
        let kept = pauseGate.timeline.keptFrameRanges(
            bufferStartSeconds: machTicksToSeconds(hostTicks), frameCount: frameCount,
            sampleRate: Double(actualSampleRate > 0 ? actualSampleRate : sampleRate),
        )
        guard kept.first != 0 ..< frameCount else {
            writeAllToFileHandle(fd, data, count: byteCount)
            forwardToLiveSink(data: data, byteCount: byteCount)
            return
        }
        for range in kept {
            let piece = data + range.lowerBound * bytesPerFrame
            writeAllToFileHandle(fd, piece, count: range.count * bytesPerFrame)
            forwardToLiveSink(data: piece, byteCount: range.count * bytesPerFrame)
        }
    }

    /// Write silence for a device-restart gap before this buffer's audio, so the
    /// app track stays aligned to the recording clock (issue #379 follow-up).
    /// Mirrors `MicCaptureHandler.fillTimelineGap`; the `TimelineAnchor`
    /// self-anchors on the first buffer and is never reset, so only a real gap
    /// produces silence. Fed the pause-free recording clock, a pause is no gap:
    /// a restart gap that overlaps one is filled only for its unpaused part.
    private func fillTimelineGap(fd: Int32, recordingSeconds: Double, outputFrames: Int) {
        let silence = timelineAnchor.silenceFramesBefore(
            hostSeconds: recordingSeconds, frameCount: outputFrames,
        )
        guard silence > 0 else { return }
        Self.writeFloats([Float](repeating: 0, count: silence), to: fd)
    }

    /// Write a float buffer's raw bytes to `fd` in one POSIX write loop.
    private static func writeFloats(_ samples: [Float], to fd: Int32) {
        samples.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                writeAllToFileHandle(fd, base, count: raw.count)
            }
        }
    }
}
