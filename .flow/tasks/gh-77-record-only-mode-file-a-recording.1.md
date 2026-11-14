---
satisfies: [R1, R2, R3, R4, R5, R6, R7, R8]
---
# gh-77-record-only-mode-file-a-recording.1 Implement Record-only mode: file a recording recovered after a crash instead of processing it

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
In record-only mode a recording the staged recovery pass finds (the app died during it, or a live record-only write failed) is now filed into `<output folder>/recordings/` with a `<stem>_meta.json` sidecar instead of being queued for processing (R1-R8). The review found that a one-time processed-ledger migration hid the first crashed recording on an install that never finished a job (every record-only install); the migration is removed.

stage: impl-review - ran [2026-11-14T20:37Z..2026-11-14T20:51Z] (codex gpt-6-astra xhigh; round 1: 3 reviewers, NEEDS_WORK, 1 finding, validator kept it; round 2: SHIP, finding fixed)

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

baseline: green (build + 273 focused tests, 0 failures, before any edit)

Tests for the ACs and error cases:
- R1 `StagedRecoveryRecordOnlyTests.testACrashedRecordingInRecordOnlyModeIsWrittenWithItsSidecarAndNotQueued` (committed red first in d4214f9d)
- R2 `testWithRecordOnlyOffTheCrashedRecordingIsQueuedAndGetsNoSidecar`; setting read at hand-on `testThePassReadsTheSettingWhenItHandsItsRecordingsOn`
- R3 `testTheRecoveredSidecarHasTheRecoveryValuesAndReadsBack`, `testARecordingWhoseStemIsNoTimeAndWhoseMixCannotBeReadIsStillFiled`
- R4 `testAWriteThatFailsKeepsTheRecordingInStagingAndALaterPassFilesIt` (1 and 2 failures, exact notice bodies, retry without a new notice)
- R5 `StagedRecoveryFolderTests.testARecordingWithAStoredCutIsFiledCutInRecordOnlyMode`, `testARecordingWhoseCutFailsIsFiledUncutInRecordOnlyMode`
- R6 `OrphanRecoveryRaceTests.testARecordingTakenDuringTheScanIsNotFiledInRecordOnlyMode` (enqueued, started by another queue, cancelled, moved away, queue retired), `StagedRecoveryRecordOnlyTests.testAPassDuringAQuitLeavesTheQuitsRecordingToTheQuit`
- R7 `RecordOnlyLogPrivacyTests` (source scan of every log line, with a self-test)
- R8 `RecordOnlyStagingKeptTests` (exact body on the live and quit paths), `StagedRecoveryRecordOnlyTests.testAFiledRecordingWhoseStagingFilesStayTellsTheUser`
- Each new guard was removed once (quit check, retired check, still-orphaned check, file-exists check, live setting read, quit wiring, the record-only branch, the kept-files notice) and its test went red; all restored.

Assumptions (rule 4/5):
- A1 ledger seeding removed. Default built: no migration; the scan's 24-hour age limit covers old recordings. Alternatives: B keep it but skip it in record-only mode; C write an empty ledger on the first launch so the migration runs once. Flip at `PipelineQueue+OrphanRecovery.swift:scanForOrphanedRecordings`. Test: none committed (the branch ran only on the app's real staging folder, which tests must not touch); the reviewer's isolated-home probe went red before and green after.
- A2 recovered start time. Default built: the stem read as `yyyyMMdd_HHmmss` in the current time zone, else the files' earliest creation date, else now. Alternatives: B the mix's modification date minus its length; C leave `startedAt` at the stop. Flip at `RecordOnlyRecovery.swift:RecordOnlyWrite.recordedStart`. Test: the two R3 tests.
- A3 the "files left in staging" notice shows once per filed recording, as on a live stop. Alternatives: B one notice per pass with the count; C log only. Flip at `RecordOnlyRecovery.swift:PipelineQueue.fileOrphanedRecordings` (the `reportStagingFilesKept` call). Test: `testAFiledRecordingWhoseStagingFilesStayTellsTheUser`.
- A4 a retired queue or a begun quit ends the pass (`break`) rather than skipping recording by recording. Alternatives: B `continue` per recording; C check once before the loop. Flip at `RecordOnlyRecovery.swift:PipelineQueue.fileOrphanedRecordings` (first guard). Test: R6 race table ("queue retired") and the quit test.
- A5 failure notice wording: title "Record-only output failed" (the live path's title), body "A recovered recording could not be written ..." / "<n> recovered recordings could not be written ...". Alternative: B the live path's body. Flip at `RecordOnlyRecovery.swift:recoveredWriteFailedBody`. Test: the R4 test.

Follow-ups:
- Upstream-lane candidate: the ledger-seeding removal also fixes a processing-mode install whose very first recording crashed; generic, could go to the original via submit.sh after the owner's go.
- `PipelineQueue.recoverOrphanedRecordings` is now called only by tests (production runs scan, then adopt or file); its callers could move to `scanForOrphanedRecordings` + `adoptOrphanedRecordings` and the wrapper go.
- Not run locally: the App Store variant build and `swiftlint analyze` (CI's analyze job); the Homebrew release build passed.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: d4214f9da96112e732a4ce5f6ee0d315bc4e5f0e, 22e74d46276df2876d5e23ed72e3324d5fafa840, b259c57eed71a4547667cfc30c41dfaa8043a856
- Tests: cd app/MeetingTranscriber && swift build -j 6 --build-tests (build_rc=0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch home> swift test --skip-build --filter '<30 focused classes: record-only, recovery, orphan, ledger, sidecar, quit, PipelineController, PipelineQueue, WatchLoop, WatchingController>' (680 tests, 0 failures), ./scripts/lint.sh with SwiftFormat 0.63.0 and SwiftLint 0.65.1 (0 files to format, 0 violations), cd app/MeetingTranscriber && swift build -c release -j 6 (Homebrew variant, passed)
- PRs: