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
AudioTapLib can now pause: `AudioCaptureSession.pause()` / `resume()` / `isPaused` drive one `CapturePauseTimeline` (behind `CapturePauseGate`) shared by the app-audio and microphone handlers, which cut the frames captured inside a pause out of every buffer before resampler/converter, file and live sink and feed their `TimelineAnchor` the pause-free recording clock; `AudioCaptureResult` reports `micDelay` on that clock and a new `pauseOffsets`. Library only, nothing in the app calls it yet.

stage: impl-review - skipped(policy: parallel-wave - conductor owns the review)

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

### Early proof point (measured, passes)

`CapturePauseAlignmentTests.testBothTracksDropTheSameSpanAndStayAligned` drives both real write paths through one gate in live order (48 kHz stereo app buffers of 10 ms from 0 s; 44.1 kHz mono microphone buffers of 3750 frames = 85 ms from 3 ms), 29 markers at the same host times, through a 29.8 ms pause (shorter than a microphone buffer), a 0.7 s pause and three repeated pauses (total 0.8511 s):
- app: worst marker deviation 0.40 of a 16 kHz frame, file length deviation -0.40 frames
- microphone: worst marker deviation 0.24 frames, file length deviation +0.60 frames
- markers inside pauses absent on both tracks and in both live sinks; sink length = unpaused minus paused time within 1 frame.
Mutation check (measured): making `keptFrameRanges` drop every buffer a pause touches fails the test (microphone 17 of 19 kept markers; app sink short by 302 frames). Observation worth knowing: with whole-buffer drops the app FILE still looked right, because the gap fill replaced the dropped unpaused audio with silence; only the sink check exposed it.

### Acceptance

- Timeline contract: `CapturePauseTimelineTests` (10 tests, written before the type).
- Alignment proof: above.
- Per track: `CapturePauseTrackTests.testAGapAroundAPauseIsFilledOnlyForItsUnpausedPart` (both tracks: 2 s restart gap with a 1 s pause inside, silence = 1 s within 3 ms, sink carries no silence); `testTheMicrophoneKeepsReportingWhilePaused` (level and `secondsSinceLastBuffer` update from a paused buffer; nothing written or forwarded).
- `AudioCaptureResult.make`: `testMakeReportsTheMicDelayWithoutThePauseBetweenTheFirstFrames`, `testMakeWithoutAPauseReportsNoPauseOffsets`, `testMakePlacesEachPauseOnTheSavedTimeline` (two pauses, mic first, mic later, pause before first frames, pause around them, open pause), `testMakeWithoutAnyFirstFramePutsEveryPauseAtZero`; existing result tests unchanged and green.
- Session: `AudioCaptureSessionPauseTests.testPauseAndResumeActOnTheMicrophoneTheSessionBuilt` (micSessionFactory seam).
- Gates: see evidence. Full AudioTapLib suite `swift test --parallel` 550 tests exit 0 (run before the final two-line edit: whole-buffer check switched from an array literal to `kept.first`, `copy(frames:of:)` made private); after that edit the spec's focused Quick command (148 tests) exit 0, `./scripts/lint.sh` 0 violations / 0 files to format, `cd app/MeetingTranscriber && swift build` exit 0 (21 s first build, 0 warnings). `swift build -c release` of AudioTapLib exit 0 (before the final edit).
- Line caps: `MicCaptureHandler.swift` 595 -> 570 (write path moved to new `MicCaptureHandler+Write.swift`), `AppAudioCapture.swift` 580 -> 584.

baseline: green via handoff (conductor-verified at 69e42de9, spec Quick commands exit 0; only .flow/ changed since); lint re-run at baseline: 0 violations

### Decisions

1. (1) An empty pause (resume at or before the pause instant) stays in the pause list and gets a `pauseOffsets` entry: the spec asks for one entry per pause, and task .4 pairs the capture's positions with its own pause log by count. Alternative: drop empty pauses. Switch: `CapturePauseTimeline.resume(atHostSeconds:)`. Test: `CapturePauseTimelineTests.testAResumeEarlierThanItsPauseClampsToThePauseStart`.
2. (6) A pause stamped before the previous resume starts at that resume, so pauses stay ordered and disjoint. Alternative: accept overlapping pauses. Switch: `CapturePauseTimeline.pause(atHostSeconds:)`. Test: `testAPauseEarlierThanTheLastResumeStartsAtThatResume`.
3. (6) Frame boundaries snap with a 1e-3-frame tolerance so a pause starting exactly on a frame cuts that frame despite host-second rounding. Alternative: exact ceil. Switch: `CapturePauseTimeline.boundaryToleranceFrames`. Test: `testKeptFrameRangesAroundOneClosedPause` (the "ending exactly at the pause" and "starting exactly at the resume" rows).
4. (1) Nothing is allocated under the gate's lock (spec, Edge Cases "Audio thread"): writes build the new timeline outside the lock and swap it in with a compare-and-retry. Alternative: mutate under the lock (append can allocate). Switch: `CapturePauseGate.update`. Test: none can observe allocation; covered functionally by every pause test.
5. (6) `isPaused` means "a pause is open" (no clock read). Switch: `CapturePauseGate.isPaused`. Test: `AudioCaptureSessionPauseTests`.
6. (6) `CapturePauseTimeline` / `CapturePauseGate` stay internal; the public surface is only `AudioCaptureSession.pause/resume/isPaused` and `AudioCaptureResult.pauseOffsets` (init parameter defaulted to `[]`). Switch: the two types' access level.
7. (6) The library writes no log line on pause/resume: R1 asks for exactly one diagnostic line per pause/resume, which task .4 writes in the app. Switch: `AudioCaptureSession.pause()`.
8. (6) `AudioCaptureSession.makeAppCapture` takes the gate as a required parameter (no default), so no production caller can build an app capture that ignores the session's pauses; the one existing test call passes `CapturePauseGate()`. The two handlers' internal inits default to a never-paused gate, as the public convenience inits need.
9. (6) The microphone piece is copied buffer by buffer at the format's bytes per frame (`MicCaptureHandler.copy(frames:of:)`), so it holds for any PCM layout the tap may deliver. Test: alignment and track tests (float mono only).
10. (1) The pause-offset origin counts the microphone only when it was recorded, the same condition `micDelay` uses (task: "tracks that delivered one").
11. (6) The mic write path moved to `MicCaptureHandler+Write.swift` with the original `MicCapture` log category, so the "Mic resample error" / "Mic write error" lines keep their Console category.

### Notes for the conductor

- Not run locally: CI's `swiftlint analyze` (`unused_declaration`, needs a clean xcodebuild). Every new internal declaration has a production caller (`CapturePauseGate.pause(atHostSeconds:)` is called by `pause()`; `isPaused(atHostSeconds:)` by the rate fallback in `keptFrameRanges`).
- The raw no-resampler fallback (`writeRawUnpausedFrames`) cuts by the same ranges but has no test: the resampler is always built for a 16 kHz target and there is no seam to remove it. Inferred correct, not measured.
- `TimelineAnchor.silenceFramesBefore(hostSeconds:)` keeps its label but now receives recording-clock seconds; its doc comment says so. A rename was left out as unrequested.
- Phase 1b reference read late (after implementation): IMPLEMENTER "opus at xhigh" resolves to the session model, so the phase was inert either way and no `implement` stage line applies.
- Follow-up (not filed, outside this task's surface): none.

### Review and integration (conductor)

stage: impl-review - ran [codex gpt-6-astra xhigh; round 1: three draws (correctness, contracts, integration) all NEEDS_WORK with the same two R3 findings, merged to 2, validator kept 2; fix pass by an Opus xhigh worker; round 2: single re-review SHIP, both prior findings fixed]

Integrated onto feat/gh-46-pause-recording as b9816669, 7efa8c60 (implementation) and fcb0d1b1, d3ec7c81 (review fixes), base 5d62cea1. Focused integrated verify at d3ec7c81: audiotap filter exit 0 (156 tests), app build exit 0, lint exit 0.

Review findings fixed:
1. P1: a fully paused first buffer never set the TimelineAnchor, so a delivery gap after the resume vanished (16,000 frames lost). Fix: TimelineAnchor.anchorIfUnset, called by both handlers when a buffer writes nothing.
2. P2: whole-frame cuts against an exact-seconds clock accumulated per-boundary rounding over repeated pauses (up to 6.4 output frames on the app track). Fix: CapturePauseCutter carries the difference per track and settles it by one frame at the next seam.

Fix-pass decisions (rubric): (5) settlement in the input domain in a new per-track type, switch CapturePauseCutter.pieces, tests CapturePauseCutterTests + testRepeatedPausesOnSubFrameBoundariesDoNotAddUp; (5) a track behind repeats the first frame after a seam rather than writing a zero sample, switch Piece.leadingRepeats; (6) settle to the nearest frame; (6) anchor a fully paused buffer only when it writes nothing; (1) the mic cutter resets with its anchor on a new file; (6) the raw no-resampler fallback keeps the plain cut (untestable today, follow-up).

Follow-ups (not filed by the worker): AppAudioCapture.writeRawUnpausedFrames does not carry the sub-frame correction and has no test seam; CI's swiftlint analyze (unused_declaration) was not run locally for this task.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: b9816669cf721f34fd9373ee7c4a608cee3e21dd, 7efa8c6025596660c6120d12fb7713b2053d716b, fcb0d1b1e56c21b96e29bbd493adf629bcfce94f, d3ec7c818a0ff84614e0e42585399060023668de
- Tests: cd tools/audiotap && swift test --parallel --filter 'CapturePause|MicCaptureHandler|AppAudioCapture|AudioCaptureResult|AudioCaptureSession|TimelineAnchor' (integrated head d3ec7c81: exit 0, 156 tests, 1 skipped (needs an output device)), cd app/MeetingTranscriber && swift build (integrated head d3ec7c81: exit 0), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (integrated head d3ec7c81: exit 0, 0 violations in 789 files), cd tools/audiotap && swift test --parallel (lane tree equal to d3ec7c81: exit 0, 558 tests), cd tools/audiotap && swift build -c release (lane tree equal to d3ec7c81: exit 0), review: codex gpt-6-astra xhigh, round 1 three draws all NEEDS_WORK (2 findings, validator kept 2), round 2 single re-review SHIP (receipt /tmp/impl-review-receipt-d1afe3212e3b-gh-46-pause-and-resume-a-recording.1.json), cd tools/audiotap && swift test --parallel --filter 'CapturePause|MicCaptureHandler|AppAudioCapture|AudioCaptureResult|AudioCaptureSession|TimelineAnchor', cd app/MeetingTranscriber && swift build, ./scripts/lint.sh
- PRs: