import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "DualSourceRecorder")

/// The pause of one recording: the track files `start()` opened, and while the
/// recording is paused, the task keeping them looking alive.
struct RecorderPauseState {
    /// The raw app temp and the microphone WAV, whichever the recording opened.
    var tracks: [URL] = []
    /// Runs exactly while the recording is paused.
    var trackToucher: Task<Void, Never>?
    /// The pauses this recording has begun; see `RecordingProvider.pausesBegun`.
    var pausesBegun = 0
}

/// Pausing the recording in progress. The capture session does the cutting;
/// the recorder forwards to it and keeps a paused recording from looking
/// crashed.
///
/// Crash recovery, the temp cleanup and the WAV header repair all read a
/// recording whose track files have not been written for 30 seconds as one
/// whose writer died, and a paused recording writes nothing. So while paused,
/// the recorder sets each track's modification date to now every
/// `pausedTrackTouchInterval`: without that, a pause longer than the window
/// would have its recording re-mixed under it and its raw app temp deleted.
extension DualSourceRecorder {
    var isPaused: Bool {
        pauseState.trackToucher != nil
    }

    var pausesBegun: Int {
        pauseState.pausesBegun
    }

    func pause() {
        guard isRecording, !isPaused, let captureSession else { return }
        captureSession.pause()
        pauseState.pausesBegun += 1
        pauseState.trackToucher = touchTracksWhilePaused()
    }

    func resume() {
        guard isRecording, isPaused, let captureSession else { return }
        captureSession.resume()
        endPause()
    }

    /// Stop keeping the tracks fresh. Also how `stop()` ends a pause still open.
    func endPause() {
        pauseState.trackToucher?.cancel()
        pauseState.trackToucher = nil
    }

    /// Ends with the recorder as well as on cancellation: a recorder dropped
    /// without a stop must not keep a dead recording looking alive.
    private func touchTracksWhilePaused() -> Task<Void, Never> {
        let tracks = pauseState.tracks
        let interval = pausedTrackTouchInterval
        return Task { @MainActor [weak self] in
            var warned = false
            while true {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, self != nil else { return }
                let now = Date()
                for track in tracks where FileManager.default.fileExists(atPath: track.path) {
                    do {
                        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: track.path)
                    } catch {
                        // Once per pause: a track that stays stale is read as
                        // crashed after 30 s, and nothing else would say why.
                        if !warned {
                            warned = true
                            logger.warning("Could not refresh a paused track's modification date")
                        }
                    }
                }
            }
        }
    }
}
