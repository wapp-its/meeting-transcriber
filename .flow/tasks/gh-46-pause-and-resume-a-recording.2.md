---
satisfies: [R4]
---
# gh-46-pause-and-resume-a-recording.2 Pause record and transcript markers

## Description
The pause record and the transcript marker: a `RecordingPause` value (wall-clock `startedAt`/`endedAt`, `offsetSeconds` on the saved timeline), a pure pause log that turns pause/resume times into that list, the `PipelineJob` field that carries it, and every transcript rendering placing `[Pause HH:MM–HH:MM]` at the right point (spec: Architecture "The pause record", "The transcript marker is rendered, not stored"; R4; Edge Cases "Several pauses", "Speaker-name re-apply"). Independent of the capture work; nothing produces pauses yet except tests.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/RecordingPause.swift` (new), `TimestampedSegment.swift`, `DiarizationProcess.swift`, `PipelineJob.swift`, `PipelineQueue+Stages.swift`, `SpeakerNamingSession.swift`, `SpeakerNamingSession+Late.swift`; tests and the three `SpeakerNamingSessionDelegate` test doubles
**Touches:** [app/MeetingTranscriber/Sources/RecordingPause.swift, app/MeetingTranscriber/Sources/TimestampedSegment.swift, app/MeetingTranscriber/Sources/DiarizationProcess.swift, app/MeetingTranscriber/Sources/PipelineJob.swift, app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift, app/MeetingTranscriber/Sources/SpeakerNamingSession.swift, app/MeetingTranscriber/Sources/SpeakerNamingSession+Late.swift, app/MeetingTranscriber/Tests/RecordingPauseTests.swift, app/MeetingTranscriber/Tests/TranscriptPauseMarkerTests.swift, app/MeetingTranscriber/Tests/TranscriptPauseMarkerPipelineTests.swift, app/MeetingTranscriber/Tests/DiarizationProcessTests.swift, app/MeetingTranscriber/Tests/PipelineJob*Tests.swift, app/MeetingTranscriber/Tests/SpeakerNamingSessionTests.swift, app/MeetingTranscriber/Tests/AccidentalNamingAcceptTests.swift]

## Approach
- **`RecordingPause`** (`Codable`, `Equatable`, `Sendable`): `startedAt: Date`, `endedAt: Date`, `offsetSeconds: TimeInterval`. A marker line function taking a `TimeZone` (default `.current`): `[Pause 14:05–14:20]`, en dash U+2013, 24-hour `HH:mm` through a `DateFormatter` with `en_US_POSIX` locale and the given time zone (fixed-format pattern: `DateFormatter+FilenameStamp.swift`).
- **`RecordingPauseLog`** (pure value type, same file or a sibling): `pausedSince: Date?`; `pause(at:)` (no-op while paused, reports whether it changed); `resume(at:)` (no-op while running, returns the paused duration); `pauses(endingAt stop: Date, recordingStartedAt origin: Date, capturedOffsets: [TimeInterval]) -> [RecordingPause]` closes an open pause at `stop` and takes each `offsetSeconds` from `capturedOffsets` (the positions the capture session measured, spec "Alignment and positions") when its count equals the number of pauses; otherwise it falls back to `max(0, (startedAt − origin) − sum of earlier pause durations)` for every pause and the caller logs that it did. Plus three helpers on `[RecordingPause]` that the end-of-recording task (and later gh-45) uses: `pausedDuration(from: Date, to: Date)` (paused time inside the interval, an open-ended pause counted up to `to`), `timelineOffset(of: Date, recordingStartedAt:)` (wall time since origin minus `pausedDuration` up to that date, clamped at 0; flat inside a pause) and `clipped(at cut: Date)` (drops pauses starting at or after `cut`, ends a pause spanning `cut` at `cut`). Tests first: these are a clear contract.
- **Job field.** `PipelineJob` (`PipelineJob.swift:45-211`) gets `var pauses: [RecordingPause]?` (nil = none; optional because the synthesized decoder must accept snapshots without the key; add the `discouraged_optional_collection` disable comment the way `PipelineQueue+Stages.swift:41` does) and an init parameter `pauses: [RecordingPause] = []` stored as nil when empty. `prepareForRetry` (`:232-239`) keeps it: it describes the recording, not the run.
- **Rendering.** `[TimestampedSegment].transcriptText(note:)` (`TimestampedSegment.swift:53-57`) becomes `transcriptText(note:pauses:)` (pauses without a default, like `note`, so no call site can forget it; a `timeZone` parameter defaulting to `.current` for tests). After dropping suppressed segments, each pause in offset order goes on its own line before the first rendered line whose segment `start >= offsetSeconds`; any left over go at the end; then `TranscriptNote.prepend` as today.
- **Merge break.** `DiarizationProcess.mergeConsecutiveSpeakers` (`DiarizationProcess.swift:247-270`) gets `breakingAt offsets: [TimeInterval] = []`: never merge `seg` into the running block when an offset `o` satisfies `current.start < o <= seg.start`.
- **Call sites.** In `PipelineQueue+Stages.swift`: a helper beside `transcriptNote(_:)` (`:283-285`) reading the job's pauses; `TranscriptionOutput` (`:33-47`) carries them like `note` (set where `note:` is set, about `:497-503`); the empty-body check (`:206`) renders with `pauses: []` so a marker-only transcript still fails as "Empty transcript"; the transcription-stage renderings (`:457`, `:488`) and `labeledTranscript` (`:775-779`) pass the job's pauses; `renderLabeledTranscript` (`:790-823`) gets a `pauses:` parameter, merges with `breakingAt` the pause offsets, and renders with them. The delegate requirement `SpeakerNamingSessionDelegate.renderLabeledTranscript` (`SpeakerNamingSession.swift:42-45`) gains the same parameter; the late rebuild (`SpeakerNamingSession+Late.swift:340-344`) passes `delegate.job(withID: jobID)?.pauses ?? []`. Update the doubles at `Tests/SpeakerNamingSessionTests.swift:67, 370` and `Tests/AccidentalNamingAcceptTests.swift:81`.

## Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/TimestampedSegment.swift:45-91` and `TranscriptNote.swift` — the single render point and the note precedent
- `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift:33-47, 200-215, 280-286, 440-505, 760-823` — every render site
- `app/MeetingTranscriber/Sources/SpeakerNamingSession+Late.swift:320-350` — late rebuild
- `app/MeetingTranscriber/Tests/EmptyTrackSurvivesTests.swift:16-200` — pipeline harness that checks the saved transcript after the transcription stage, the speaker-labelled rewrite and a late re-diarization

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/TranscriptNoteTests.swift` — pure render test style
- `app/MeetingTranscriber/Sources/DateFormatter+FilenameStamp.swift` — POSIX fixed-format formatter

## Key context
- The speaker-name re-apply (`SpeakerNamingSession+Late.swift:62-70`) replaces `] <label>:` in the saved file; a marker line has no `] X:` and survives it untouched.
- Markers sit on the transcript timeline, which is the saved tracks' timeline after the dual-source merge and after VAD remapping, so no other stage needs to know about pauses.
- `Tests/TestHelpers.swift` is exactly 600 lines: put new helpers in the new test files.
- Commit messages are written for the original project's readers: no fork issue numbers or spec ids.

## Acceptance
- [ ] `RecordingPauseTests` (written first) pin the marker text with a fixed time zone (`[Pause 14:05–14:20]`, en dash, 24-hour even where the user locale is 12-hour, a pause across midnight), the log (pause/resume idempotency, an open pause closed at the stop, captured offsets used when their count matches, the wall-clock fallback subtracting earlier pauses and clamped at 0 otherwise), `pausedDuration(from:to:)` over intervals that miss, cut into and contain pauses, `timelineOffset(of:recordingStartedAt:)` before, inside and after pauses, and `clipped(at:)`.
- [ ] Rendering tests: a marker lands before the first line starting at or after its offset; at the top (under the note) for offset 0; at the end when past the last segment; several markers in order; suppressed segments ignored; no pauses → output byte-identical to today.
- [ ] `mergeConsecutiveSpeakers(_:breakingAt:)`: two same-speaker segments on either side of an offset stay separate lines; without offsets behaviour is unchanged.
- [ ] `PipelineJob` decodes a snapshot without `pauses` (nil) and round-trips one with pauses; retry keeps them.
- [ ] Pipeline runs in the `EmptyTrackSurvivesTests` style (new `TranscriptPauseMarkerPipelineTests.swift`) with a job carrying a pause: the saved transcript has the marker between the right lines after the transcription stage, after the speaker-labelled rewrite (diarization on), and after a late re-diarization; a job whose engine returns no segments but which has a pause still ends in `.error` "Empty transcript".
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'RecordingPause|TranscriptNote|Transcript|Timestamped|Diarization|PipelineJob|PipelineQueue|EmptyTrack|SpeakerNaming|AccidentalNaming' > <scratch>/t2.log 2>&1` green (read the log; model-download tests failing under the scratch home are environmental).
- [ ] `./scripts/lint.sh` clean with the pinned tools (fetch them into a temp dir first on `PATH` if not installed); no touched file without a `file_length` disable crosses 600 lines.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
