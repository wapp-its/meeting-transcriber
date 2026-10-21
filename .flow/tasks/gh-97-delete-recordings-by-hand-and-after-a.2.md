---
satisfies: [R1, R13]
---
# gh-97-delete-recordings-by-hand-and-after-a.2 Meeting file record: imports, recovery, retry, cancel, naming files, Regenerate Protocol and the segments permission

## Description
Completes the record of task .1 for every other way a meeting enters, leaves or changes: imports, orphan recovery, retry, cancel, dismiss and remove, the naming files that come and go, the raw transcript removal, and Regenerate Protocol. Also R13: the segments file is written owner-only. Split from task .1 so the proof point stays small; these are many small hooks at known choke points.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/PipelineQueue.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift`, `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift`, `app/MeetingTranscriber/Sources/SpeakerNamingSession+Late.swift`, `app/MeetingTranscriber/Sources/SpeakerNamingStore.swift`, `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift`, `app/MeetingTranscriber/Sources/AppState.swift`, `app/MeetingTranscriber/Sources/MeetingFileStore.swift`, `app/MeetingTranscriber/Tests/PipelineQueueMeetingFilesTests.swift`, `app/MeetingTranscriber/Tests/ProtocolRegenerationMeetingFilesTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/PipelineQueue.swift, app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift, app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift, app/MeetingTranscriber/Sources/SpeakerNamingSession.swift, app/MeetingTranscriber/Sources/SpeakerNamingSession+Late.swift, app/MeetingTranscriber/Sources/SpeakerNamingStore.swift, app/MeetingTranscriber/Sources/ProtocolRegeneration.swift, app/MeetingTranscriber/Sources/MeetingFileStore.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Tests/PipelineQueueMeetingFilesTests.swift, app/MeetingTranscriber/Tests/ProtocolRegenerationMeetingFilesTests.swift]

### Approach
- **Orphan recovery** (`PipelineQueue+Recovery.swift:441`, the job is appended at `:505` without `enqueue`): create the record there as `.recorded` (orphans are only scanned in the staging folder, which only the recorder writes); its recording date falls back to `enqueuedAt` by task .1's rule (A6). Recovery also admits staging recordings left from before an upgrade, so compare the audio file's creation date with the store's `since`: when it is earlier, set `excludedFromAutomaticDeletion` (spec "Recordings from before this feature", D9). The manual actions still apply to it.
- **Outcome changes**:
  - `cancelJob` (`PipelineQueue.swift:656`) on a job that is not terminal: `.leftUnfinished`.
  - `removeJob` (`PipelineQueue.swift:621`): `.leftUnfinished` only while the outcome is still `.inProgress`. The queue also calls `removeJob` to reap a finished job after `completedJobLifetime` (`:747-751`), and that must keep `.finished`; a failed job removed through `removeFailedJob` (`PipelineController+Transcriptions.swift:40`) stays `.failed`.
  - `retryJob` (`PipelineQueue+Recovery.swift:377`): back to `.inProgress`, same record, recording date and Keep unchanged, `incomplete` and `audioDeletion` untouched.
