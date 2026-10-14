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
A job that carries pauses now gets one `[Pause HH:MM–HH:MM]` line per pause in every transcript the pipeline saves (transcription draft, speaker-labelled rewrite, late re-diarization rebuild) and so in the protocol input and the protocol's full transcript. The line sits before the first line starting at or after the pause's position on the saved timeline, and same-speaker merging never spans a pause. New `Sources/RecordingPause.swift` holds `RecordingPause` (Codable, Equatable, Sendable), the pure `RecordingPauseLog`, and the `[RecordingPause]` helpers `pausedDuration(from:to:)`, `timelineOffset(of:recordingStartedAt:)` and `clipped(at:)` for tasks .4 and .5. `PipelineJob.pauses` is optional (nil = none), and a retry keeps it. Nothing produces pauses yet except tests.

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

stage: impl-review - skipped(policy: parallel-wave - conductor owns the review after integration)

baseline: green via handoff (conductor, spec Quick commands at 69e42de9, only .flow/ changed since) + lint measured green pre-edit (`./scripts/lint.sh`, 0 violations)

Gates (worker, on commit 87e0dec6):
- spec Quick 2 filter plus the task's classes, 436 tests, rc 0 (measured)
- task AC filter, 853 tests. 4 failures, all WhisperKit model-load E2E tests (`VADEnginePipelineE2ETests`, `WatchLoopE2ETests`: "unloaded is not equal to loaded"). The scratch home held a partial model download (TextDecoder weights 0 bytes). The same two classes pass serially in a fresh scratch home, 9/9 (measured). This is environmental.
- `./scripts/lint.sh` with the pinned tools, rc 0 (measured)
- `swiftlint analyze --strict` after a clean `xcodebuild build-for-testing` (CI parity): no finding in any touched file. It reports 2 `unused_declaration` in `RecordingProvider.swift:144,146`. This task does not touch that file. That they are pre-existing is inferred, not measured on the base.
- spec Quick 1 (tools/audiotap) not run: this task changes no audiotap code.
- Mutation check (measured): the wiring was broken on purpose at four points (empty-body check, draft render, late rebuild, merge break). Each time, exactly the matching `TranscriptPauseMarkerPipelineTests` failed, for the stated reason.

Tests by acceptance criterion:
- RecordingPause marker, log, conversions: `Tests/RecordingPauseTests.swift` (11). These were written before the code. A red run was not possible, because the test target cannot compile without the new type.
- Rendering and `mergeConsecutiveSpeakers(_:breakingAt:)`: `Tests/TranscriptPauseMarkerTests.swift` (7).
- Job decode, round trip, retry: `Tests/PipelineJobTests.swift` (3 new).
- Pipeline runs: `Tests/TranscriptPauseMarkerPipelineTests.swift` (4). It covers the transcription stage, the speaker-labelled rewrite (with the protocol input and file), the late re-diarization, and a marker-only job that ends `.error` "Empty transcript".

Touches deviation: `Tests/NamingSessionFixture.swift` (one signature line). The task's Approach names the double at `Tests/SpeakerNamingSessionTests.swift:67`. Commit 1e7b2ad7 moved that double to `NamingSessionFixture.swift` after planning. The test target does not compile without the change.

Decisions:
- D-a (rule 6): `renderLabeledTranscript` (the delegate requirement, the `PipelineQueue` witness and the 3 doubles) takes `annotations: (note: String?, pauses: [RecordingPause])`. The Approach had separate `note:` and `pauses:` parameters, but six parameters fail `function_parameter_count` under `lint.sh --strict`. The same protocol already bundles `tracks:` this way. Alternative: five `swiftlint:disable:next function_parameter_count` comments. Switch point: `SpeakerNamingSessionDelegate.renderLabeledTranscript` (`Sources/SpeakerNamingSession.swift`). Tests: `TranscriptPauseMarkerPipelineTests` speaker-labelled and late tests.
- D-b (rule 1, spec Edge Cases "Timestamps": "rendered in the time zone current at rendering time", and the repo precedent `ProtocolGenerator.meetingMetadata`): the default time zone is `.autoupdatingCurrent`. The task's Approach says `.current`, but `.current` is a cached snapshot in a long-running app. Switch point: the defaults of `RecordingPause.markerLine(in:)` and `[TimestampedSegment].transcriptText(note:pauses:timeZone:)`. Tests: `RecordingPauseTests` marker tests (fixed zone, Asia/Tokyo).
- D-c (rule 6): `RecordingPauseLog.resume(at:)` returns `TimeInterval?`: nil when nothing was paused, otherwise the duration clamped at 0. `pause(at:)` returns `Bool`. Neither is `@discardableResult`. Switch point: `Sources/RecordingPause.swift`. Test: `testResumingWhileRunningChangesNothing`, `testPausingWhilePausedChangesNothing`.
- D-d (rule 6): `pauses(endingAt:recordingStartedAt:capturedOffsets:)` keeps the Approach's `[RecordingPause]` return type. A caller detects the wall-clock fallback with `capturedOffsets.count != result.count`, as the doc comment states. Alternative: return a tuple with a `usedCapturedOffsets` flag. Switch point: that function. Test: `testCapturedOffsetsAreUsedWhenTheirCountMatches`, `testTheWallClockFallbackSubtractsEarlierPauses`.
- D-e (rule 6): markers with equal offsets render in `startedAt` order (sort key `(offsetSeconds, startedAt)`), because Swift's sort is not documented as stable. Switch point: `transcriptText(note:pauses:timeZone:)`. Test: `testSeveralMarkersAppearInTimelineOrder` (distinct offsets).
- D-f (rule 6): the `mergeConsecutiveSpeakers` merge-break tests live in `TranscriptPauseMarkerTests.swift`. `DiarizationProcessTests.swift` is at 590 lines and would cross the 600-line lint cap.
- D-g (rule 1, Approach): the `pauses` init parameter sits after `meetingStartTime`. A single-source job also renders the job's pauses. The Approach lists that render site.

Follow-ups (not part of this task):
- `Sources/TranscriptNote.swift:5` doc comment still names `transcriptText(note:)`. This task may not touch that file. The fix is a comment only.
- Two `unused_declaration` findings from `swiftlint analyze` in `Sources/RecordingProvider.swift:144,146` (`storePendingCut`, `recordPendingCutResolution` protocol-extension defaults). CI's analyze job would fail on them.

Integration notes for the conductor and tasks .4/.5: NOTES_DIR `task2-integration-notes.md`.

### Review and integration (conductor)

stage: impl-review - ran [codex gpt-6-astra xhigh; round 1: three draws (correctness, contracts, integration) all SHIP, 0 findings; no fix pass]

Integrated onto feat/gh-46-pause-recording as 887a2936 (lane commit 87e0dec6), base 1972a313. Focused integrated verify at 887a2936: the spec's app Quick filter plus this task's classes, 538 tests, 536 passed; the 2 failures (WatchLoopE2ETests, job ended error) came from a fresh scratch home without a WhisperKit model and pass 9/9 in a serial rerun with a complete model (flaky-gate rerun, recorded both runs); lint exit 0.

Conductor decisions on the worker's report: Touches deviation accepted (rule 6): the one-line signature change in Tests/NamingSessionFixture.swift is the test double the task names, moved after planning; the test target does not compile without it. D-a (annotations tuple, rule 6), D-b (.autoupdatingCurrent, rule 1 per spec Edge Cases Timestamps), D-c to D-g (rule 6) accepted as reported.

Follow-ups (not in this task): Sources/TranscriptNote.swift:5 doc comment still names transcriptText(note:); swiftlint analyze reports 2 pre-existing unused_declaration in Sources/RecordingProvider.swift:144,146.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 887a29367d477ebc9ae515b638ae5415e995c70c
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/gh46-home-c2 swift test --parallel --filter 'RecordingPause|WatchLoopPause|DualSourceRecorderPause|ChannelHealth|RecordControl|RPCRecordStatus|MenuBar|EmptyTrack|RecordingSidecar|TranscriptPauseMarker|PipelineJob|SpeakerNaming|AccidentalNaming|TranscriptNote|Timestamped|Diarization' (integrated head 887a2936: 538 tests, 536 passed, 2 failed: WatchLoopE2ETests.testDiarizationSkippedWhenNotAvailable and testFullPipelineWithRealDiarization, job ended error under a fresh scratch home without a WhisperKit model), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/gh46-home-t2b swift test --filter 'WatchLoopE2ETests|VADEnginePipelineE2ETests' (flaky-gate rerun, serial, scratch home with a complete model: exit 0, 9 tests, 0 failures), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (integrated head 887a2936: exit 0, 0 violations in 793 files), worker at lane head 87e0dec6 (same tree): spec Quick 2 filter plus task classes 436 tests exit 0; task AC filter 853 tests with 4 environmental WhisperKit model-load failures that pass 9/9 serially; lint exit 0; xcodebuild clean build-for-testing + swiftlint analyze --strict: no finding in a touched file; four-point mutation check, each mutation failed exactly its matching test, review: codex gpt-6-astra xhigh, round 1 three draws (correctness, contracts, integration) all SHIP, 0 findings (receipt /tmp/impl-review-receipt-d1afe3212e3b-gh-46-pause-and-resume-a-recording.2.json), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'RecordingPause|WatchLoopPause|DualSourceRecorderPause|ChannelHealth|RecordControl|RPCRecordStatus|MenuBar|EmptyTrack|RecordingSidecar|TranscriptPauseMarker|PipelineJob|SpeakerNaming|AccidentalNaming|TranscriptNote|Timestamped|Diarization', ./scripts/lint.sh
- PRs: