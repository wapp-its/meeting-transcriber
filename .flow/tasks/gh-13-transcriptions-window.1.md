---
satisfies: [R2, R3, R9]
---
# gh-13-transcriptions-window.1 History record with app, dates, duration and participants

## Description
Give the existing finished-job store the fields the window needs (app, meeting start, enqueue time, audio duration, participants) without changing the `/v1` wire shape, and have stage 1 measure each job's audio duration. First in order because it proves the store can carry the history (spec "Early proof point"); tasks .2-.4 only read what this task writes. See spec "Architecture & Data Models" (History record, Store, Duration).

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/TerminalJobRecord.swift` (new), `app/MeetingTranscriber/Sources/TerminalJobStore.swift`, `app/MeetingTranscriber/Sources/PipelineJob.swift`, `app/MeetingTranscriber/Sources/PipelineQueue.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift`, `app/MeetingTranscriber/Tests/TerminalJobRecordTests.swift` (new), `app/MeetingTranscriber/Tests/TerminalJobStoreTests.swift`, `app/MeetingTranscriber/Tests/PipelineQueueHistoryRecordTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/TerminalJobRecord.swift, app/MeetingTranscriber/Sources/TerminalJobStore.swift, app/MeetingTranscriber/Sources/PipelineJob.swift, app/MeetingTranscriber/Sources/PipelineQueue.swift, app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift, app/MeetingTranscriber/Tests/TerminalJobRecordTests.swift, app/MeetingTranscriber/Tests/TerminalJobStoreTests.swift, app/MeetingTranscriber/Tests/PipelineQueueHistoryRecordTests.swift]

### Approach
- Tests first: the legacy-decode test and the wire-unchanged test below, run red, then the type.
- `TerminalJobRecord: Codable, Equatable` (not `#if !APPSTORE`): `let status: JobStatusDTO` plus `appName: String?`, `meetingStartTime: Date?`, `enqueuedAt: Date?`, `audioDuration: TimeInterval?`, `participants: [String]`. Flatten it exactly like `JobStatusResponse` at `Sources/DebugRPCServer+V1.swift:9-31`: `init(from:)` decodes `status` with `JobStatusDTO(from: decoder)` and every extra with `decodeIfPresent` (participants `?? []`); `encode(to:)` encodes `status` first, then the extras with `encodeIfPresent` (participants only when non-empty).
- Two initialisers: `init(job: PipelineJob)` (status through the existing `JobStatusDTO(job:)` at `Sources/JobStatusDTO.swift:124-139`, extras copied from the job) and `init(status: JobStatusDTO)` (extras nil/empty).
- `TerminalJobStore` (`Sources/TerminalJobStore.swift`): element type `TerminalJobRecord`; add `@Observable` with `@ObservationIgnored` on `path` and `cap`, keeping `@MainActor final class`; default `cap: 1000`; `record(_: TerminalJobRecord)` plus a kept `record(_: JobStatusDTO)` convenience that wraps with `init(status:)` (so `Tests/PipelineControllerTests.swift:268,425` stay untouched); `lookup(jobID:)` still returns `JobStatusDTO?` (the record's `status`); `upserting` keys on `status.jobID`; load decodes `[TerminalJobRecord]`. Update the type's doc comment (element type, cap) and the "same JobStatusDTO" note at `Sources/JobStatusDTO.swift:3-6` only if it becomes untrue.
- `PipelineQueue.recordTerminalJob` (`Sources/PipelineQueue.swift:669-671`) records `TerminalJobRecord(job:)`.
- `PipelineJob` (`Sources/PipelineJob.swift`): add `var audioDuration: TimeInterval?` next to `trackViability`, with a doc comment saying stage 1 writes it and nil means not measured (or a snapshot from before the field). Leave the init and `prepareForRetry` (`:232-239`) alone; a retry re-measures the same audio.
- `PipelineQueue.recordAudioDuration(jobID:_:)` shaped like `recordEchoVerdict` (`Sources/PipelineQueue.swift:751-754`): sets the field only for a value > 0, no snapshot write of its own (the next state transition persists it).
- Stage 1 (`Sources/PipelineQueue+Stages.swift`): dual source, after both resamples in `transcribeDualSource` (`:325-338`), duration = max(app frames, mic frames) / `AudioConstants.targetSampleRate`; `resolveTrackViability` (`:297-316`) already reads both frame counts with `AudioMixer.frameCount(of:)`, so either return them from it or read them again (about 1 ms each). Single source, right after `AudioMixer.resampleFile(from: mixPath, to: mix16k)` (`:463-464`) and before VAD trimming: `AudioMixer.frameCount(of: mix16k)` / rate.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/TerminalJobStore.swift` — the whole store (97 lines)
- `app/MeetingTranscriber/Sources/JobStatusDTO.swift:1-41,113-139` — wire shape, lenient echo decoder, job mapping
- `app/MeetingTranscriber/Sources/DebugRPCServer+V1.swift:9-31` — the flattening pattern to copy
- `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift:297-338,435-500` — stage 1, both branches
- `app/MeetingTranscriber/Sources/PipelineQueue.swift:654-671,745-754` — terminal transition, per-job recorders

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/TerminalJobStoreTests.swift` — existing store tests to adapt
- `app/MeetingTranscriber/Tests/PipelineQueueRetryTests.swift:41-90` — mock-engine queue harness and `failOneJob`
- `app/MeetingTranscriber/Tests/EmptyTrackSurvivesTests.swift:36-75` — dual-source harness (`segmentsByPathSuffix`)
- `app/MeetingTranscriber/Tests/TestHelpers.swift:486-510` — `createTestAudioFile`, 0.5 s of 16 kHz mono

### Key context
- Never nest the DTO under a key: an older build reads `terminal_jobs.json` as `[JobStatusDTO]` with synthesized `Decodable`, which ignores unknown keys, so only the flat layout keeps a downgrade from losing the history. A new non-optional key would make every legacy record throw and `load` return `[]` (the whole history gone).
- `JobStatusDTO` itself must not change: it is the `/v1/jobs/<id>` body (`docs/automation-api.md:380-400`).
- `audioDuration` is the recording's length, not the transcript's: `jobAudioSeconds` (`PipelineQueue+Stages.swift:494-497`) is the last segment's end and stays as it is.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<your scratch dir>/home swift test --parallel --filter 'TerminalJobRecordTests|TerminalJobStoreTests|PipelineQueueHistoryRecordTests|PipelineControllerTests|PipelineQueueRetryTests|EmptyTrackSurvivesTests' > <your scratch dir>/t1-tests.log 2>&1` and read the log (never pipe a test run into tail/head/grep).
- `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 from `scripts/tool-versions.sh` (fetch the pinned binaries into a temp dir and put it first on `PATH` if they are not installed; never `brew install`).
- `./scripts/pre-push.sh --with-appstore` (release build plus the App Store variant: the new type must compile in both).

## Acceptance
- [ ] A `terminal_jobs.json` holding plain `JobStatusDTO` objects, as written before this change, loads every record with nil app, dates and duration and empty participants (R9).
- [ ] A record with every extra set survives a store re-created from the same file unchanged (R3).
- [ ] The `JobStatusDTO` that `lookup(jobID:)` returns encodes without any of the keys `appName`, `meetingStartTime`, `enqueuedAt`, `audioDuration`, `participants` (R9).
- [ ] The default cap is 1000: after 1001 distinct records the store holds the newest 1000 (R2).
- [ ] A single-source job run to `.done` through the mock-engine pipeline with `createTestAudioFile` leaves a history record with its app name, participants, meeting start, enqueue time and an audio duration of 0.5 s ± 0.05 (R2, R3).
- [ ] A dual-source job's `audioDuration` equals the longer of its two 16 kHz tracks (R2).
- [ ] `TerminalJobStoreTests` (adapted to the new element type only), `PipelineControllerTests` and `PipelineQueueRetryTests` pass; lint and `./scripts/pre-push.sh --with-appstore` are clean.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