- **Rewrites of listed files** (task .1's `noteWritten` helper, so the stored identity follows each atomic replace): the transcript rewritten when speaker names are confirmed (`SpeakerNamingSession+Late.swift:74`) and by a late re-diarization (`SpeakerNamingSession+Late.swift:394`, reached through `rewriteTranscriptFromLateRun` at `:213`); `_naming.json` on every save (`SpeakerNamingStore.swift:86`), not only the first. The writers task .1 already covers are the transcript draft and final transcript (`PipelineQueue+Stages.swift:141`, `:856`), the segments file (`:897`) and the protocol (`:978`); Regenerate Protocol is below. Report these through the same session callback as the naming files.
- **Naming files**: list `_naming.json` when `saveNamingData` writes it (`SpeakerNamingSession.swift:396`, also reached from `:343` and `SpeakerNamingSession+Late.swift:204`); after `removeNamingData` (`SpeakerNamingSession.swift:460`, which runs `cleanupSidecarFiles`, `SpeakerNamingStore.swift:145`) mark the naming file, the 16 kHz copies and the segments file gone where the file is gone. The session and the naming store are keyed by slug and know nothing of records, so do not thread the record store into them: give the session one callback (`onNamingFilesChanged: (UUID) -> Void` or similar) the queue wires, and let the queue re-check those roles for that job. `cleanupStalePending` (`SpeakerNamingSession.swift:544`) and the late paths reach the same removal, so the callback covers them.
- **Raw transcript removal**: `removeRawTranscriptArtifactsIfSafe` (`PipelineQueue.swift:~765-800`) deletes the `.txt` and the segments when "save raw transcript separately" is off; mark both gone.
- **Regenerate Protocol** (`ProtocolRegeneration.swift:440`, `replaceProtocol`): when its target carries a `jobID` (`:108`), report the new protocol URL and, if the Trash refused the old one and it was kept as `.previous-<stamp>.md`, that kept file, through a closure added to `ProtocolRegenerator.Environment` and wired to the record store in `AppState.makeProtocolRegenerator` (`AppState.swift:152-195`). The record lists the protocol with its new identity (also for a meeting that had none) and the kept previous copy as owned `.previousProtocol`, so Move Meeting to Trash takes it too. A target without a `jobID` (a file chosen by hand) changes no record.
- **R13**: after the atomic write of `_segments.json` (`PipelineQueue+Stages.swift:895-897`) call `FileManager.restrictToOwner` (`FileManager+OwnerOnly.swift`), best effort like the write itself. Older segments files are not touched.
- **Gone versus unreachable**: whenever a hook marks a file gone, ask task .1's `MeetingFilePresence`; only `.gone` marks it gone.
- **Tests, written first**, extending `PipelineQueueMeetingFilesTests`: an import enqueued through `PipelineController.enqueueFiles` records origin imported, its source not owned and no recording date, also for a source file placed inside `<output>/recordings`; an orphan recording gets a record with recording date `enqueuedAt`; an orphan whose audio file was created before the store's `since` (the upgrade-after-crash case) is excluded from automatic deletion, one created after it is not; cancel of a waiting job gives `.leftUnfinished`; the reaper's `removeJob` after done keeps `.finished`; dismissing a naming-pending job gives `.leftUnfinished` and marks the naming files gone; retry returns `.inProgress` with the recording date unchanged; with "save raw transcript separately" off the transcript and segments are gone after done; the segments file has permissions 0600; after speaker names are confirmed, and after a late re-diarization, the record's transcript identity equals the identity of the file now on disk, and so does the naming file's after a second save. `ProtocolRegenerationMeetingFilesTests`: regenerating for a job id updates the protocol path, a refused Trash adds the kept previous copy, and a hand-picked file changes no record.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/PipelineQueue.swift:621-690` - `removeJob`, `cancelJob`
- `app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift:377-400` and `:441-510` - retry and orphan recovery
- `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift:380-470` - saving and removing naming data
- `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift:400-500` - `replaceProtocol`, `withOutputScope`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/SpeakerNamingStore.swift:40-60`, `:140-167` - sidecar suffixes and cleanup
- `app/MeetingTranscriber/Sources/PipelineController.swift:400-480` - the import entry points

### Key context
- Dismiss already deletes the 16 kHz copies and the segments; the record must follow that, not assume they exist.
- A paired import without a `_mix.wav` mixes into the temporary work folder, which is never persisted: list only files that exist at their recorded path.
## Acceptance
- [ ] An imported file gets a record with origin imported, its source not owned (also inside the recordings subfolder) and no recording date; a recovered orphan gets a record with the time it entered processing as its recording date, and one whose audio predates this feature is excluded from automatic deletion (R1, A6, D9).
- [ ] Cancel, dismiss and remove of an unfinished job give the outcome "left unfinished"; the queue's reaping of a finished job keeps "finished"; Retry returns "in progress" without changing the recording date or the Keep mark (R1, spec "Meeting outcome").
- [ ] The record lists the naming file while it exists and marks the naming file, 16 kHz copies, segments and (with the raw transcript option off) the transcript gone once the pipeline removed them (R1).
- [ ] Every app rewrite of a listed file (transcript on confirmed names and on a late re-diarization, each save of the naming file, the protocol) updates the file's recorded identity, so the app never later refuses its own file as replaced (R1, spec "Same file, right before removal").
- [ ] Regenerate Protocol for a meeting updates its protocol path and lists a previous protocol the Trash refused; a hand-picked file changes no record (R1).
- [ ] The segments file is written with permissions 0600; older segments files keep theirs (R13).
- [ ] The new tests were written before the implementation and pass; the spec's quick command stays green.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
