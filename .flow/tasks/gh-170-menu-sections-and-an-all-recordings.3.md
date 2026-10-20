---
satisfies: [R6, R7, R10]
---
# gh-170-menu-sections-and-an-all-recordings.3 RecordingRowActions: the pure row decision for the All Recordings window

Touches: app/MeetingTranscriber/Sources/RecordingRowActions.swift, app/MeetingTranscriber/Tests/RecordingRowActionsTests.swift

## Description
The early proof point: one pure decision that turns a row's job state, its files and whether the pipeline would retry it into the row's main button and its "…" menu items. The view (task .4) only renders what this returns, so every state is tested here without SwiftUI, and the "…" menu and the right-click menu cannot drift because both render the same list.

**Size:** S
**Files:** `app/MeetingTranscriber/Sources/RecordingRowActions.swift` (new), `app/MeetingTranscriber/Tests/RecordingRowActionsTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/RecordingRowActions.swift, app/MeetingTranscriber/Tests/RecordingRowActionsTests.swift]

### Approach
- **Shape** (signatures only; the worker names the cases):
  - `RecordingRowActions.MainAction`: `cancel`, `nameSpeakers`, `openProtocol`, `openTranscript`, `retry`, `remove`.
  - `RecordingRowActions.MenuItem` (Equatable): `openProtocol`, `openTranscript`, `showInFinder`, `regenerate(enabled: Bool)`, `retry`, `remove`, `dismiss`.
  - `RecordingRowActions.RecordedFiles` (`hasProtocol`, `hasTranscript`: the entry's URLs, as `TranscriptionEntry.protocolURL`/`transcriptURL` record them) and `RecordingRowActions.FilesOnDisk` (`protocolExists`, `transcriptExists`, `protocolHoldsFullTranscript`: read when the menu is built, by the view's resolver in task .4).
  - `static func mainAction(state: JobState, files: RecordedFiles, canRetry: Bool) -> MainAction?`
  - `static func menuItems(state: JobState, onDisk: FilesOnDisk, canRetry: Bool) -> [MenuItem]`
- **Main button rule (R6):** Cancel for the states the menu's job row cancels today (`.waiting`, `.transcribing`, `.diarizing`, `.generatingProtocol`; `MenuBarView.swift:465-468`); Name Speakers for `.speakerNamingPending`; for `.done`, Open Protocol when `hasProtocol`, else Open Transcript when `hasTranscript`, else none (R6's error case: no main button); for `.error`, Retry when `canRetry`, else Remove. The main button follows the recorded files, as today's Open does (`TranscriptionsView.swift:173-181`), so a file deleted later still fails with the window's "The file was moved or deleted." message (A6).
- **Menu rule (R7, in R7's order), items only where they apply:** Open Protocol when `protocolExists`; Open Transcript when `transcriptExists`; Show in Finder when either exists; Regenerate Protocol… on `.done` rows always, and on `.error` rows only when a transcript source exists, with `enabled` true exactly when `transcriptExists || protocolHoldsFullTranscript`; Retry on `.error` rows when `canRetry`; Remove on `.error` rows; Dismiss on `.speakerNamingPending` rows. Live rows (`.waiting` to `.generatingProtocol`) get no file items (the entry exposes none). The main action is repeated in the menu where R7 lists it (Open Protocol, Retry, Remove), so the right-click menu stands on its own. A file item never appears twice.
- **Tests, written before the implementation:** a table over every `JobState` case (the enum, `PipelineJob.swift`) crossed with the three transcript sources of R10 (a transcript file; only the transcript inside the protocol; neither), with the protocol present and missing, and `canRetry` both ways; plus the explicit cases: done with neither recorded file has no main button and an empty menu except a disabled Regenerate; done with only a transcript has Open Transcript as its main button; error that cannot be retried has Remove as its main button and Remove in the menu; naming-pending has Name Speakers and Dismiss; a live job has Cancel and no items. Assert the item order.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/MenuBarView.swift:456-490` - today's per-job actions and their state gates
- `app/MeetingTranscriber/Sources/TranscriptionsView.swift:160-200` - today's row buttons
- `app/MeetingTranscriber/Sources/TranscriptionList.swift:5-75` - `TranscriptionEntry`, what a row knows

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/PipelineJob.swift` - `JobState` cases and `isTerminal`
- `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift:99-108` - how the regenerator falls back from the `.txt` to the protocol's full transcript, the reason for `protocolHoldsFullTranscript`

### Key context
- Pure: no `FileManager`, no `PipelineQueue`, no SwiftUI import. The existence and `canRetry` inputs are resolved by the view's owner.
- `JobState` has seven cases; a `switch` without `default` keeps the function honest when a state is added.

### Acceptance
- [ ] `RecordingRowActions.mainAction` returns Cancel for waiting and running jobs, Name Speakers while names are awaited, Open Protocol or Open Transcript for a finished job by its recorded files, Retry or Remove for a failed job by `canRetry`, and nil for a finished job with neither file (R6).
- [ ] `RecordingRowActions.menuItems` lists, in R7's order and only where they apply, Open Protocol, Open Transcript, Show in Finder, Regenerate Protocol…, Retry, Remove and Dismiss; a file item is left out when its file is missing on disk, and Regenerate is disabled exactly when neither a transcript file nor a protocol holding the full transcript exists (R7).
- [ ] `RecordingRowActionsTests` covers every `JobState` case and the three transcript sources (separate file, only inside the protocol, neither), with files present and missing and `canRetry` both ways, and was written before the implementation (R10).
- [ ] The type imports no UI framework and touches no file system; `swift test --filter RecordingRowActionsTests` is green.

## Acceptance
- [ ] TBD

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
