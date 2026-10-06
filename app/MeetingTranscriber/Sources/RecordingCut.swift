import AVFoundation
import Foundation

/// Cuts a finished recording back to a point on its timeline, every saved track
/// at the same point.
///
/// Used when a detected meeting ends through the "meeting seems to have ended"
/// question: the recording ran on while the question was open, and those
/// minutes are the room after the meeting, not the meeting. The cut puts the
/// end back where the automatic stop used to put it.
///
/// All or nothing. Every track is first copied up to its cut point beside the
/// original; only once every copy exists are they swapped in, and a failed swap
/// puts the tracks already swapped back. Each swap and each restore is one
/// atomic `rename`, which replaces its target, with the original kept under a
/// second name until every track is in, so a track's path always holds a whole
/// file, the cut copy or the original. A failure leaves every original as it
/// was, and no track ends up cut while another is not or cut at a different
/// point; in the one case where an original cannot be put back on its path, the
/// error says where it is, so the recording is still processed uncut.
enum RecordingCut {
    enum CutError: LocalizedError {
        /// The cut point lies at or before the recording's start. Cutting
        /// there would discard the whole recording, which no end may do.
        case nothingToKeep(TimeInterval)
        /// The swap failed and some originals could not be renamed back onto
        /// their paths. They are intact under the second name in `uncut`, keyed
        /// by their path; `redirect(_:to:)` points a recording at them.
        case rollbackIncomplete(uncut: [URL: URL])

        var errorDescription: String? {
            switch self {
            case let .nothingToKeep(seconds): "Cut point \(seconds) s is not after the recording's start"
            case let .rollbackIncomplete(uncut): "\(uncut.count) original track(s) could not be put back on their paths"
            }
        }
    }

    /// Where on the recording's own timeline `cutAt` falls, in seconds from
    /// its first frame.
    ///
    /// The timeline's origin is not known exactly, so it is estimated twice,
    /// and each estimate is wrong where the other is right. From the start: the
    /// moment capture was running, which can lie after the first frame (the
    /// microphone opens before the app tap, whose first start is unbounded), so
    /// on its own it can cut into the meeting. From the end: the stop minus the
    /// mix's length, exact while the tracks kept pace with the clock (gaps are
    /// filled with silence), but early when a track stopped delivering and left
    /// the mix short, which would cut into the meeting too. The later point
    /// wins: it never cuts meeting audio, and the two agree on an ordinary
    /// recording.
    static func keptSeconds(cutAt: Date, startedAt: Date, stoppedAt: Date, mixDuration: TimeInterval?) -> TimeInterval {
        let fromStart = cutAt.timeIntervalSince(startedAt)
        guard let mixDuration else { return fromStart }
        return max(fromStart, mixDuration - stoppedAt.timeIntervalSince(cutAt))
    }

    /// The length of the audio at `url`, nil when it cannot be read.
    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// `recording` with every track `uncut` names pointing at its original.
    static func redirect(_ recording: RecordingResult, to uncut: [URL: URL]) -> RecordingResult {
        RecordingResult(
            mixPath: uncut[recording.mixPath] ?? recording.mixPath,
            appPath: recording.appPath.map { uncut[$0] ?? $0 },
            micPath: recording.micPath.map { uncut[$0] ?? $0 },
            micDelay: recording.micDelay,
            recordingStartDate: recording.recordingStartDate,
        )
    }

    /// One saved track and where its first frame sits on the recording's
    /// timeline, whose origin is the mix's first frame.
    struct Track: Equatable {
        let url: URL
        let offset: TimeInterval
    }

    /// The recording's tracks with their offsets. The mix is the timeline. The
    /// two source tracks sit where `AudioMixer.mix` placed them, which is only
    /// ever shifted when both exist: a positive delay puts the microphone that
    /// much later, a negative one the app track. A single-track recording's mix
    /// is that track unshifted.
    static func tracks(of recording: RecordingResult) -> [Track] {
        var tracks = [Track(url: recording.mixPath, offset: 0)]
        let delay = (recording.appPath != nil && recording.micPath != nil)
            ? min(max(recording.micDelay, -AudioMixer.maxMicDelay), AudioMixer.maxMicDelay)
            : 0
        if let app = recording.appPath {
            tracks.append(Track(url: app, offset: max(0, -delay)))
        }
        if let mic = recording.micPath {
            tracks.append(Track(url: mic, offset: max(0, delay)))
        }
        return tracks
    }

    /// Keep the first `seconds` of the recording's timeline in every track.
    /// A track that already ends before the cut point is left as it is.
    ///
    /// - Parameter rename: the atomic rename, injectable so a test can fail the
    ///   swap or its undoing and watch what is left.
    static func apply(
        to recording: RecordingResult,
        keepingFirst seconds: TimeInterval,
        rename: (URL, URL) throws -> Void = Self.rename,
    ) throws {
        guard seconds > 0 else { throw CutError.nothingToKeep(seconds) }

        // Which tracks run past the cut point, and how many frames each keeps.
        // Opening every track first means an unreadable one fails the cut
        // before anything is written.
        var cuts: [(url: URL, frames: AVAudioFramePosition)] = []
        for track in tracks(of: recording) {
            let file = try AVAudioFile(forReading: track.url)
            let keep = max(0, ((seconds - track.offset) * file.fileFormat.sampleRate).rounded(.down))
            let frames = AVAudioFramePosition(keep)
            if file.length > frames {
                cuts.append((track.url, frames))
            }
        }
        guard !cuts.isEmpty else { return }

        let staged = try stageCopies(of: cuts)
        try swapIn(staged, rename: rename)
    }

    /// POSIX `rename`: atomically replaces `destination`, unlike
    /// `FileManager.moveItem`, which refuses an existing one.
    static func rename(_ source: URL, _ destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Write each track's kept frames beside it. On any failure every copy
    /// written so far is removed and the originals were never touched.
    private static func stageCopies(
        of cuts: [(url: URL, frames: AVAudioFramePosition)],
    ) throws -> [(original: URL, staged: URL)] {
        var staged: [(original: URL, staged: URL)] = []
        do {
            for cut in cuts {
                let copy = sibling(of: cut.url, suffix: "cutting.wav")
                try? FileManager.default.removeItem(at: copy)
                staged.append((cut.url, copy))
                try copyFrames(from: cut.url, to: copy, frames: cut.frames)
            }
        } catch {
            for entry in staged {
                try? FileManager.default.removeItem(at: entry.staged)
            }
            throw error
        }
        return staged
    }

    /// Swap every copy in, keeping each original under a second name (a hard
    /// link, so nothing is copied) until all are in. A failed swap puts the
    /// tracks already swapped back, newest first; one that cannot be put back
    /// keeps its original under that second name, and its path, which still
    /// holds the cut copy, is cleared so nothing mistakes it for the recording.
    private static func swapIn(
        _ staged: [(original: URL, staged: URL)],
        rename: (URL, URL) throws -> Void,
    ) throws {
        var swapped: [(original: URL, backup: URL)] = []
        do {
            for entry in staged {
                let backup = sibling(of: entry.original, suffix: "uncut")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.linkItem(at: entry.original, to: backup)
                do {
                    try rename(entry.staged, entry.original)
                } catch {
                    // Nothing was renamed, so the path still holds the original.
                    try? FileManager.default.removeItem(at: backup)
                    throw error
                }
                swapped.append((entry.original, backup))
            }
        } catch {
            var uncut: [URL: URL] = [:]
            for entry in swapped.reversed() {
                do {
                    try rename(entry.backup, entry.original)
                } catch {
                    uncut[entry.original] = entry.backup
                    try? FileManager.default.removeItem(at: entry.original)
                }
            }
            for entry in staged {
                try? FileManager.default.removeItem(at: entry.staged)
            }
            if !uncut.isEmpty { throw CutError.rollbackIncomplete(uncut: uncut) }
            throw error
        }
        for entry in swapped {
            try? FileManager.default.removeItem(at: entry.backup)
        }
    }

    /// A hidden file next to `url`. Hidden and with its own ending, so no scan
    /// of the recordings folder mistakes it for a track. The copy keeps a
    /// `.wav` ending because `AVAudioFile` picks the container from it.
    private static func sibling(of url: URL, suffix: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(suffix)")
    }

    /// Copy the first `frames` frames of `source` into a new file in the same
    /// format, with the original's permissions, which for a recording are
    /// owner-only because the audio may carry a confidential meeting.
    private static func copyFrames(from source: URL, to destination: URL, frames: AVAudioFramePosition) throws {
        try writePrefix(of: AVAudioFile(forReading: source), to: destination, frames: frames)
        if let permissions = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
        }
    }

    /// A block at a time, so an hours-long track is never held whole. Its own
    /// function so the writer is released, and its header finalised, on
    /// return, before the copy can be swapped in.
    private static func writePrefix(of input: AVAudioFile, to destination: URL, frames: AVAudioFramePosition) throws {
        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: input.fileFormat.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved,
        )
        let blockFrames: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw AudioMixerError.bufferCreationFailed
        }
        var remaining = frames
        while remaining > 0 {
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, AVAudioFramePosition(blockFrames))))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }
}
