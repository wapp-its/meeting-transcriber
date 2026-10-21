---
satisfies: [R5, R6, R8]
---
# gh-97-delete-recordings-by-hand-and-after-a.3 Delete a meeting's files: the Trash mover, Keep and the window's actions

## Description
The part that removes files: a mover that sends a list of a meeting's files to the Trash (manual) or deletes them for good (automatic, used by task .6), one file at a time with a result per file, plus the window's backend actions Move Audio to Trash, Move Meeting to Trash, Retry Deletion and Keep. No view changes here (task .5); the actions are callable and tested on their own, so the manual slice is proven before any button exists.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/MeetingFileRemover.swift` (new), `app/MeetingTranscriber/Sources/MeetingFileStore.swift`, `app/MeetingTranscriber/Sources/MeetingFileRecord.swift`, `app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift`, `app/MeetingTranscriber/Sources/PipelineController.swift`, `app/MeetingTranscriber/Tests/MeetingFileRemoverTests.swift` (new), `app/MeetingTranscriber/Tests/PipelineControllerTranscriptionsTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/MeetingFileRemover.swift, app/MeetingTranscriber/Sources/MeetingFileStore.swift, app/MeetingTranscriber/Sources/MeetingFileRecord.swift, app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift, app/MeetingTranscriber/Sources/PipelineController.swift, app/MeetingTranscriber/Tests/MeetingFileRemoverTests.swift, app/MeetingTranscriber/Tests/PipelineControllerTranscriptionsTests.swift]

### Approach
- **Presence**: task .1's `MeetingFilePresence` and `FileIdentity`; never a plain `fileExists`, which cannot tell absence from a denied permission.
- **Pending deletion first** (spec "Pending deletion"): before touching any file, save `pending = PendingDeletion(kind: .audioToTrash | .meetingToTrash | .automatic, paths:, process:)` through the store and start only when that write returned true; `process` names this process (pid and launch time, as `LivenessMarker` identifies an instance) so another running build never treats it as abandoned. Clear `pending` when the action finishes, in the same write that records the outcome.
- **Mover**: `struct MeetingFileRemover` with injected `trash: (URL) throws -> Void` and `removeForGood: (URL) throws -> Void` (production: `FileManager.trashItem(at:resultingItemURL:)` and `removeItem(at:)`; the injection pattern of `ProtocolTemplates.swift:172-176`), and `func remove(_ files: [MeetingFile], mode: Mode, in store: MeetingFileStore, jobID: UUID) -> [FileOutcome]`. Per file: skip one already gone; an unreachable file fails with the reason that its drive or folder is not available; then check it is the same file (spec "Same file, right before removal": `lstat` says regular file, not a symbolic link or folder; its parent resolves to the recorded parent; device and inode match the recorded `identity`), and fail with "the file was replaced" if not; otherwise mark `.deleting` in the record, run the operation, mark `.gone`, or on a throw restore `.present` and fail with a reason (a Trash refusal reads "this volume has no Trash" or the error's text). **A refused Trash never falls back to `removeForGood`** (D6). `removeForGood` in production is `unlink(2)` on that one path, never `FileManager.removeItem`, which would empty a folder put in the file's place.
- **Shared paths**: a path that another record also lists is not removed and stays in this record, reported as blocked ("1 file is also listed by another meeting"); a retry removes it once no other record lists it (R1's error case). A recorded meeting whose audio was later imported as its own meeting is the realistic case: test both deletion orders.
- **Security scope**: run each action inside the scope of the configured output folder when `AppSettings.outputDirectoryResolution` is `.custom` (`AppSettings+OutputDirectory.swift:42`), never on `.fallback`, as `ProtocolRegeneration.swift:489-495` opens it on the resolved root through `SecurityScopeAccess` (`SecurityScopeAccess.swift:22`).
- **Launch reconcile**: at launch, a record whose `pending` names a process that is no longer running is reconciled: each covered file is re-probed (`.deleting` becomes `.present` or `.gone`); a manual kind then becomes `incomplete` with the same kind to retry (or completes, when nothing is left: for Move Meeting that removes the row and record as the action would have), and an automatic kind is cleared without `incomplete`, so the next check simply runs again. A crash between two files is covered the same way, since `pending` lists every file. A `pending` owned by a live process is left alone.
- **Actions** on `PipelineController` (`PipelineController+Transcriptions.swift`, beside `removeFailedJob`):
  - `moveAudioToTrash(jobID:)`: the audio roles that are owned and present; sets `audioDeletion = manual(at: now)` when all moved, else `incomplete` with the reason and the paths left (R5).
  - `moveMeetingToTrash(jobID:)`: every owned file; on full success removes the job from the queue if it is still listed, its `TerminalJobStore` entry and its record, so `GET /v1/jobs/<id>` answers 404 (A5); otherwise `incomplete`, and the row stays (R6, D7).
  - `retryDeletion(jobID:)`: repeats the kind stored in `incomplete` on the files still there; when none are left it completes as the original action would (R5, R6).
  - `setKeep(jobID:, _:)` (R8).
  - Each action refuses (returns false, changes nothing) when its pending write cannot be saved, while another deletion of the meeting is pending, for a meeting without a record (A2), a failed meeting (A3), and a live job that waits, runs or awaits speaker names (R4); `moveAudioToTrash` and `setKeep` refuse an import (A4). These guards repeat the menu's rule on purpose, so a stale menu cannot act on a meeting that changed state.
  - The clock is injected (`now: () -> Date`, as `RemoteVocabularyController.swift:62-63`).
- **Tests, written first**: `MeetingFileRemoverTests` in a temp folder with an injected `trash` (moves into a fake Trash folder, or throws): audio moved while transcript and protocol stay; a refusing Trash leaves the file, sets the reason, and never calls `removeForGood`; a missing parent folder is unreachable, not gone; a file the user removed counts as gone without a failure; a file replaced by another file, by a folder (with a file inside that must survive) or by a symbolic link, and a parent folder replaced by a symbolic link, are not removed and fail; a shared path stays and is removed by a retry once the other record is gone, in both deletion orders; a failed pending write starts nothing; a `pending` from a dead process left after the first of three files reconciles to `incomplete` with the same kind (manual) or clears (automatic), and a `pending` of a live process is left alone. `PipelineControllerTranscriptionsTests` also runs a recorded meeting through the queue, confirms its speaker names (and, in a second case, runs a late re-diarization), then moves the whole meeting to the Trash and expects it to complete with nothing reported as replaced. `PipelineControllerTranscriptionsTests`: Move Meeting removes the record, the finished-job entry (`lookup(jobID:)` is nil) and the queue job; an import's source file is not moved; Retry Deletion moves only the remaining file and then completes; each refusal case changes nothing; Keep survives a new store on the same file.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift` - `removeFailedJob`, the existing window actions
- `app/MeetingTranscriber/Sources/ProtocolTemplates.swift:160-190` - injected `trashItem` and its error handling
- `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift:480-500` - opening the output folder's scope
- `app/MeetingTranscriber/Sources/AppSettings+OutputDirectory.swift:30-80` - `outputDirectoryResolution`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/PipelineControllerTranscriptionsTests.swift` - controller setup with `IsolatedQueueEnvironment`
- `app/MeetingTranscriber/Tests/ProtocolTemplatesSettingsTests.swift:260-294` - asserting nothing was deleted

### Key context
- `trashItem` throws on volumes without a Trash (network shares, some external drives); that is the case D6 forbids turning into a permanent delete.
- `removeJob` on the queue marks the mix processed, so orphan recovery does not bring a moved meeting back; keep that call when removing the job.
## Acceptance
- [ ] Move Audio to Trash moves the meeting's owned audio files to the Trash, keeps transcript and protocol, and records the date; a file the Trash refuses or that is unreachable stays where it is, is never deleted for good, and the record holds the reason and the paths left (R5, D6).
- [ ] Move Meeting to Trash moves every owned file, never an imported source, then removes the queue job, the finished-job entry and the record, so the automation API answers 404 for it; a partial failure leaves the record marked incomplete (R6, A5, D7).
- [ ] Retry Deletion moves only the files still there and completes the action when none are left (R5, R6).
- [ ] Keep is stored in the record and survives a restart (R8).
- [ ] The actions change nothing for a meeting without a record, a failed meeting, a meeting that waits, runs or awaits speaker names, and (Move Audio, Keep) an import (R4, A2, A3, A4).
- [ ] A deletion saves its kind and files before touching any file and does nothing if that save fails; one interrupted by a quit or crash, also between two files, is reconciled at the next launch: a manual one shows as incomplete with a retry of the same kind, an automatic one is left to the next check (R1, spec "Pending deletion").
- [ ] A file is removed only while it is still the recorded regular file in the recorded folder; a replacement file, folder or symbolic link is never removed, and deleting for good never removes a folder's contents (R1, spec "Same file, right before removal").
- [ ] A meeting whose transcript the app rewrote on confirmed speaker names, or on a late re-diarization, moves to the Trash completely (R6).
- [ ] A path another record lists is never removed, stays listed, is reported as blocked, and is removed by a retry once no other record lists it (R1).
- [ ] `MeetingFileRemoverTests` and the new `PipelineControllerTranscriptionsTests` cases were written before the implementation and pass.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
