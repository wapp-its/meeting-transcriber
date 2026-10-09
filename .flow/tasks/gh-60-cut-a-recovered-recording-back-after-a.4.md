---
satisfies: [R2, R3, R5]
---
# gh-60-cut-a-recovered-recording-back-after-a.4 Apply a stored meeting-end cut when recovering a crashed recording

## Description
The proof point: launch recovery of staged recordings applies a stored cut before the recording is queued, finishes an interrupted cut at the same point, refuses a stale one, restores originals a failed rollback left hidden, and runs one pass at a time. Tests write stored cuts by hand with task 1's type, so nothing here needs the live path. See spec Architecture (one recovery pass at a time, recovery applies it, the resolved cut, the deadline check), Edge Cases, R2, R3 (recovery guard), R5.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/RecoveredCut.swift` (new), `app/MeetingTranscriber/Sources/RecordingCut.swift`, `app/MeetingTranscriber/Sources/DualSourceRecorder.swift`, `app/MeetingTranscriber/Sources/PipelineController.swift`, `app/MeetingTranscriber/Sources/PipelineController+ProductionEnvironment.swift`, `app/MeetingTranscriber/Tests/RecoveredCutTests.swift` (new), `app/MeetingTranscriber/Tests/StagedRecoveryFolderTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/RecoveredCut.swift, app/MeetingTranscriber/Sources/RecordingCut.swift, app/MeetingTranscriber/Sources/DualSourceRecorder.swift, app/MeetingTranscriber/Sources/PipelineController.swift, app/MeetingTranscriber/Sources/PipelineController+ProductionEnvironment.swift, app/MeetingTranscriber/Tests/RecoveredCutTests.swift, app/MeetingTranscriber/Tests/StagedRecoveryFolderTests.swift]

### Approach
- Pure `RecoveredCut.decide(record:mixDuration:)`: `keptSeconds` present → cut at exactly that (no deadline check, no recomputation). Absent → no `captureEndedAt` → refuse `no_capture_end`; `captureEndedAt > deadline + 5 min` (named constant, spec rationale beside it) → refuse `ran_past_deadline`; else `RecordingCut.keptSeconds(cutAt:startedAt:stoppedAt: captureEndedAt, mixDuration:)` (`RecordingCut.swift:52`), ≤ 0 → refuse `nothing_to_keep`, else cut.
- `collect(in:)` (runs FIRST in the pass): every non-hidden stored-cut file in staging whose stem is not held (task 1's hold set). Invalid → remove the file and log `refused reason=<unreadable|other_recording>` now (the recording stays untouched). Valid without `captureEndedAt` → read the capture end (widen `DualSourceRecorder.lastTrackWrite(stem:in:)`, `DualSourceRecorder.swift:266`, from private; it covers the raw temps and `_mic.wav`; fall back to `_app.wav`; never `_mix.wav` or hidden files) and store it with `PendingRecordingCut.recordResolution`; a failed store is logged and the in-memory value is used for this pass.
- `apply(_:in:diagnostics:rename:)` (after the re-mix): per entry, independently. FIRST, for every entry whatever is on disk, restore each of the stem's three track paths (`_mix`, `_app`, `_mic`) that is missing while its hidden backup exists (add `RecordingCut.backupURL(for:)` exposing the existing `sibling(of:suffix: "uncut")` name, used at `RecordingCut.swift:201`, defined at `:237`); a restore that fails logs `recovered_cut_failed restore …`, keeps the stored cut and skips the entry. Only then judge: no `_mix.wav` → marker present: keep the stored cut (re-mix failed, retry next pass); no marker and no hidden backup left: remove, log `refused reason=stale`. Mix present → `decide`; refuse → log, remove the stored cut; cut → if `keptSeconds` was absent store it first (failure logged, cut proceeds, spec A7), then `RecordingCut.apply(to:keepingFirst:rename:)` on `RecordingResult(mixPath:appPath:micPath:micDelay: 0, recordingStartDate: .distantPast)` from the staged `_mix/_app/_mic`; success → log `recovered_cut applied removed_s=<n> kept_s=<n>` (removed = mix length before minus kept, 0 when already cut), remove the stored cut. `rollbackIncomplete(uncut:)` → move each backup back once; all back → log failed, remove the stored cut (queued uncut); any left → log, keep the stored cut. Other errors → log `recovered_cut_failed domain=<d> code=<c>`, remove the stored cut (queued uncut).
- Wire into `PipelineController.recoverStagedRecordings(into:levelBalance:)`, which since gh-4 lives in `PipelineController+ProductionEnvironment.swift:25-50` (called from `PipelineController.swift:173` with `settings.levelBalanceEnabled`; `recoverCrashedRecordings(in:levelBalance:)` takes the flag through and the re-mix is level-balanced when it is on), inside the detached block, on the queue's `staging` folder: `collect` → `WavHeaderRepair.repairUnfinalized` → `recoverCrashedRecordings` → `cleanupTempFiles` → `apply`; the orphan scan after it (`:48`) stays as is.
- Serialize passes: keep the previous pass's `Task` in a `@MainActor` static on `PipelineController` and have each new pass await it before doing anything, orphan scan included (spec A8).
- Diagnostics: injected `any DiagnosticsLogging`, production `OSLogDiagnostics(category:)`; no stem, path or title in any line.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/RecordingCut.swift` — keptSeconds, apply, rollbackIncomplete, hidden sibling names
- `app/MeetingTranscriber/Sources/DualSourceRecorder.swift:136-385` — cleanup, crash detection, lastTrackWrite, recoverCrashedRecording(s)
- `app/MeetingTranscriber/Sources/PipelineController+ProductionEnvironment.swift:25-50` — where the pass is started and its sequence (`PipelineController.swift:173` calls it)
- `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift:74-128` — the live cut this must match

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/RecordingCutTests.swift` — WAV fixture helpers (`makeTrack`), injected rename failures
- `app/MeetingTranscriber/Tests/DualSourceRecorderCrashRecoveryTests.swift` — crashed-recording fixtures (raw temp + mic + marker, mic-only)
- `app/MeetingTranscriber/Tests/StagedRecoveryFolderTests.swift` — driving the production pass against a temp staging folder
- `app/MeetingTranscriber/Tests/RecordingDiagnostics.swift` — capturing diagnostics double

### Key context
- The recovered mix is built with `micDelay: 0` from the tracks' file starts (`DualSourceRecorder.swift:305-323`), so every track sits at offset 0; the orphan shape is queued with `micDelay: 0` too, so cutting with 0 matches what is processed.
- Production `recoverStagedRecordings` runs the orphan scan with its default folder (`PipelineController+ProductionEnvironment.swift:48`, `PipelineQueue+Recovery.swift:441-450`), not the queue's staging folder. Leave that as it is, and assert on the staged files, never on a job queued through the production environment.
- Since gh-4 (A9) the live `cutBack` remixes a level-balanced recording after the cut (`RecordingCut.remixBalanced`, `WatchLoop+MeetingEnd.swift:114-121`). The recovered cut does not do that: the 2026-10-09 fit check left that parity as a follow-up for the PR, so do not add it here.
- Mtimes are wall clock; tests set them (`FileManager.setAttributes([.modificationDate: …])`) to place a recording inside or past the deadline.
## Acceptance
- [ ] `decide` uses a stored `keptSeconds` unchanged; otherwise returns the live rule's value for a recording that ended inside the countdown, refuses `ran_past_deadline` just past deadline + tolerance (boundary pinned on both sides), `no_capture_end` without one and `nothing_to_keep` for a cut at or before the audio's start.
- [ ] Crashed dual-source recording (raw app temp + `_mic.wav` + marker + stored cut): collect → re-mix → apply leaves mix, app and mic ending at the same expected frame (WAV fixtures), the stored cut gone, and one `applied removed_s=… kept_s=…` line.
- [ ] The same for a microphone-only crashed recording and for the orphan shape (mix + tracks, no marker: crash between stop and cut).
- [ ] Idempotence with capture beginning before `startedAt` (e.g. startedAt 0, cutAt 100, stop 220, 250 s mix, live keeps 130): a recording already cut to the stored `keptSeconds` stays at 130 s, and one with only the mix cut (partial swap) ends with every track at 130 s; neither is cut deeper.
- [ ] App-only recording interrupted after the re-mix: a first pass that stops after collect + re-mix, then a second full pass, cuts at the same point as one uninterrupted pass (the stored `captureEndedAt` is used, not the re-mixed app track's time).
- [ ] A stored cut beside a recording whose capture ended past deadline + tolerance is refused; the tracks stay byte-identical; the stored cut is removed and logged.
- [ ] Invalid stored cuts (unreadable, other recording) are removed and logged; the recording is untouched. A held stem's stored cut and tracks are left alone even with a mix present.
- [ ] Marker without mix: stored cut kept. No mix, no marker and no hidden backup: removed as `stale`. No mix and no marker but a restorable hidden mix: restored, then cut, not judged stale.
- [ ] Cut failure (unreadable track): originals in place, uncut, `recovered_cut_failed domain=… code=…`, stored cut removed. Rollback failure that the extra restore fixes: every original back on its path. Persistent restore failure (rename always failing) with the mix itself under its backup name and no marker: the stored cut stays (it is not judged stale), the original stays under its backup name, a failure line is logged; a complete second pass (collect → re-mix → cleanup → apply) with a working rename restores the mix and finishes the cut.
- [ ] Collect runs before header repair: with an unfinalized mic header, the stored `captureEndedAt` is the pre-repair time.
- [ ] Two production passes started back to back on the same staging folder cut the recording once (frame count, one `applied` line); `StagedRecoveryFolderTests` also shows the step works in the queue's staging folder.
- [ ] No captured log line contains the stem or a path; focused tests pass (spec Quick commands); lint clean.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
