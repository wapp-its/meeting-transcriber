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
  - `RecordingRowActions.RecordedFiles` (`hasProtocol`, `hasTranscript`: the entry's URLs, as `TranscriptionEntry.protocolURL`/`transcriptURL` record them) and `RecordingRowActions.FilesOnDisk` (`protocolExists`, `transcriptExists`, `transcriptSource: TranscriptSource`), where `TranscriptSource` is `.transcriptFile` (a readable, non-blank UTF-8 `.txt`), `.protocolOnly` (no usable `.txt`, but the protocol holds the full transcript) or `.none`: the three sources R10 names, resolved by the view's owner in task .4 with the regenerator's own rule (`ProtocolRegenerationFiles.transcript`, `ProtocolRegeneration.swift:99-108`), so a file that exists but is blank or not UTF-8 is `.none` for Regenerate while it still exists for Open Transcript.
  - `static func mainAction(state: JobState, files: RecordedFiles, canRetry: Bool) -> MainAction?`
  - `static func menuItems(state: JobState, onDisk: FilesOnDisk, canRetry: Bool) -> [MenuItem]`
- **Main button rule (R6):** Cancel for the states the menu's job row cancels today (`.waiting`, `.transcribing`, `.diarizing`, `.generatingProtocol`; `MenuBarView.swift:465-468`); Name Speakers for `.speakerNamingPending`; for `.done`, Open Protocol when `hasProtocol`, else Open Transcript when `hasTranscript`, else none (R6's error case: no main button); for `.error`, Retry when `canRetry`, else Remove. The main button follows the recorded files, as today's Open does (`TranscriptionsView.swift:173-181`), so a file deleted later still fails with the window's "The file was moved or deleted." message (A6).
- **Menu rule (R7, in R7's order), items only where they apply:** Open Protocol when `protocolExists`; Open Transcript when `transcriptExists`; Show in Finder when either exists; Regenerate Protocol… on `.done` rows always, and on `.error` rows only when `transcriptSource != .none`, with `enabled` true exactly when `transcriptSource != .none`; Retry on `.error` rows when `canRetry`; Remove on `.error` rows; Dismiss on `.speakerNamingPending` rows. Live rows (`.waiting` to `.generatingProtocol`) get no file items (the entry exposes none). The main action is repeated in the menu where R7 lists it (Open Protocol, Retry, Remove), so the right-click menu stands on its own. A file item never appears twice.
- **Tests, written before the implementation:** a table over every `JobState` case (the enum, `PipelineJob.swift`) crossed with the three transcript sources of R10 (`.transcriptFile`; `.protocolOnly`; `.none`), with the protocol present and missing, and `canRetry` both ways; plus the explicit cases: done with neither recorded file has no main button and an empty menu except a disabled Regenerate; done with only a transcript has Open Transcript as its main button; a transcript file that exists but is unusable (`transcriptExists` true, source `.none` or `.protocolOnly`) lists Open Transcript and enables Regenerate only with the protocol fallback; error that cannot be retried has Remove as its main button and Remove in the menu; naming-pending has Name Speakers and Dismiss; a live job has Cancel and no items. Assert the item order.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/MenuBarView.swift:456-490` - today's per-job actions and their state gates
- `app/MeetingTranscriber/Sources/TranscriptionsView.swift:160-200` - today's row buttons
- `app/MeetingTranscriber/Sources/TranscriptionList.swift:5-75` - `TranscriptionEntry`, what a row knows
- `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift:95-108` - `ProtocolRegenerationFiles.transcript`, the usability rule `TranscriptSource` mirrors (readable non-blank UTF-8 file, else the protocol's full transcript, else nil)

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/PipelineJob.swift` - `JobState` cases and `isTerminal`

### Key context
- Pure: no `FileManager`, no `PipelineQueue`, no SwiftUI import. The existence, source and `canRetry` inputs are resolved by the view's owner (task .4) with the regenerator's own reading code, so this type and the sheet never disagree about what is usable.
- `JobState` has seven cases; a `switch` without `default` keeps the function honest when a state is added.

### Acceptance
- [ ] `RecordingRowActions.mainAction` returns Cancel for waiting and running jobs, Name Speakers while names are awaited, Open Protocol or Open Transcript for a finished job by its recorded files, Retry or Remove for a failed job by `canRetry`, and nil for a finished job with neither file (R6).
- [ ] `RecordingRowActions.menuItems` lists, in R7's order and only where they apply, Open Protocol, Open Transcript, Show in Finder, Regenerate Protocol…, Retry, Remove and Dismiss; a file item is left out when its file is missing on disk, and Regenerate is disabled exactly when the transcript source is `.none` under the regenerator's rule (no readable non-blank transcript file and no protocol holding the full transcript), so an existing but blank transcript file alone does not enable it (R7).
- [ ] `RecordingRowActionsTests` covers every `JobState` case and the three transcript sources (`.transcriptFile`, `.protocolOnly`, `.none`), with files present, missing and present-but-unusable, and `canRetry` both ways, and was written before the implementation (R10).
- [ ] The type imports no UI framework and touches no file system; `swift test --filter RecordingRowActionsTests` is green.

## Acceptance
- [ ] TBD

## Done summary
The All Recordings window (task .4) can now render each row's main button and its "…" menu from one tested list. `RecordingRowActions` (new, `app/MeetingTranscriber/Sources/RecordingRowActions.swift`) turns a row's `JobState`, its recorded files, its files on disk and whether the pipeline would take a retry into a `MainAction?` and an ordered `[MenuItem]`. It imports nothing and reads no file. `RecordingRowActionsTests` (9 tests, written first and committed red against a signature stub) covers every `JobState` case crossed with seven on-disk situations (protocol present or missing; transcript present, missing, or present but blank or not UTF-8; the sources `.transcriptFile`, `.protocolOnly`, `.none`) and `canRetry` both ways, asserting each exact list so order and no-duplicates are pinned.

Error cases and the tests that cover them:
- R6, finished job with neither recorded file has no main button: `testMainActionOfAFinishedJobOpensItsProtocolElseItsTranscriptElseNothing` (last assertion), and its menu holds only a disabled Regenerate: the `neither` row of `testMenuOfAFinishedJobLeavesOutMissingFilesAndDisablesRegenerateWithoutASource`.
- R7, a file missing on disk leaves its item out: the `protocolHoldingTranscript`, `protocolWithoutTranscript`, `transcriptOnly` and `neither` rows of the four menu tests.
- R7, Regenerate disabled exactly when there is no usable source, and a blank transcript alone does not enable it: the `unusableTranscript` row (disabled) and the `unusableTranscriptBesideFullProtocol` row (enabled through the protocol) of the finished-job and failed-job menu tests.

Gates: `swift test --parallel --filter 'RecordingRowActionsTests'` rc 0 with 9 of 9 tests (log `/private/tmp/mt-gh170/task3/quick-rows.log`); the red-first run against the stub was rc 1 with 8 of 9 failing on assertions (`/private/tmp/mt-gh170/task3/quick-rows-red.log`; the live-job empty-menu test passes against a stub that returns `[]`). `./scripts/lint.sh` with the pinned tools rc 0, 0 violations in 906 files. `gate classify` returned FULL (Swift code), so no GATE_SKIPPED line. Baseline: green via handoff (conductor run at 79481cc5, 112 tests, rc 0); every path changed since that SHA is this task's two new files. Not run here: `swiftlint analyze` (the conductor runs it on the integrated branch). Every new declaration has a reader in the tests or the implementation.

Integration notes for task .4 are in the run-notes directory as `task-3-row-actions.md`.

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

stage: impl-review - ran [79481cc5..8a4b851f] (codex:gpt-6-astra:xhigh, one draw correctness, SHIP, 0 findings; receipt /tmp/impl-review-receipt-d1cb77e1af10-gh-170-menu-sections-and-an-all-recordings.3.json)
stage: wave-join - ran (lane b0dd74aa,e7eb4ecd cherry-picked onto 79481cc5 as c06bc2a3,8a4b851f; focused verify RecordingRowActionsTests rc 0, 9 of 9, log /private/tmp/mt-gh170/verify3/quick-rows.log)

### Decisions

- DECIDED: `TranscriptSource` keeps the case name `none`, with `// swiftlint:disable:this discouraged_none_name`. The opted-in lint rule flags it, and the task's Approach, its Acceptance and task .4's plan all name `.none`. The repository already suppresses the rule the same way in `SilencePromptPolicy.swift:55`, `AppSettings.swift:128` and `LiveCaptionsGate.swift:33` (rule 1, repo convention).
- DECIDED: a `.speakerNamingPending` row lists Open Protocol, Open Transcript and Show in Finder for the files on disk, then Dismiss. The task's menu rule excludes only `.waiting` to `.generatingProtocol` from file items (rule 1). Today's window also offers Open on any row with a file. During naming the transcript on disk is normally the unlabelled stage-1 draft.
- DECIDED: Cancel and Name Speakers do not appear in the "…" menu. R7's item list does not name them, and the task repeats only Open Protocol, Retry and Remove (rule 1).
- DECIDED: no `TranscriptSource` mapping helper from `ProtocolRegenerationFiles` in this task. Task .4's plan puts that mapping in `AllRecordingsActions.filesOnDisk` (nil is `.none`, `fromProtocol` is `.protocolOnly`, else `.transcriptFile`), and the task's Approach leaves resolution to the view's owner. Adding it here would be scope past the ACs.
- DECIDED: the test's red step is a commit with the final signatures and wrong bodies (nil and `[]`), so the run fails on assertions instead of on a missing type. That is the stated reason for failure, which a test-only commit that does not compile cannot show.

Finding (no action taken): the plan's note that a live entry "exposes no files" is inaccurate. Stage 1 sets `PipelineJob.transcriptPath` to an unlabelled draft (`PipelineQueue+Stages.swift:140-149`), so a diarizing or protocol-generating entry has a transcript URL. The decision gates live rows to an empty menu by state anyway, as the task asks. Today's window shows Open on such a row, so the change removes that, by design.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: c06bc2a3ed58818cc807fc9ec933f8292217eb65, 8a4b851f07c2e14ab76c7840e832c7112148f274
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh170/home swift test --parallel --filter 'RecordingRowActionsTests' (rc 0, 9/9); ./scripts/lint.sh (rc 0)
- PRs: