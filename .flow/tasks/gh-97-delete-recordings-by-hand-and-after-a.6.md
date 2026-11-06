---
satisfies: [R11, R12, R14]
---
# gh-97-delete-recordings-by-hand-and-after-a.6 Automatic deletion: the check and when it runs

## Description
The automatic deletion: a controller that runs task .4's rule over every record and deletes what it returns for good through task .3's mover, at launch, after each finished meeting, once a day, and on request after a setting change. It runs headless, so it can ship and be tested before the Settings section (task .7) exists; with the setting at its default Never it deletes nothing.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/RecordingRetentionController.swift` (new), `app/MeetingTranscriber/Sources/AppState.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/PipelineController.swift`, `app/MeetingTranscriber/Sources/MeetingFileStore.swift`, `app/MeetingTranscriber/Tests/RecordingRetentionControllerTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/RecordingRetentionController.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/PipelineController.swift, app/MeetingTranscriber/Sources/MeetingFileStore.swift, app/MeetingTranscriber/Tests/RecordingRetentionControllerTests.swift]

### Approach
- **Shape**: `@MainActor @Observable final class RecordingRetentionController` modelled on `RemoteVocabularyController` (`RemoteVocabularyController.swift:55-95`): injected `interval: Duration` (one day), `now: () -> Date`, `calendar: Calendar` (carries the time zone), the record store, the live-state lookup (`(UUID) -> JobState?` from the queue's jobs), the settings, and the mover. `start()` is idempotent (guarded like `:76`), runs one check, then loops on `Task.sleep(for: interval)`; `Task.sleep` keeps counting through system sleep, which is what a daily check wants (`LivenessMarker.swift:84` explains the difference).
- **`requestCheck(after: Duration = .zero)`**: coalesces requests; at most one check runs at a time (`SingleFlight`, `SingleFlight.swift`, or one in-flight task plus a pending flag). Task .7 calls it with a few seconds' delay after a confirmed setting change (R12's "within a minute").
- **One check**: `reload()` the store (the other build may have changed it), read `settings.recordingRetention` once; for each record ask `RecordingRetentionRule.audioToDelete(record:liveState:retention:now:)`; right before deleting a meeting's files re-read its record and live state and skip it if either changed (a Retry, a reopened naming, a Keep); save a pending deletion of kind automatic (task .3; skip the meeting if that save fails), delete through the mover in `.forGood` mode inside the output folder's scope (as task .3 does, never on `.fallback`); on success set `audioDeletion = automatic(at: now)`. A file that is unreachable or cannot be deleted is logged (no file names at `.public` privacy), stays listed, and is tried again at the next check; it does not set the row's incomplete state, which is for manual deletions, and the pending mark is cleared when the meeting is done. A meeting with a pending deletion of another live process is skipped, so two running builds never delete the same meeting at once.
- **Record pruning**: a record none of whose files is present any more, and whose folders are reachable, is removed in the same pass (R1: a record lives while any of its files exists).
- **Triggers**: build it in `AppState` next to `remoteVocabulary` (`AppState.swift:191`) and start it from the launch `.task` (`MeetingTranscriberApp.swift:259-270`). After each meeting finishes (`.done`, which every naming path reaches): `onJobStateChange` is a single closure that `configureCallbacks` (`PipelineController.swift:381`) reinstalls on each queue rebuild, so chain the request in there, as the local-model notices chain theirs (`NotificationManager+LocalModel.swift:246-247`), and never assign the closure from outside.
- **Tests, written first** (`RecordingRetentionControllerTests`, temp folder, injected clock and calendar, a short interval): with Never nothing is deleted; with After 30 days a meeting recorded 31 days ago loses its audio for good while transcript and protocol stay, and one recorded 29 days ago keeps it until the clock passes the due date; Right after the protocol deletes at once after done; imports, failed, kept, left-unfinished, protocol-failed and no-record meetings are never touched; a recovered recording from before this feature is never touched; a record changed between selection and deletion is skipped; a meeting pending in another live process is skipped; an unreachable folder deletes nothing and is retried at the next check; two overlapping `requestCheck` calls run one check; a finished job triggers a check; a record whose files are all gone is pruned.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/RemoteVocabularyController.swift` - timer, clock injection, start guard, settings observation
- `app/MeetingTranscriber/Sources/PipelineController.swift:370-395` - `configureCallbacks`
- `app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift:235-255` - chaining `onJobStateChange`
- `app/MeetingTranscriber/Sources/AppState.swift:180-200` - where controllers are built

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/SingleFlight.swift` - one run at a time
- `app/MeetingTranscriber/Tests/RemoteVocabularyControllerTests.swift` - testing a timed controller

### Key context
- `AppSettings.effectiveOutputDir` silently falls back to `~/Downloads/MeetingTranscriber`; the check deletes only by the paths in the records and never resolves an output folder for that.
- `AppState.init` is constructed by unit tests: starting the timer belongs in the launch `.task`, not in `init`.
## Acceptance
- [ ] With a retention other than Never, the check deletes for good the audio of every recorded, finished, not kept meeting that is due, keeps its transcript, protocol and other files, and records the automatic deletion date (R11).
- [ ] Imports, failed meetings, meetings that left the queue unfinished, finished meetings whose protocol failed, kept meetings and meetings without a record are never touched; a meeting whose state changed after selection is skipped; an unreachable or undeletable file is logged, stays listed and is retried at the next check (R11).
- [ ] The check runs at launch, after each finished meeting (also when speakers are named later), once a day and on `requestCheck`; it never runs twice at once and deletes nothing with Never (R12).
- [ ] A record none of whose files remains is removed (R1).
- [ ] `RecordingRetentionControllerTests` were written before the implementation, use an injected clock and calendar, and pass (R14).
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
