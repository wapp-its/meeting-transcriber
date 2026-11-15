---
satisfies: [R5, R11]
---
# gh-171-transcribe-again-and-identify-speakers.4 Swap in a re-run's transcript and notes and keep the earlier ones beside them

## Description
Fills task 2's success hook (R5, A7, A8, A12, A15, A6): the pure earlier-version name, the swap in the order Architecture gives with the record update as the commit point, its undo and its launch completion, the finished-job entry and the Notion export after it, and the docs.

**Size:** M
**Files:** a new `app/MeetingTranscriber/Sources/EarlierVersionName.swift`, a new `app/MeetingTranscriber/Sources/PipelineQueue+RerunSwap.swift`, `app/MeetingTranscriber/Sources/MeetingFileStore.swift`, `app/MeetingTranscriber/Sources/MeetingFileRecord+Rerun.swift`, `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift` (share the stamp), `app/MeetingTranscriber/Sources/PipelineQueue+Notion.swift`, `app/MeetingTranscriber/Sources/TerminalJobStore.swift`, `app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift`, `docs/architecture/pipeline.md`, `docs/automation-api.md`, tests
**Touches:** [app/MeetingTranscriber/Sources/EarlierVersionName.swift, app/MeetingTranscriber/Sources/PipelineQueue*.swift, app/MeetingTranscriber/Sources/MeetingFileStore.swift, app/MeetingTranscriber/Sources/MeetingFileRecord*.swift, app/MeetingTranscriber/Sources/ProtocolRegeneration.swift, app/MeetingTranscriber/Sources/DateFormatter+FilenameStamp.swift, app/MeetingTranscriber/Sources/PipelineController*.swift, app/MeetingTranscriber/Sources/TerminalJobStore.swift, app/MeetingTranscriber/Sources/NotionClient.swift, docs/architecture/pipeline.md, docs/automation-api.md, app/MeetingTranscriber/Tests/*Rerun*.swift, app/MeetingTranscriber/Tests/EarlierVersionNameTests.swift]

### Approach
- Name: `<name>.until-<yyyyMMdd_HHmmss>.<ext>` with `-2`, `-3`, … after the stamp. Reuse the stamp formatter Regenerate uses (`ProtocolRegeneration.swift:180`, `DateFormatter.filenameStamp`); the taken check asks the disk and folds case, as `ArtifactRenamePlan.availableStem` (47-59) and `MeetingReportFolder` do; past a fixed upper bound the re-run ends as R6.
- Order: write the list of renames into the record's marker; rename the current transcript and notes to their earlier names; rename the re-run's files to the current names (a meeting renamed to its AI title keeps that name) with a move that never replaces a file, so a name taken meanwhile (Generate Meeting Notes from Transcript writes `<stem>.md` beside a transcript without notes, `PipelineQueue.enqueueNotes(fromTranscripts:)`) fails the step and the swap is undone; a meeting without current notes (they failed, or no provider made any) gets no earlier notes, and the new notes take the name the meeting's notes have by its current transcript's stem; then one record update lists the new files as present with their current identity, appends both earlier versions as owned `previousProtocol` (`appendKept`), clears the marker, notes the stamp as committed and sets the outcome to finished. Then upsert the finished-job entry (it moves last, so Last Recording shows the meeting); `TerminalJobStore.record` returns whether its save landed (`TerminalJobStore.swift:51-90`, discardable for today's callers). Once it did, the job turns into an ordinary finished job, with its transcript, notes and stem (`namingSlug`) set to the current names, which a later Retry Notion Export, Retry Meeting Notes and the held-job cleanup read, and leaves the re-run file; then the Notion export runs as for a new meeting. The re-run's notes were saved under its own stem by `saveGeneratedNotes` (`PipelineQueue+Stages.swift:1228-1268`), which also queued the pending export with its configuration; it starts only now (`startPendingNotionExport`). A failed export does not undo anything. A taken-over entry held for failed notes ends held only when the re-run made no notes (A12): then its notes failure stays, and Retry Meeting Notes reads the new transcript.
- Notion (A26): the export goes to the database the record names for the page. Resolve the configuration with that database in place of Settings' (`NotionExportConfiguration.resolve`, `PipelineQueue+Notion.swift:8-40`; for a re-run, where `saveGeneratedNotes` calls `resolveNotionExport`), so `notionPageToReuse` (186-191) finds the page and the client builds properties from that database's schema (`NotionClient.exportMeeting`, `NotionClient.swift:235-270`); a record without the database uses the configured one (A6). The finished job keeps a field saying its exports go to its page's database, so a later Retry Notion Export of a failed re-run export goes there too.
- Undo: a failed rename undoes the steps done, the pattern of `undoRenames` (`PipelineQueue+Stages.swift:1342`), then task 3's end path. Every rename, of the current files and of the re-run's, passes task 3's file check first.
- Launch, the Architecture table's two remaining rows beside task 3's: a marker with a list of renames is completed when every re-run file it names is there, else undone from the list; a stamp noted as committed while the job is still in the re-run file is handled when the queue restores that file: write the finished-job entry again, turn the job into an ordinary finished job and, with the export on, start its export once from the saved notes through the path `retryNotionExport` takes (`PipelineQueue+Notion.swift:345-400`). The launch's handling of interrupted exports (`recoverInterruptedNotionExports`, and `PipelineQueue+Recovery.swift:57,169`, which only record finished-job history) marks exports failed for a manual retry and starts none, so it does not cover this.
- The swap waits while a regeneration runs (as Move Meeting to Trash does; the queue gets that state injected).
- Notes off (A12): only the transcript is swapped and the current notes stay. Additional reports are not touched (A7).
- Docs: `docs/architecture/pipeline.md` gets the re-run, its marker and the swap; `docs/automation-api.md` says a done job can be live again and what `GET /v1/jobs/<id>` answers during, after and instead of a re-run.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift:175-185,440-480`
- `app/MeetingTranscriber/Sources/ArtifactRenamePlan.swift:25-60`
- `app/MeetingTranscriber/Sources/MeetingFileStore.swift:136-165,313-435`
- `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift:1160-1268,1342-1420`
- `app/MeetingTranscriber/Sources/TrashConfirmationText.swift:60-76`
**Optional:**
- `app/MeetingTranscriber/Sources/AdditionalReport.swift:40-181`
- `app/MeetingTranscriber/Tests/ProtocolRegenerationMeetingFilesTests.swift`

### Key context
- `MeetingFileRecord.list` replaces only the entry with the same path, and the Trash remover checks file identity: list the new files with the identity they have after the rename (memory: a record assumed what a write did).
- Fold case to refuse a taken name, compare exactly to claim one (memory: file-name ownership).
- `ArtifactRenamePlan.artifactURLs` is a closed list that does not know `.until-` files; with no AI-title rename in a re-run (A8) that is fine.
## Acceptance
- [ ] Name tests: the stamp format, `-2` and `-3` for a taken name and for a case variant of one, no name ending in `)` or holding ` (` (gh-190's rule claims none), the upper bound ending the re-run as R6.
- [ ] At success the earlier transcript and notes keep their bytes under their earlier-version names, the re-run's files hold the current names, the record lists the new files as present and both earlier versions as owned; Move Meeting to Trash afterwards moves all of them and its confirmation counts them; additional reports are byte for byte.
- [ ] Open Notes, Open Transcript, Last Recording and `jobStatus(forID:)` show the new result, and the row keeps its place in the list.
- [ ] With the Notion export on, the stub exporter sees one update of the existing page and no create, also when Settings name another database than the record (the export goes to the record's); a failed export leaves the swapped files and offers Retry Notion Export.
- [ ] A cold start (`activate`, then the first queue built) after a stop right after the commit point writes the finished-job entry, calls the stub exporter once with an update of the recorded page and leaves no re-run job in the file; a Retry Notion Export after a failed re-run export updates the page in the record's database; a finished-job write that fails keeps the job in the re-run file until a later write lands.
- [ ] A current transcript or notes file replaced at its path before the swap is not renamed, and the re-run ends as R6; so does a notes file that appeared at the current notes name of a meeting without notes, which stays byte for byte.
- [ ] A rename failing at each step undoes the earlier steps and ends as R6; a launch after a stop at each step completes or undoes the swap, and the meeting always has a current transcript under its current name.
- [ ] With notes off only the transcript is swapped; a meeting without current notes gets the new notes under its notes name and no earlier notes; a meeting with its AI title keeps it and its earlier versions carry it.
- [ ] `docs/architecture/pipeline.md` and `docs/automation-api.md` describe the re-run, the swap and the readback.
- [ ] The Quick commands' focused tests and `./scripts/lint.sh` pass.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
