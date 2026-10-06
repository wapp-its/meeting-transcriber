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
- `DualSourceRecorder`: `storePendingCut` first remembers the current recording's stem (`startTimestamp`, the marker's stem, `DualSourceRecorder.swift:415-421`) in its own property and holds it, THEN writes the record into `recordingsDir` (spec: a failed write may still have published its record, so the recorder must own it before writing). The remembered stem survives `stop()` (which nils `startTimestamp`, `:490-491`). A notPublished or publishedNotSynced outcome throws an error that carries which one it was (task 3 logs `published=`); the stem stays remembered and held in both cases. Not recording → throw `RecorderError.notRecording`, write nothing, remember nothing.
- Give `DualSourceRecorder.init` an injectable sync function, defaulting to task 1's production sync, and pass it to every `PendingRecordingCut` call; it is the seam the sync-failure test below uses.
- `recordPendingCutResolution` updates that record through `PendingRecordingCut.recordResolution`; nothing stored → no-op.
- `clearPendingCut` removes it (task 1's sequence, emptying fallback included) and releases the hold; nothing stored → quiet no-op that reports removed.
- `stop()` never removes the stored cut (the live cut has not run when it returns). When `stop()` throws while a cut is stored, release the hold and keep the file, so recovery owns it together with the surviving marker (`:505-512`). Task 3 clears a settled question's cut before calling `stop()`, so only a cut-carrying stop reaches this.
- `MockRecorder`: one ordered call log for start, store (with arguments), resolution (with arguments), clear and stop; let a test make each of store, resolution, clear and stop fail; and let a test run a closure inside `recordPendingCutResolution` (task 3 uses it to check the tracks are still uncut at that moment).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/DualSourceRecorder.swift:395-514` — start (stem, marker) and stop (marker removal after the mix)
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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
