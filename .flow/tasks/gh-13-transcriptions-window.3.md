---
satisfies: [R6, R7, R8]
---
# gh-13-transcriptions-window.3 Shorter menu: unfinished jobs plus the last three finished

## Description
Shorten the menu-bar menu: it lists every unfinished job plus only the 3 most recently finished (from the same list as the window, so finished lines survive the 60 s reap and a restart), a failed line gets Remove instead of Dismiss, a done line loses Dismiss. Split from the window so the menu change and its test rewrites land as one reviewable unit. See spec R6, R7, R8 and decision A3.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/MenuBarView.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Tests/MenuBarJobMenuTests.swift`, `app/MeetingTranscriber/Tests/MenuBarViewTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/MenuBarJobMenuTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift]

### Approach
- New `MenuBarView` inputs, declared as `var` with a default like `updateChecker` (`Sources/MenuBarView.swift:7`) so the ~17 existing test constructions keep compiling: `var history: [TerminalJobRecord] = []` and `var onRemoveFailedJob: (UUID) -> Void = { _ in }`. Production passes both explicitly.
- `processingQueue` (`:177-188`): render `TranscriptionList.menuEntries(TranscriptionList.entries(liveJobs: pipelineQueue.jobs, records: history))` instead of every queue job; keep the "Processing" caption and its visibility rule (shown when the list is non-empty), enumerate for the row index.
- Rows (`jobRow`, `jobMenuTitle`, `jobStateLabel`, `stageProgressText`, `:248-330`) take a `TranscriptionEntry` (id + state + warnings + error + title) instead of a `PipelineJob`, using the `(state, hasWarnings)` overloads of `JobMenuSummary`. Keep one `Menu` per line (`:248-251` explains why).
- Actions per line (`jobActions`, `:270-286`): unfinished lines unchanged (Name Speakers, Cancel, Dismiss for naming-pending); a finished line with `fileToOpen` gets "Open" (`onOpenProtocol`); a failed line gets "Retry" only when `pipelineQueue.canRetryJob(id:)` (unchanged rule and identifier `A11yID.jobRetryButton(index)`) and "Remove" with a new `A11yID.jobRemoveButton(index)` calling `onRemoveFailedJob(id)`; no "Dismiss" on done or failed lines.
- `A11yID.jobRemoveButton(_ index: Int)` next to `jobRetryButton` (`Sources/A11yID.swift:55-60`), index-based for the same reason (no title in an identifier).
- `MeetingTranscriberApp.menuBarContent` (`Sources/MeetingTranscriberApp.swift:133-160`): pass `history: appState.pipeline.terminalJobStore.records` and `onRemoveFailedJob: { appState.pipeline.removeFailedJob(id: $0) }`, and route `onOpenProtocol` (today `NSWorkspace.shared.open` directly, `:148`) through `TranscriptionFileOpener.perform(url, scopeRoot: appState.settings.effectiveOutputDir, action: { NSWorkspace.shared.open($0) })` (task .2): after a restart a history line can be opened before any queue holds the output folder's scope, which the App Store build needs. A missing file opens nothing, as today. Leave `onDismissJob` wired as is (naming-pending Dismiss).
- Changed requirement, so these existing tests are rewritten, not deleted, and the commit body says why: `MenuBarJobMenuTests.testEachJobIsOneSubmenuWithoutRowLayoutParts` (4 failed jobs now give 3 lines; keep the one-submenu-per-line and no-Spacer assertions), `MenuBarJobMenuTests.testAJobsActionsAndFullErrorSitInItsSubmenu` (Remove instead of Dismiss), `MenuBarViewTests.testDismissButtonShownForCompletedJob` (a done line has no Dismiss), `MenuBarViewTests.testDismissButtonCallsCallbackWithJobID` (use a naming-pending job, where Dismiss stays), `MenuBarViewTests.testDismissButtonShownForErrorJob` (Remove shown). Every other menu test must pass unchanged, including both Retry tests (`MenuBarViewTests.swift:600-639`), whose row indices hold because the menu keeps oldest-added first.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/MenuBarView.swift` — the whole view; the type-check note at `:50-55`
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:111-160` — scene split rule and the menu wiring
- `app/MeetingTranscriber/Tests/MenuBarJobMenuTests.swift` — the job-line tests
- `app/MeetingTranscriber/Tests/MenuBarViewTests.swift:408-640` — job tests that change or must hold

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/TranscriptionList.swift` — from task .2
- `app/MeetingTranscriber/Sources/A11yID.swift:1-60` — identifier rules

### Key context
- The analyze build fails any body over 300 ms of type checking (`-warn-long-function-bodies=300`, warnings as errors); keep the row builders small and hoist interpolated strings out of `ViewBuilder`s, as the file already does.
- A history-only failed line has no live job, so `canRetryJob` is false and Retry is absent until the pipeline loads the job; Remove still works because the controller starts the pipeline first (task .2).
- ViewInspector: locate buttons by `A11yID` constant, `find(viewWithAccessibilityIdentifier:)` then `.button().tap()` (pattern at `Tests/MenuBarViewTests.swift:607-611`).

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<your scratch dir>/home swift test --parallel --filter 'MenuBarJobMenuTests|MenuBarViewTests|TranscriptionListTests' > <your scratch dir>/t3-tests.log 2>&1` and read the log.
- `./scripts/lint.sh` with the pinned tools from `scripts/tool-versions.sh`.
## Acceptance
- [ ] With 1 transcribing job and 5 done jobs in the queue the menu shows 4 job lines: the transcribing one and the 3 most recent done ones (R7).
- [ ] A failed job known only from `history` shows a line whose submenu has the error text and Remove, and no Retry; tapping Remove (located by `A11yID.jobRemoveButton`) calls `onRemoveFailedJob` with that job's id (R6, R7).
- [ ] A live failed job's line has Retry exactly when `canRetryJob` holds, and Remove; a done line has Open when it has a file and no Dismiss; a naming-pending line keeps Name Speakers and Dismiss (R7).
- [ ] The five tests named in the Approach are rewritten for the new rule; every other existing menu test passes unchanged (R7).
- [ ] The menu's Open closure in `MeetingTranscriberApp` goes through `TranscriptionFileOpener` with the current output folder as scope root (R7).
- [ ] No identifier added contains a title, participant or path (R8).
- [ ] Tests and lint pass.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
