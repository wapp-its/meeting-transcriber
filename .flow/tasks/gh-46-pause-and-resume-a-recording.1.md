---
satisfies: [R2, R3]
---
# gh-46-pause-and-resume-a-recording.1 Drop paused audio in the capture library

## Description
Make the capture library able to pause: one pause timeline per `AudioCaptureSession`, shared by the app-audio and microphone handlers, that cuts out of every buffer exactly the frames captured inside a pause before they reach the resampler or converter, the track file or the live sink, and feeds each track's `TimelineAnchor` a pause-free clock so the audio before and after a pause is written back to back (spec: Architecture "Where a pause takes effect", "One pause clock for both tracks", "Alignment and positions"; Edge Cases "Frame accuracy", "Device change or capture restart during a pause", "Audio thread"; R2, R3). Library only; nothing in the app calls it yet. This is the early proof point: if two tracks with different buffer sizes cannot drop the same span and stay aligned, the approach is wrong.

**Size:** M
**Files:** `tools/audiotap/Sources/CapturePauseTimeline.swift` (new), `tools/audiotap/Sources/AudioCaptureSession.swift`, `tools/audiotap/Sources/AudioCaptureResult.swift`, `tools/audiotap/Sources/AppAudioCapture.swift`, `tools/audiotap/Sources/AppAudioCapture+Resampling.swift`, `tools/audiotap/Sources/MicCaptureHandler.swift`, `tools/audiotap/Sources/MicCaptureHandler+Timeline.swift`; new tests under `tools/audiotap/Tests/`
**Touches:** [tools/audiotap/Sources/**, tools/audiotap/Tests/**]

## Approach
- **Pure core first, tests first.** `CapturePauseTimeline` (value type, `Sendable`, `Equatable`) over host seconds: closed pauses plus an optional open one. `pause(atHostSeconds:)` / `resume(atHostSeconds:)` are idempotent (a second pause or a resume while running changes nothing; a resume earlier than its pause clamps to the pause start). `isPaused(atHostSeconds:)` is true on `[start, end)` of a closed pause and from the start of the open one. `recordingSeconds(atHostSeconds:)` is `t` minus all paused time before `t` (flat inside a pause; `t` itself with no pause). `keptFrameRanges(bufferStartSeconds:frameCount:sampleRate:) -> [Range<Int>]`: the frame ranges of a buffer whose frames (frame `i` at `start + i / rate`) lie outside every pause, in order; the whole buffer when nothing is paused, none when it lies inside a pause, two when a pause sits inside it. Write `CapturePauseTimelineTests` against this contract before the type.
- **Thread-safe wrapper.** A small final class (for example `CapturePauseGate`, `@unchecked Sendable`) holding the timeline in an `OSAllocatedUnfairLock`, the pattern of `runningLock` / `actualSampleRateLock` in `AppAudioCapture.swift:56-60, 108-112`. `pause()` / `resume()` stamp `machTicksToSeconds(mach_absolute_time())` (`Helpers.swift:17`); queries take the buffer's host seconds. Nothing allocated inside the lock.
- **Session API.** `AudioCaptureSession` owns one gate and gets `public func pause()`, `public func resume()`, `public var isPaused: Bool`. Hand the gate to both handlers through their internal inits: `MicCaptureHandler(outputURL:…sessionFactory:)` built in `startMicCapture` (`AudioCaptureSession.swift:202-215`) and `AppAudioCapture` built in `makeAppCapture` (`AudioCaptureSession.swift:258-273`, init at `AppAudioCapture.swift:196-227`). The public convenience inits keep their signatures and get a gate that is never paused.
- **App track.** In `AppAudioCapture+Resampling.swift`: keep `adoptDeliveredRate` (`:55`) for every buffer so rate tracking sees the device continuously. In `resampleForwardAndWrite` (`:71-82`), before `resampler.process`, ask for the kept ranges of the interleaved input (frames = count / channels, at `inputRate`, starting at the buffer's host seconds) and run the existing process → gap fill → write → live sink once per kept range, slicing the interleaved array; feed `fillTimelineGap` (`:88-94`) the recording-clock position of the range's first frame instead of raw host seconds. The raw fallback in `writeCapturedBuffer` (`:46-50`) applies the same ranges to the raw bytes. A buffer with nothing paused takes exactly today's path. Do not touch the level publishing in the IOProc (`AppAudioCapture.swift:467-469`): levels and buffer ages must keep reading the live device during a pause.
- **Microphone track.** In the tap block (`MicCaptureHandler.swift:308-349`) keep `firstFrameTime`, `noteBufferForStallWatchdog`, `accumulateDebugRMS`, `publishCurrentLevel`, `maybeReportDebugRMS` where they are; then take the kept ranges from the buffer's host seconds (as `fillTimelineGap(before:)` computes them, `MicCaptureHandler+Timeline.swift:19-27`), `buffer.frameLength` and `buffer.format.sampleRate`. Whole buffer → today's path; otherwise copy each kept range into a new `AVAudioPCMBuffer` of the tap format and run the existing convert → gap fill → write → live sink for it (the block already allocates an output buffer per callback). The gap fill takes the recording-clock position of the piece's first frame. `MicCaptureHandler.swift` is at 583 lines and `./scripts/lint.sh` runs SwiftLint `--strict` with `file_length` 600: put the helpers in `+Timeline.swift` or a new extension file.
- **micDelay.** `AudioCaptureResult.make` (`AudioCaptureResult.swift:60-78`) converts both first-frame tick values through the session's recording clock before subtracting, so a pause between the two first frames does not enter the delay. `firstFrameTime` / `appFirstFrameTime` keep their meaning (first callback, paused or not): the recording clock stands still during a pause, so a first callback inside a pause sits at the same position as the first frame written after the resume. Default the new parameter so existing callers and `AudioCaptureResultTests` keep working.
- **Pause positions.** `AudioCaptureResult` gains `public let pauseOffsets: [TimeInterval]` (public init parameter defaulted to `[]`, so the app's test target keeps building fixtures). `make` fills it with one entry per pause, in order: the pause start on the recording clock minus the origin, clamped at 0, where the origin is the earliest recording-clock first frame among the tracks that delivered one (both: the smaller; one: that one; none: every offset 0). That origin is the transcript timeline's origin: `MicDelayNormalisation` pads the app track when the microphone started first (`DualSourceRecorder+BuildRecording.swift:114-130`) and the dual-source merge shifts the microphone when it started later. An open pause at stop counts like a closed one.

## Investigation targets
**Required** (read before coding):
- `tools/audiotap/Sources/TimelineAnchor.swift:19-54` — the gap fill the recording clock feeds (it only inserts silence, never removes frames)
- `tools/audiotap/Sources/AppAudioCapture+Resampling.swift:43-94` — app write path and its test seam
- `tools/audiotap/Sources/MicCaptureHandler.swift:308-349` and `MicCaptureHandler+Timeline.swift:19-27` — mic write path
- `tools/audiotap/Sources/AudioCaptureSession.swift:137-165, 198-273, 343-373` — start, handler construction, stop
- `tools/audiotap/Sources/AudioCaptureResult.swift:52-78` — micDelay arithmetic

**Optional** (reference as needed):
- `tools/audiotap/Tests/MicEngineSessionSeamTests.swift:14-70, 195-215` and `MicCaptureHandlerStallWatchdogTests.swift:22-60, 188-198` — fake engine session driving the real tap block (pass `AVAudioTime(hostTime:)` with chosen ticks)
- `tools/audiotap/Tests/AppAudioCaptureLiveSinkTests.swift:160-260` — `resampleForwardAndWrite` with explicit `hostTicks:` and a sink recorder
- `tools/audiotap/Tests/AudioCaptureSessionStartOrderTests.swift:120-150` — session built with the `micSessionFactory` seam
- `tools/audiotap/Tests/TimelineAnchorTests.swift`, `AudioCaptureResultTests.swift`

## Key context
- Host time (mach ticks) does not advance during system sleep; the pause clock and both tracks skip sleep alike, which keeps them consistent.
- A handler restart (device change, stall watchdog) reuses the same handler instance and keeps the gate; the microphone's anchor resets only when a fresh output file is created (`MicCaptureHandler.swift:259-279`).
- Paused input never enters the resampler or converter; their state carries over the excised span, so their latency (and the alignment) does not change.
- Commit messages are written for the original project's readers: no fork issue numbers or spec ids.

## Acceptance
- [ ] `CapturePauseTimelineTests` (written first) pin: no pause → `recordingSeconds == t`, nothing paused, whole buffers kept; one closed pause → paused exactly on `[start, end)`, recording clock flat inside it and shifted by its length after it; `keptFrameRanges` for a buffer before, inside, straddling the start, straddling the end, and containing a whole short pause; an open pause; several pauses; repeated `pause`/`resume` are no-ops.
- [ ] Alignment proof (written first): drive the microphone tap block (fake engine session) and `resampleForwardAndWrite` (temp file) with different buffer sizes and phases (for example 10 ms app buffers and 85 ms microphone buffers offset by a few ms), each carrying a marker sample at the same host times, through one short pause (shorter than a microphone buffer), one long pause and repeated pauses; in the finished files every marker outside a pause sits, on both tracks, where the same run without pauses puts it minus the paused time before it (within one 16 kHz frame), markers inside a pause are absent, and each file's length equals the unpaused run's length minus the paused time. (Comparing each track against its own unpaused run cancels the resampler and converter latency.)
- [ ] Microphone and app track each: frames captured inside a pause are not written and not forwarded to the live sink; no silence is inserted for the pause; a real gap after the resume, and a restart gap that overlaps a pause, is filled with silence only for its unpaused part; on the microphone, `currentSignalAges.secondsSinceLastBuffer` and `currentLevelDBFS` keep updating from buffers delivered during the pause.
- [ ] `AudioCaptureResult.make` with a pause between the two first frames reports the delay on the recording clock; without a pause the result is unchanged and `pauseOffsets` is empty (existing `AudioCaptureResultTests` green).
- [ ] `pauseOffsets`: two pauses give two offsets, the second reduced by the first pause's length; the origin is the microphone's first frame when it started first (negative delay) and the app's when the microphone started later; a pause before any first frame gives 0; an open pause at stop is included.
- [ ] Session level: `AudioCaptureSession.pause()` / `resume()` / `isPaused` act on the microphone handler the session built (`micSessionFactory` seam); an unpaused session writes exactly as before (existing `AudioCaptureSession*`, `MicCaptureHandler*`, `AppAudioCapture*`, `TimelineAnchorTests` green).
- [ ] `cd tools/audiotap && swift test --parallel > <scratch>/t1-audiotap.log 2>&1` green (read the log, never pipe it).
- [ ] `./scripts/lint.sh` clean with the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 from `scripts/tool-versions.sh` (fetch them into a temp dir and put it first on `PATH` if they are not installed); no source file over 600 lines.
- [ ] `cd app/MeetingTranscriber && swift build` still compiles (the app links the library).

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
