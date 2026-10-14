import Foundation

/// Result returned by `AudioCaptureSession.stop()`.
public struct AudioCaptureResult: Sendable {
    /// URL of the raw app audio file (interleaved float32 PCM), nil when the
    /// session opened no process tap at all (a microphone-only recording).
    /// Distinct from a tap that ran and wrote nothing, which still yields a URL
    /// pointing at an empty file.
    public let appAudioFileURL: URL?
    /// URL of the mic audio WAV file (nil if mic was not recorded).
    public let micAudioFileURL: URL?
    /// Actual sample rate of the aggregate device (may differ from requested).
    public let actualSampleRate: Int
    /// Actual channel count of the app audio (1=mono, 2=stereo).
    public let actualChannels: Int
    /// Time delta between app and mic first frames (seconds, positive = mic
    /// started later), on the session's pause-free recording clock, so a pause
    /// between the two first frames does not enter it.
    public let micDelay: TimeInterval
    /// Where each pause of the session begins on the saved tracks' timeline,
    /// in seconds, in order, one entry per pause (one still open at the stop
    /// included). The origin is the earliest first frame of the tracks that
    /// delivered one, which is the transcript timeline's origin once the
    /// recorder has normalised the mic delay. Empty without a pause.
    public let pauseOffsets: [TimeInterval]

    /// A `public` struct's synthesized memberwise init is only `internal`, so
    /// other modules can't construct one — declare it `public` to complete the
    /// type's public API. (Lets the app's test target build fixtures directly.)
    public init(
        appAudioFileURL: URL?,
        micAudioFileURL: URL?,
        actualSampleRate: Int,
        actualChannels: Int,
        micDelay: TimeInterval,
        pauseOffsets: [TimeInterval] = [],
    ) {
        self.appAudioFileURL = appAudioFileURL
        self.micAudioFileURL = micAudioFileURL
        self.actualSampleRate = actualSampleRate
        self.actualChannels = actualChannels
        self.micDelay = micDelay
        self.pauseOffsets = pauseOffsets
    }
}

extension AudioCaptureResult {
    /// First-frame + output-format readings from the app-audio track at stop().
    struct AppReadings {
        let firstFrameTicks: UInt64
        let sampleRate: Int
        let channels: Int
    }

    /// Mic-track reading at stop(): whether a mic was actually recorded (mic
    /// start can fail, leaving app-audio only) plus its first-frame ticks.
    struct MicReadings {
        let recorded: Bool
        let firstFrameTicks: UInt64
    }

    /// Builds the `AudioCaptureSession.stop()` result from the two tracks' raw
    /// readings, split out of the hardware glue so the delay / rate / channel
    /// arithmetic is unit-testable. Ticks are `mach_absolute_time` values (0 when
    /// that track never delivered a frame). `micDelay` is the mic-minus-app
    /// first-frame delta in seconds — positive when the mic started later — and is
    /// only non-zero when a mic was recorded AND both tracks produced a frame.
    /// Both first frames are read on the `pauses` recording clock, which stands
    /// still during a pause, so a first callback inside a pause sits where the
    /// first frame written after the resume does. Sample rate / channels fall
    /// back to `configured` when the app track reported 0 (never wrote output).
    static func make(
        appOutputURL: URL?,
        micOutputURL: URL?,
        configured: (sampleRate: Int, channels: Int),
        app: AppReadings,
        mic: MicReadings,
        pauses: CapturePauseTimeline = CapturePauseTimeline(),
    ) -> AudioCaptureResult {
        func recordingSeconds(ofTicks ticks: UInt64) -> Double? {
            ticks > 0 ? pauses.recordingSeconds(atHostSeconds: machTicksToSeconds(ticks)) : nil
        }
        let appStart = recordingSeconds(ofTicks: app.firstFrameTicks)
        let micStart = mic.recorded ? recordingSeconds(ofTicks: mic.firstFrameTicks) : nil
        var micDelay: TimeInterval = 0
        if let appStart, let micStart {
            micDelay = micStart - appStart
        }
        let origin = [appStart, micStart].compactMap(\.self).min()
        let pauseOffsets = pauses.pauses.map { pause in
            origin.map { max(0, pauses.recordingSeconds(atHostSeconds: pause.start) - $0) } ?? 0
        }
        return AudioCaptureResult(
            appAudioFileURL: appOutputURL,
            micAudioFileURL: mic.recorded ? micOutputURL : nil,
            actualSampleRate: app.sampleRate > 0 ? app.sampleRate : configured.sampleRate,
            actualChannels: app.channels > 0 ? app.channels : configured.channels,
            micDelay: micDelay,
            pauseOffsets: pauseOffsets,
        )
    }
}
