---
satisfies: [R1, R4]
---
# gh-60-cut-a-recovered-recording-back-after-a.2 Let the recorder store, hold and clear the pending cut beside its marker

## Description
The recorder owns the staging folder and the stem, so writing, updating and removing the stored cut go through it: three new `RecordingProvider` calls, implemented by `DualSourceRecorder` on top of task 1's `PendingRecordingCut`, with the process-wide hold kept in step. Split from the watch-loop wiring (task 3) so this seam is proven against the real recorder before the loop calls it. It comes after task 4 (the proof point) and uses task 4's recovery step in its sync-failure test. See spec Architecture (who writes and removes it, this process's hold, the resolved cut), R1, R4.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/RecordingProvider.swift`, `app/MeetingTranscriber/Sources/DualSourceRecorder.swift`, `app/MeetingTranscriber/Tests/MockRecorder.swift`, `app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/RecordingProvider.swift, app/MeetingTranscriber/Sources/DualSourceRecorder.swift, app/MeetingTranscriber/Tests/MockRecorder.swift, app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift]

### Approach
- `RecordingProvider` (`RecordingProvider.swift:6`): add `storePendingCut(cutAt:deadline:startedAt:) throws`, `recordPendingCutResolution(keptSeconds:captureEndedAt:) throws` and `clearPendingCut()` returning task 1's removal outcome. No-op defaults in the existing protocol extension (`RecordingProvider.swift:51`), the pattern the level and give-up properties use, so the other doubles need no change.
- `DualSourceRecorder`: `storePendingCut` first remembers the current recording's stem (`startTimestamp`, the marker's stem, `DualSourceRecorder.swift:424-431`) in its own property and holds it, THEN writes the record into `recordingsDir` (spec: a failed write may still have published its record, so the recorder must own it before writing). The remembered stem survives `stop()` (which nils `startTimestamp`, `:500-501`). A notPublished or publishedNotSynced outcome throws an error that carries which one it was (task 3 logs `published=`); the stem stays remembered and held in both cases. Not recording → throw `RecorderError.notRecording`, write nothing, remember nothing.
- Give `DualSourceRecorder.init` an injectable sync function, defaulting to task 1's production sync, and pass it to every `PendingRecordingCut` call; it is the seam the sync-failure test below uses.
- `recordPendingCutResolution` updates that record through `PendingRecordingCut.recordResolution`; nothing stored → no-op.
- `clearPendingCut` removes it (task 1's sequence, emptying fallback included) and releases the hold; nothing stored → quiet no-op that reports removed.
- `stop()` never removes the stored cut (the live cut has not run when it returns). When `stop()` throws while a cut is stored, release the hold and keep the file, so recovery owns it together with the surviving marker (`:515-523`). Task 3 clears a settled question's cut before calling `stop()`, so only a cut-carrying stop reaches this.
- `MockRecorder`: one ordered call log for start, store (with arguments), resolution (with arguments), clear and stop; let a test make each of store, resolution, clear and stop fail; and let a test run a closure inside `recordPendingCutResolution` (task 3 uses it to check the tracks are still uncut at that moment).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/DualSourceRecorder.swift:405-526` — start (stem, marker) and stop (marker removal after the mix)
- `app/MeetingTranscriber/Sources/RecordingProvider.swift` — protocol and default extension
- `app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift` — `FakeCaptureSession`, marker lifecycle assertions to mirror

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/MockRecorder.swift` — existing doubles and their defaults
- `app/MeetingTranscriber/Sources/RecoveredCut.swift` (task 4) — collect and apply, for the sync-failure → Keep → recovery test

### Key context
- The stored cut's stem must be the marker's stem: recovery matches them by name, and `crashedRecordingStems` keys on the same stem.
- `MockRecorder` is `@MainActor`; the hold set is not actor-isolated (recovery reads it detached), so call it synchronously from the recorder.
## Acceptance
- [ ] With a `FakeCaptureSession` recorder: `storePendingCut` during a recording writes a valid record beside the marker under the marker's stem, owner-only, and the stem is held.
- [ ] A second store in the same recording replaces the record whole.
- [ ] `recordPendingCutResolution` after `stop()` adds `keptSeconds` and `captureEndedAt` to the stored record; a second call does not change them.
- [ ] `clearPendingCut` after `stop()` removes the file and releases the hold; a clear with nothing stored is a no-op.
- [ ] `stop()` alone leaves the stored cut and the hold in place.
- [ ] A `stop()` that throws after a store leaves the file and the marker and releases the hold.
- [ ] `storePendingCut` while not recording throws and writes nothing.
- [ ] Sync failure → Keep → recovery: with the injected sync failing only on the folder sync, `storePendingCut` throws an error saying the record was published, the record is on disk and the stem is held; `clearPendingCut` (what Keep triggers) then removes it and releases the hold; a recovery pass over the recordings folder (task 4's collect and apply) applies nothing and leaves the tracks byte-identical.
- [ ] With the injected sync failing on the temp file, `storePendingCut` throws an error saying nothing was published, no record exists, and a later `clearPendingCut` is a quiet no-op that releases the hold.
- [ ] Existing recorder, crash-recovery and WatchLoop tests still pass unchanged (the defaults keep other doubles compiling); lint clean.
## Done summary
The recorder can now store, resolve and clear the meeting-end cut of the recording it is making, through three new `RecordingProvider` calls that `DualSourceRecorder` implements on top of `PendingRecordingCut`. It owns and holds the recording's stem before it writes, so a write that fails after publishing its record is still cleared later. A stop that throws hands the stored cut to recovery together with the surviving marker. Task 3 can now wire the watch loop to this seam, and `MockRecorder` gives it an ordered call log and a failure switch for each call.

stage: impl-review - ran [2026-10-09T01:58:08Z..2026-10-09T02:03:14Z] (codex gpt-5.6-sol xhigh per receipt; round 1 three draws correctness/contracts/integration, all SHIP with zero findings; finalized with --merged-file because --merge-plan could not parse the correctness draw, as on task .1; validator not run, it runs only on NEEDS_WORK)

Tier: session (jev-unavailable(no_key)); explicit invocation: opus at xhigh; actual model: claude-opus-5-5 (host metadata)

baseline: green via handoff (verified at 8f868a91 by task .4; only .flow/ changed since); lint 0 violations in 714 files before any edit

### Tests per acceptance criterion

All tests are in `app/MeetingTranscriber/Tests/DualSourceRecorderLifecycleTests.swift`, in the extension "Stored meeting-end cut". They use a real `DualSourceRecorder` with the existing `FakeCaptureSession`.

- Store beside the marker under its stem, 0600 and held, plus a second store that replaces the record whole: `testAStoreWritesTheCutBesideTheMarkerOwnerOnlyAndHoldsIt`
- `stop()` alone leaves the stored cut and its hold; the resolution after the stop adds `keptSeconds` and `captureEndedAt`, and a second call changes neither; the clear then removes the file and releases the hold: `testTheStoredCutOutlivesTheStopUntilItIsResolvedAndCleared`
- A clear with nothing stored is a no-op (between recordings and during one), and so is a resolution: `testAClearWithNothingStoredChangesNothing`
- A stop that throws after a store leaves the file and the marker and releases the hold, and a later clear no longer reaches the file: `testAStopThatThrowsAfterAStoreHandsTheStoredCutToRecovery`
- A store before the recording and after its stop throws `notRecording`, writes nothing and holds nothing: `testAStoreWhileNotRecordingThrowsAndWritesNothing`
- Sync failure, then Keep, then recovery: only the folder sync fails, the store throws `published=true`, the record is on disk and held, and the clear removes it (`removedNotSynced`) and releases the hold. `PipelineController.recoverStagingFolder` (task 4's collect, re-mix and apply) then logs nothing and leaves the mic track byte-identical, and the re-mixed mix is the full 2 s: `testAStoreThatPublishedWithoutItsFolderSyncIsClearedByKeepAndRecoveryAppliesNothing`
- File sync failure: the store throws `published=false`, no record or temporary file exists, the stem is held, the resolution is a no-op, and the clear reports `removed` and releases the hold: `testAStoreWhoseFileSyncFailedPublishesNothingAndItsClearOnlyReleasesTheHold`

Mutation-checked: each of these edits turns a test red. Clear not removing, hold taken after the write, a failed stop keeping the hold, a failed stop keeping the stem, the resolution throwing on "no record", and clear not releasing the hold.

Verification on the final tree (4ab0a4d9):
- `swift test --parallel --filter 'DualSourceRecorder|WatchLoop|RecordOnly|PendingRecordingCut|RecoveredCut|StagedRecovery|RecordingCut'`: 282 tests ran and 277 passed. The 5 failures are the known environmental `WatchLoopE2ETests` (`modelNotLoaded`: no WhisperKit model under the redirected home); CI is their gate. The spec's own Quick filter is a subset of this run, and none of its tests failed.
- `swift test --parallel --filter DualSourceRecorderLifecycleTests`: 19 of 19 passed (12 existing, 7 new).
- `./scripts/lint.sh` with the pinned tools: 0 violations in 714 files.

### Decisions

- **Error type:** a dedicated `PendingCutWriteError { published: Bool, underlying: any Error }` in `RecordingProvider.swift`, thrown by both store and resolution. Task 3 logs the underlying error's domain and code with `published=`. The alternative was a new `RecorderError` case, whose NSError domain and code would name the enum and not the file error. Flip at `RecordingProvider.swift`.
- **Nothing stored, for the resolution:** this covers no store in this recording, and also a store that published nothing (`ResolutionError.noRecord`). Either way it is a quiet no-op, because the store's own failure was already reported and recovery has no record to apply. An invalid record on disk still throws (`published=false`). Flip at `DualSourceRecorder.recordPendingCutResolution`.
- **Clear releases the hold and forgets the stem whatever the removal ended in.** This matches the task text. An emptied file is then recovery's to refuse, and a file that is still intact because emptying failed too is covered by spec A6's deadline check. The alternative was to keep the hold after a `failed` removal so that a later clear retries. Flip at `DualSourceRecorder.clearPendingCut`.
- **A stop that throws releases the hold and also forgets the stem**, so a stray later clear or resolution cannot touch a cut that recovery now owns. Only the stop of a live recording does this. A `notRecording` throw from a second `stop()` leaves the first stop's cut held. Flip at `DualSourceRecorder.stop`.
- **The sync seam** is `DualSourceRecorder.init(recordingsDir:makeCaptureSession:pendingCutSync:)`, placed last so the existing trailing-closure calls still bind to `makeCaptureSession`. Its default wraps `PendingRecordingCut.fullSync` in a closure, like the factory default in the same init.
- **MockRecorder:** one `calls: [Call]` log of start, `storePendingCut(cutAt:deadline:startedAt:)`, `recordPendingCutResolution(keptSeconds:captureEndedAt:)`, clear and stop. There are failure switches `storePendingCutError`, `recordPendingCutResolutionError` and `clearPendingCutOutcome`, and a `duringPendingCutResolution` hook that runs before the resolution returns or throws. A failing `stop()` stays the existing `mixPath = nil` (it throws `noAudioData`) rather than gaining a second switch for the same thing. Flip at `MockRecorder.swift`.
- **`file_length` suppressed** at the top of `DualSourceRecorder.swift`, which was at 593 lines before this task and is 676 now. Upstream did the same in `PipelineQueue.swift`, `AppSettings.swift` and `SpeakerNamingView.swift`, most recently in e0147b5a. A split into `DualSourceRecorder+PendingCut.swift` is outside this task's Touches and would have to widen the recorder's private stem, folder and sync to internal. Flip by moving the "Stored meeting-end cut" section into such a file.
- `stop()` now wraps its body, moved unchanged into `private func finishRecording()`, so every throw path releases the stored cut in one place.

### Follow-ups noticed, not fixed

- `DualSourceRecorder.swift` is past SwiftLint's 600-line warning. Moving the stored-cut section (or `crashedRecordingStems` / `recoverCrashedRecording`, which are static anyway) into an extension file would let the suppression go.
- A reused `DualSourceRecorder` (the watch loop makes a fresh one per meeting) keeps a stem that a successful stop never cleared until its next store. The next recording's store then replaces it and leaves the old stem held. That cannot happen while task 3 clears on every end, and nothing reuses a recorder today.
- No user route to a mapped feature changed.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 4ab0a4d97821bbb61066e624b1c81b433bd5eb00
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh60-home swift test --parallel --filter 'DualSourceRecorder|WatchLoop|RecordOnly|PendingRecordingCut|RecoveredCut|StagedRecovery|RecordingCut' (282 run, 277 passed; 5 WatchLoopE2ETests environmental: modelNotLoaded, no WhisperKit model under the redirected home), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh60-home swift test --parallel --filter DualSourceRecorderLifecycleTests (19/19 passed), PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh (0 violations in 714 files)
- PRs: