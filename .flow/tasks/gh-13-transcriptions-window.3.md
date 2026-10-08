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
The menu-bar menu now lists every unfinished job plus only the 3 jobs that finished last, read from the same merged list the Transcriptions window will use, so finished lines survive the one-minute reap and a restart while the menu no longer grows with every recording. A failed line offers Remove (and Retry where the queue accepts it), a done line offers Open and lost Dismiss, and Open goes through TranscriptionFileOpener inside the output folder's security scope.

Tier: session (jev-unavailable(no_key)) -> explicit invocation opus at xhigh (actual: claude-opus-5-5)

stage: impl-review - ran [2026-10-08T12:10:22Z..2026-10-08T12:17:28Z]

The review ran on codex gpt-5.6-sol at xhigh with three draws (correctness, contracts, integration), each SHIP with no findings, so the validator (FLOW_VALIDATE_REVIEW=1) had nothing to dispatch and the phase lease was released. Receipt /tmp/impl-review-receipt-372726e60d63-gh-13-transcriptions-window.3.json, fan-out rid 551a0e843e024e3b89d4343806fd11ac. The reviewers ran the focused suites themselves under CODEX_SANDBOX=workspace-write (74 of 74 passed) and wrote nothing into the tracked tree.

Acceptance criteria and the tests that pin them (74 tests, suite_rc 0, /private/tmp/gh13/t3-green2.log at 22ac061c):
- 1 transcribing job and 5 done jobs give 4 lines, the running one and Done 3 to Done 5; Done 1 and Done 2 are absent (R7). MenuBarJobMenuTests.testOneRunningAndFiveDoneJobsGiveFourLines
- A failed job known only from the history shows its error text and Remove and no Retry; tapping Remove, located by A11yID.jobRemoveButton(0), hands that job's id to onRemoveFailedJob (R6, R7). MenuBarJobMenuTests.testAFailedJobKnownOnlyFromTheHistoryOffersRemoveButNoRetry
- A live failed line has Retry exactly when canRetryJob holds (both Retry tests unchanged and green) and Remove (MenuBarViewTests.testRemoveButtonShownForErrorJob, MenuBarJobMenuTests.testAJobsActionsAndFullErrorSitInItsSubmenu). A done line with a protocol has Open, whose tap hands the protocol URL to onOpenProtocol, and no Dismiss (MenuBarViewTests.testDoneJobOffersOpenAndNoDismiss). A naming-pending line keeps Name Speakers and Dismiss (MenuBarViewTests.testDismissButtonCallsCallbackWithJobID) (R7).
- The five named tests were rewritten for the new rule and two renamed because their old names stated the opposite: testDismissButtonShownForCompletedJob is now testDoneJobOffersOpenAndNoDismiss, testDismissButtonShownForErrorJob is now testRemoveButtonShownForErrorJob. Every other menu test runs unchanged (R7).
- MeetingTranscriberApp.openJobFile routes the menu's Open through TranscriptionFileOpener.perform with appState.settings.effectiveOutputDir as scope root; a missing file opens nothing (R7). Verified by reading the code, the @main App has no test seam.
- The only identifier added is A11yID.jobRemoveButton(index), "jobRemoveButton.<n>", which takes an Int and carries no title, participant or path (R8).
- Lint with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 returned rc 0 (0 of 708 files need formatting, 0 violations, /private/tmp/gh13/t3-lint3.log at 22ac061c).

Baseline before the edit was green (72 tests in MenuBarJobMenuTests, MenuBarViewTests and TranscriptionListTests, /private/tmp/gh13/t3-baseline.log). A mutation run applied 5 source mutations to MenuBarView one at a time (menu lists every entry, history ignored, Retry keyed on the failed state, Remove calling Dismiss, Dismiss back on finished lines); each turned its intended tests red and the source was restored byte-identical before the commit (/tmp/gh13/t3-mutate.py, /private/tmp/gh13/t3-mut-*.log).

CI parity measured locally with Xcode 27.0. An xcodebuild build-for-testing with -debug-time-function-bodies succeeded; the slowest touched body is MeetingTranscriberApp.menuBarContent at 63.5 ms against the 300 ms gate, MenuBarView.jobActions 16 ms (/private/tmp/gh13/t3-xcodebuild.log). swiftlint analyze --strict on that log found 1 violation, unused_declaration on PipelineController.retryJob(id:) in PipelineController+Transcriptions.swift, which predates this task (no caller since task .2, task .4 wires it). ./scripts/pre-push.sh --with-appstore returned rc 0 (Homebrew and App Store release builds, /tmp/gh13/t3-prepush.out).

Changed user route (feature map): menu bar, Processing section. Job lines now come from the merged list (unfinished jobs plus the last 3 finished); a done line has Open and no Dismiss, a failed line has Retry (when accepted) and Remove and Open when it kept a transcript, a naming-pending line keeps Name Speakers and Dismiss.

Decisions:
- MenuBarView's new inputs are `var history: [TerminalJobRecord] = []` and `var onRemoveFailedJob: (UUID) -> Void = { _ in }`, so the existing test constructions compile unchanged. onRemoveFailedJob is declared before onDismissJob, since SwiftLint's trailing_closure rule flagged the test helper when a closure variable sat between two closure literals at the end of the call.
- Retry stays on pipelineQueue.canRetryJob / retryJob as the task says, so PipelineController.retryJob(id:) keeps no caller until task .4 (see the analyze line above).
- Open is offered on any finished line with a protocol or transcript, failed lines included, as R7 states ("a finished line offers Open when a file exists"); before, only done lines had it.
- The new history-only and running-plus-done tests insert jobs with insertJobForTesting, which writes no snapshot or log into the default data folder; the rewritten done and naming-pending tests do the same.

Follow-ups and notes for the next tasks:
- JobMenuSummary.status(of:progress:) and symbol(of:) now have no production caller; the unchanged MenuBarJobMenuTests still call them, which keeps swiftlint analyze quiet. Removing them would mean rewriting two tests this task had to keep unchanged.
- The "Processing" caption now also heads lines that come only from the history (for example right after launch), as the task asked to keep its visibility rule.
- Look and feel of the shortened menu in the running app is not verified here; menu-bar dropdown interaction is manual QA per the project's GUI testing rules and is the owner's check at the spec's end.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 22ac061c2020acb2d1648e8e902beaa2e180d0fa
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh13-home swift test --parallel --filter 'MenuBarJobMenuTests|MenuBarViewTests|TranscriptionListTests' (rc 0, 74 tests, /private/tmp/gh13/t3-green2.log), PATH=$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH ./scripts/lint.sh (rc 0, 0/708 need formatting, 0 violations, /private/tmp/gh13/t3-lint3.log), ./scripts/pre-push.sh --with-appstore (rc 0, /tmp/gh13/t3-prepush.out), xcodebuild build-for-testing with -debug-time-function-bodies + swiftlint analyze --strict (build rc 0, slowest touched body 63.5 ms; analyze 1 pre-existing unused_declaration on PipelineController.retryJob(id:), /private/tmp/gh13/t3-analyze.log)
- PRs: