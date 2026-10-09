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
A recording the app died with while the meeting-end question was open is now cut back at launch recovery before the orphan scan queues it, so the room audio recorded while asking reaches neither the transcript nor the protocol. `RecoveredCut` (new) collects stored cuts before header repair and re-mix, places the cut with the live two-estimate rule (or applies a stored `keptSeconds` unchanged), refuses a recording whose capture ended more than 5 minutes past the deadline, restores originals a failed rollback left hidden, and logs one line per settled stored cut. Staged recovery passes now run one at a time, and a recording left unsettled is held back from that pass's orphan scan.

stage: impl-review - ran [2026-10-09T01:04:35Z..2026-10-09T01:26:46Z] (codex gpt-5.6-sol xhigh per receipt; round 1 three draws correctness/contracts/integration all NEEDS_WORK, validator kept 4 of 4; round 2 NEEDS_WORK on one finding; round 3 SHIP)

Tier: session (jev-unavailable(no_key)); explicit invocation: opus at xhigh; actual model: claude-opus-5-5 (host metadata)

baseline: green via handoff (spec focused filter verified at d2db03e1 by task .1; only .flow/ changed since); lint 0 violations before any edit

### Tests per acceptance criterion

All in `app/MeetingTranscriber/Tests/RecoveredCutTests.swift` unless named otherwise. Every `RecoveredCutTests` test checks at teardown that no captured line carries the stem or a `/`.

- decide (stored value, live rule, deadline boundary both sides, no capture end, nothing to keep): `testDecideKeepsAResolvedCutAndPlacesAnUnresolvedOneByTheLiveRule`
- crashed dual-source recording: `testACrashedDualSourceRecordingIsCutBeforeItIsQueued`
- microphone-only crash and orphan shape: `testAMicrophoneOnlyCrashAndAStoppedButUncutRecordingAreCutTheSameWay`
- idempotence (already cut, partial swap, plus a resolved value of 1e300 that used to trap): `testAResolvedCutIsFinishedAtItsPointAndNeverCutDeeper`
- app-only interrupted after the re-mix: `testAnAppOnlyRecordingInterruptedAfterItsReMixIsCutWhereOnePassCutsIt`
- ran past the deadline: `testAStoredCutBesideARecordingThatRanPastTheDeadlineIsRefused`
- invalid (unreadable, other recording) and held: `testInvalidStoredCutsAreRemovedAndAHeldOneIsLeftAlone`
- marker without mix, stale, restorable hidden mix: `testAStoredCutWithoutAMixWaitsForItsMarkerIsStaleWithoutAndCutsARestoredMix`
- cut failure: `testACutThatFailsLeavesTheOriginalsAndQueuesTheRecordingUncut`; rollback failure the extra restore fixes: `testAnOriginalTheCutsRollbackLeftHiddenIsPutBack`; rollback failure it cannot fix: `testAnOriginalTheCutsRollbackLeftHiddenAndThatCannotBePutBackKeepsTheRecordingUnsettled`; persistent restore failure then a complete second pass: `testAnOriginalThatCannotBePutBackKeepsTheStoredCutUntilALaterPassRestoresIt`; the orphan scan passing over an unsettled recording: `StagedRecoveryFolderTests.testTheOrphanScanPassesOverARecordingThePassLeftUnsettled`
- collect before header repair: `testTheCaptureEndIsReadBeforeHeadersAreRepairedAndTracksReMixed`. `WavHeaderRepair` restores the file's modification date after a repair, so the order against the repair alone is not observable through modification times. The test pins collect before the re-mix, which deletes the raw app temp whose write time is the capture end.
- two production passes back to back: `StagedRecoveryFolderTests.testTwoPassesStartedBackToBackCutTheRecordingOnce`; the queue's staging folder: `StagedRecoveryFolderTests.testTheStoredCutIsAppliedInTheQueuesStagingFolder`
- spec edge case A7 (a failed `keptSeconds` store still cuts): `testACutWhoseResolutionCannotBeStoredStillCuts`

Every guard was mutation-checked. Each of these edits turns its test red: removing the pass serialization, moving collect after the re-mix, not storing the capture end, skipping the restore, a strict deadline boundary, not storing `keptSeconds`, ignoring the hold, skipping the marker wait, restoring the trapping frame conversion (the test process dies with `Double value cannot be converted to Int64`), dropping the orphan-scan hold or its release, and not reporting unsettled stems. The back-to-back test first stayed green without serialization, because it counted only applied lines. It now asserts every line and goes red, since the racing pass logs `recovered_cut_failed domain=NSCocoaErrorDomain code=4` on the cut's shared working files.

Verification: spec Quick filter 127 of 127 passed on the final tree, `./scripts/lint.sh` 0 violations, and CI's `swiftlint analyze --strict` after a clean `xcodebuild build-for-testing` found 0 violations in 642 files.

### Decisions

- API shape. `RecoveredCut` is an enum with `decide(record:mixDuration:) -> Decision`, `collect(in:diagnostics:sync:) -> [PendingRecordingCut]` and `apply(_:in:diagnostics:rename:sync:) -> Set<String>` (the stems left unsettled), with a private `Pass` struct holding the folder, the sink and the injectable rename and sync. The alternative was a stateful pass object. Flip at `RecoveredCut.swift`.
- Log category `RecoveredCut` through `OSLogDiagnostics`, the same subsystem sink as gh-54's `WatchLoop` lines (the persistent log streams by subsystem). The alternative was reusing the `WatchLoop` category. Flip at `PipelineController.recoverStagedRecordings` in `PipelineController+ProductionEnvironment.swift`.
- Serialization. `@MainActor private(set) static var stagedRecoveryPass: Task<Void, Never>?` on `PipelineController`, and each pass awaits the previous one before anything, orphan scan included. The getter stays readable so a test can wait for a production pass. Flip at `PipelineController+ProductionEnvironment.swift`.
- The pass's folder steps live in `nonisolated static func recoverStagingFolder(_:levelBalance:diagnostics:)`, so the tests drive the exact production sequence synchronously. `startStagedRecovery(into:levelBalance:diagnostics:)` is the production pass with an injectable sink, and `recoverStagedRecordings(into:levelBalance:)` passes `OSLogDiagnostics`.
- Unsettled recording barrier. A recording with an original track still hidden is held back from the orphan scan by claiming its mix in the queue's `InFlightRunRegistry` for as long as the scan runs (`PipelineController.recoverOrphans(into:holdingBack:recordingsDir:)`), because the scan already skips audio a run holds. The reviewer asked for an exclusion argument on the orphan scan, which needs `PipelineQueue+Recovery.swift` (outside this task's Touches). An intermediate fix that hid the mix by renaming it was rejected in review round 2 as fallible. Flip at `recoverOrphans`, or add `excluding:` to `recoverOrphanedRecordings` if Touches is widened.
- `RecordingCut.backupURL(for:)` is an internal static beside `sibling(of:suffix:)`, and `swapIn` now uses it.
- `RecordingCut.apply` compares the kept frame count with the track length in `Double` before converting to `AVAudioFramePosition`. This is behaviour-preserving for every representable value and also covers the live cut path. It stops a stored `keptSeconds` far past the recording's end from crashing every launch.
- The applied line reports `kept_s` as the mix's length after the cut and `removed_s` as the length before minus after, both rounded to whole seconds. The decided value can exceed the recording.
- When `recordResolution` fails in collect, the value read from disk is used for this pass and the failure is logged as `recovered_cut_store_failed value=capture_end outcome=<not_published|not_synced> domain=… code=…`. A published-but-unsynced write is logged as a failure, per the spec.
- Invalid-reason mapping. `otherRecording` logs `other_recording`. Every other `InvalidReason` (unreadable, empty, unknown version, times out of order, non-positive `keptSeconds`) logs `unreadable`.
- Line levels. `recovered_cut applied` and `recovered_cut refused reason=…` are notices. `recovered_cut_failed …`, `recovered_cut_store_failed …` and `recovered_cut_remove_failed outcome=<not_synced|emptied|failed> …` are warnings. A failed removal is logged because the spec makes a failed sync a failure of the operation.
- The stale judgment checks only mix and marker. The restore step runs first and leaves the entry unsettled when any restore fails, so "no hidden original left" already holds when the judgment runs.
- Test seam. `collect` and `apply` take `sync:` (mirroring `PendingRecordingCut`) so A7 is testable with a sync that fails on regular files only.
- Review findings declined. (1, part) A held stem with a visible mix could be queued by the orphan scan between its live stop and its live cut. That window predates this change, and the hold governs only the stored cut. (4) A process death inside a successful swap leaves the cut's hidden `.uncut` original behind. The spec's Boundaries leave the cut's hidden working files uncleaned. A draw's finding that marker reaping turns a marker-without-mix cut stale was dropped at merge as a false positive, because `cleanupTempFiles` reaps a marker only when no track is rescuable, so `stale` is the correct outcome.
- The `PendingRecordingCut.swift` carve-out was not used. The stem is derived from the file name inside `RecoveredCut`.

### Follow-ups noticed, not fixed

- The recovered cut does not remix a level-balanced recording after the cut as the live `cutBack` does since gh-4 (`RecordingCut.remixBalanced`). Decided at the 2026-10-09 fit check as a PR follow-up.
- Hidden `.<stem>_pending_cut.json.<UUID>.writing` temps a crash mid-write leaves are ignored by the scan and not swept.
- Hidden `.uncut` and `.cutting.wav` working files a crash inside a cut leaves are not cleaned up (spec Boundaries, review finding 4). Such a file can hold the full-length original, including the post-meeting audio.
- On a queue rebuild, the orphan scan can queue a just-stopped live recording before its live cut and enqueue (pre-existing). The new hold-back can now cover held stems with a few lines.
- The production wiring from unsettled stems to held mix paths has no direct test, because the production orphan scan reads the real recordings folder. `recoverOrphans` and `RecoveredCut.apply` are tested separately.
- The production orphan scan still reads `AppPaths.recordingsDir` instead of the queue's staging folder (pre-existing; the task said to leave it).
- `docs/architecture-macos.md` should name `RecoveredCut` and the recovery step (spec Boundaries). That file is outside this task's Touches.
- No user route to a mapped feature changed.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: f545040556e2e43d89e1194ad98bf17d52520fef, 6e191ac5bd4ec77c630181c5008a922d3f350640, c3eb6db70558a308744c3c95f6b870afad48afc1, a81226f8ccd3110164eacc57e96638c7a1e9ed57, 8f868a91dfe8120eaa55cc7aef630095f1a9b93c
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh60-home swift test --parallel --filter 'PendingRecordingCut|RecoveredCut|DualSourceRecorder|WatchLoopMeetingEnd|StagedRecovery|RecordingCut' (127/127 passed, exit 0), PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh (0 violations, exit 0), xcodebuild clean build-for-testing + swiftlint analyze --strict (0 violations in 642 files, exit 0)
- PRs: