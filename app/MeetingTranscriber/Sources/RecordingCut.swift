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
/// original; only once every copy exists are they swapped in, by renames inside
/// the track's own directory, and a failed swap renames the tracks already
/// swapped back. So a failure leaves every original exactly as it was, and no
/// track ends up cut while another is not or cut at a different point.
enum RecordingCut {
    enum CutError: LocalizedError {
        /// The cut point lies at or before the recording's start. Cutting
        /// there would discard the whole recording, which no end may do.
        case nothingToKeep(TimeInterval)

        var errorDescription: String? {
            switch self {
            case let .nothingToKeep(seconds): "Cut point \(seconds) s is not after the recording's start"
            }
        }
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
    /// - Parameter move: the rename primitive, injectable so a test can fail
    ///   the swap half way and watch it being undone.
    static func apply(
        to recording: RecordingResult,
        keepingFirst seconds: TimeInterval,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
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
        try swapIn(staged, move: move)
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

    /// Swap every copy in, keeping each original aside until all are in. A
    /// failed rename puts the tracks already swapped back, newest first.
    private static func swapIn(
        _ staged: [(original: URL, staged: URL)],
        move: (URL, URL) throws -> Void,
    ) throws {
        var swapped: [(original: URL, staged: URL, backup: URL)] = []
        do {
            for entry in staged {
                let backup = sibling(of: entry.original, suffix: "uncut")
                try? FileManager.default.removeItem(at: backup)
                try move(entry.original, backup)
                do {
                    try move(entry.staged, entry.original)
                } catch {
                    try? move(backup, entry.original)
                    throw error
                }
                swapped.append((entry.original, entry.staged, backup))
            }
        } catch {
            for entry in swapped.reversed() {
                try? move(entry.original, entry.staged)
                try? move(entry.backup, entry.original)
            }
            for entry in staged {
                try? FileManager.default.removeItem(at: entry.staged)
            }
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
