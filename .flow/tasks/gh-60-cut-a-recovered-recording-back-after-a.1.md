---
satisfies: [R1, R3]
---
# gh-60-cut-a-recovered-recording-back-after-a.1 Stored meeting-end cut: record, durable write and removal, process hold

## Description
The stored cut itself: its record, its durable write, update, read and removal, and the process-wide hold set. Everything else in this spec (recovery in task 4, the recorder in task 2, the watch loop in task 3) builds on this type, so it comes first and is proven on its own with real files. See spec Architecture & Data Models (record shape, durability, this process's hold), R1, R3.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/PendingRecordingCut.swift` (new), `app/MeetingTranscriber/Sources/RecordingFileSuffix.swift`, `app/MeetingTranscriber/Tests/PendingRecordingCutTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/PendingRecordingCut.swift, app/MeetingTranscriber/Sources/RecordingFileSuffix.swift, app/MeetingTranscriber/Tests/PendingRecordingCutTests.swift]

### Approach
- `RecordingFileSuffix`: add the stored-cut suffix (e.g. `_pending_cut.json`) beside `inProgress`, with a doc comment saying it is neither a crash signal (crash detection stays on the marker and the raw temp, `RecordingFileSuffix.swift:9-22`) nor a track.
- `PendingRecordingCut`: `Codable` value type with exactly the spec's seven fields (`captureEndedAt`, `keptSeconds` optional), `nonisolated` static helpers in the style of `DualSourceRecorder.inProgressMarker(stem:in:)` (`DualSourceRecorder.swift:276`): `url(stem:in:)`, `write(_:in:)`, `read(stem:in:)` → absent / valid(record) / invalid(reason: unreadable, empty, unknownVersion, otherRecording, timesOutOfOrder), `recordResolution(stem:in:keptSeconds:captureEndedAt:)` (read-modify-write that sets each field only when it is absent; a present value is never changed), and `remove(stem:in:)`.
- Durable sequence (spec, "Every change to it is durable"): write = encode → hidden temp sibling in the same folder, owner-only before it holds data (`FileManager.restrictToOwner`, `FileManager+OwnerOnly.swift:22`) → full sync of the temp's descriptor → POSIX rename over the target (`RecordingCut.rename`, `RecordingCut.swift:161`) → sync the folder's descriptor. Removal = unlink → sync the folder; if the unlink fails, truncate the file to zero bytes and fully sync it, and report both. A write reports one of three outcomes (spec, "Every change to it is durable"): written; notPublished(error) for any failure before the rename (the target is untouched and the temp removed); publishedNotSynced(error) when only the folder sync after the rename failed (the target holds the new record). `recordResolution` reports the same three. A removal reports removed / removedNotSynced(error) / emptied(unlink error) / failed(both errors), so tasks 2 and 3 can log `published=` and `emptied=`.
- The sync is one injectable function `(Int32) throws -> Void` with a production default of `fcntl(fd, F_FULLFSYNC)`, falling back to `fsync` when the file system does not support `F_FULLFSYNC` (the SQLite approach). Tests inject a recorder of calls and a failing variant.
- Hold set: `hold(_:)`, `release(_:)`, `isHeld(_:)` over a lock-protected `Set<String>` (recovery reads it off the main actor, so not actor-isolated), plus a test-only reset.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/RecordingFileSuffix.swift` — suffix constants and the crash-signal rule
- `app/MeetingTranscriber/Sources/RecordingCut.swift:159-165` — POSIX rename helper
- `app/MeetingTranscriber/Sources/ProcessedRecordingsLedger.swift:44-60` — small owner-only JSON file pattern
- `app/MeetingTranscriber/Sources/FileManager+OwnerOnly.swift` — owner-only helper

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/LivenessMarker.swift` — injectable URL for tests, atomic write

### Key context
- `Data.write(options: .atomic)` renames but does not sync the file or the folder; the spec requires both, which is why this type owns its sequence.
- Dates: encode them so a round trip is exact to the millisecond or better (`keptSeconds` and the deadline check compare them).
## Acceptance
- [ ] A record round-trips through write and read with every field (optional ones present and absent); the file is owner-only (0600); a second write replaces the first whole.
- [ ] Read reports absent for no file, and invalid with the right reason for an empty file, undecodable bytes, an unknown version, a stem that differs from the file name, `cutAt` outside `startedAt…deadline`, and a non-positive `keptSeconds`.
- [ ] `recordResolution` sets `keptSeconds` and `captureEndedAt` when absent and never changes a value already present.
- [ ] Ordering is pinned with an injected sync: when the first sync fires the target still holds the old record (or nothing), when the folder sync fires it holds the new one.
- [ ] A sync failing on the temp file reports notPublished, leaves the target as it was and no temp behind; a sync failing only on the folder reports publishedNotSynced and the target reads back as the new record.
- [ ] Removal unlinks and syncs the folder (a failing folder sync reports removedNotSynced); with the folder made read-only (so the unlink fails) it empties the file instead, reports `emptied`, and the emptied file reads as invalid.
- [ ] Hold, release and isHeld behave as a set and are safe to call from several threads (concurrent test).
- [ ] Focused tests pass (spec Quick commands); lint clean.
## Done summary
The recorder and the launch recovery now have a stored meeting-end cut to build on. `PendingRecordingCut` writes, updates, reads and removes one owner-only `<stem>_pending_cut.json` per recording in the staging folder, syncs every change so it survives a power loss as well as a process death, and keeps a process-wide hold set so recovery can leave alone a cut that a live stop of this process still owns.

stage: impl-review - ran [2026-10-09T00:21Z..2026-10-09T00:26:42Z] (codex gpt-5.6-sol xhigh per receipt, three draws correctness/contracts/integration, all SHIP with zero findings; finalized with --merged-file because the integration draw carried no findings container)

Tier: session (jev-unavailable(no_key)); explicit invocation: opus at xhigh; actual model: claude-opus-5-5 (host metadata)

baseline: green (spec focused filter 100/100 tests, lint 0 violations, before any edit)

### Tests per acceptance criterion

All in `app/MeetingTranscriber/Tests/PendingRecordingCutTests.swift`.

- Round trip with every field, 0600, second write replaces the first whole: `testARecordRoundTripsExactlyAndASecondWriteReplacesTheFirstWhole` (also pins the stored key set to the seven contract fields).
- Read reports absent and each invalid reason: `testAReadRefusesEveryFileThatMustNeverBeApplied` (empty, undecodable, unknown version, other stem, cut before start, cut after deadline, zero and negative keptSeconds).
- `recordResolution` sets only absent values: `testRecordResolutionSetsOnlyWhatIsAbsentAndNeverChangesAPresentValue` (also the no-record case).
- Sync ordering: `testTheFileIsSyncedBeforeTheRenameAndTheFolderAfterIt` (with and without a previous record).
- Sync failing on the file: `testASyncFailingOnTheFilePublishesNothingAndLeavesNoTemporaryFile`. Sync failing only on the folder: `testASyncFailingOnlyOnTheFolderStillPublishesTheNewRecord`.
- Removal and removedNotSynced: `testRemovalUnlinksAndThenSyncsTheFolder`. Read-only folder empties the file, reads as invalid, and `failed` when emptying fails too: `testARemovalThatCannotUnlinkEmptiesTheFileInstead`.
- Hold set semantics and concurrency: `testHoldReleaseAndIsHeldBehaveAsASet`, `testHoldsAreSafeFromSeveralThreads` (4000 concurrent hold/isHeld/release calls).

### Decisions

- Stored-cut suffix is `_pending_cut.json` (`RecordingFileSuffix.pendingCut`). Nothing in the code argues against it, since no staging scan matches `.json` and the orphan scan takes only paired track groups. Flip at `RecordingFileSuffix.swift`.
- Dates use `JSONEncoder`'s default encoding (a Double of seconds since 2001), the same as `PipelineSnapshot` persists `PipelineJob` dates, which round-trips a `Date` bit for bit. The alternative `.iso8601` used by `RecordingSidecar` drops fractional seconds, and ISO 8601 with fractional seconds keeps only milliseconds. Flip at `PendingRecordingCut.write`/`read` (encoder and decoder construction).
- The hold set lives as static state on `PendingRecordingCut` behind an `OSAllocatedUnfairLock<Set<String>>`, beside the file helpers it guards. The alternative is an injected instance shared by the recorder and recovery, which tasks 2 to 4 could switch to if their tests need isolated hold sets. Flip at the `holds` property.
- The `F_FULLFSYNC` to `fsync` fallback runs only for errno `ENOTSUP`, `EOPNOTSUPP`, `ENOTTY`, `EINVAL` or `ENOSYS`; any other error is thrown, and `EINTR` is retried. SQLite falls back on any failure, which could hide an I/O error behind an `fsync` that reports success. Flip at `PendingRecordingCut.fullSyncUnsupported`.
- A non-positive `keptSeconds` reads as its own reason `nonPositiveKeptSeconds`. The task's list named five reasons, and the acceptance criterion asks for the right reason for this sixth case. Task 4 maps reasons to its log wording. Flip at `InvalidReason`.
- Each write uses a new hidden temporary file `.<stem>_pending_cut.json.<UUID>.writing`, created with `O_EXCL`, so two writes never share one and nothing is written through an existing file or link. A fixed name would bound leftovers to one per stem but lets two concurrent writes corrupt each other. Flip at `PendingRecordingCut.write`.
- A removal that finds no file counts as removed and still syncs the folder, so a removal retried after `removedNotSynced` becomes durable. Flip at `PendingRecordingCut.remove`.
- `write` does not validate the record; validity is defined at read, as the spec states it. `recordResolution` always rewrites the merged record, so `written` means durably written now, and returns `notPublished(ResolutionError.noRecord / .invalidRecord)` when there is no valid record to update.

### Follow-ups noticed, not fixed

- A process death between creating the temporary file and the rename leaves a hidden `.writing` file in the staging folder that nothing sweeps. The window is the length of one file sync. Task 4's recovery pass is the natural place to remove such leftovers.
- The `F_FULLFSYNC` fallback branch has no test. The test volume is APFS, which supports `F_FULLFSYNC`, and the syscalls are not injectable.
- Task 4 needs a helper that strips `_pending_cut.json` from a file name for its directory scan. It is not added here because no code in this task scans for stored cuts.
- No user route to a mapped feature changed.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: d2db03e16cd4206f96c5c75e9987f7040002cd52
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh60-home swift test --parallel --filter 'PendingRecordingCut|RecoveredCut|DualSourceRecorder|WatchLoopMeetingEnd|StagedRecovery|RecordingCut' (exit 0, 110/110 tests incl. 10 new PendingRecordingCutTests), PATH=$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH ./scripts/lint.sh (exit 0, 0 violations in 712 files)
- PRs: