---
satisfies: [R1]
---
# gh-105-watching-pauses-during-a-recording-and.4 Hide the watch toggle in the menu while a recording runs

## Description
R1: the menu shows no Start/Stop Watching item while any recording runs. Independent of the resume tasks.

**Size:** S
**Files:** `app/MeetingTranscriber/Sources/MenuBarView.swift`, `app/MeetingTranscriber/Tests/MenuBarViewSessionControlsTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Tests/MenuBarViewSessionControlsTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift]

### Approach
- `watchControls` (`MenuBarView.swift:141-148`): drop the `if onStopManualRecording != nil { watchToggle }` branch; keep the record items' condition as is. `sessionControls` (`:128-139`) already shows the toggle only when no stop closure is set. Update the doc comments that describe the toggle moving below the divider (`:142-143`, `:226`).
- Keep the hoisted-section shape (type-check budget note at `:44-56`).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/MenuBarView.swift:44-148, 220-240`
- `app/MeetingTranscriber/Tests/MenuBarViewSessionControlsTests.swift:80-170`

### Key context
- The stop closure is set for every recording, detected or manual (`MeetingTranscriberApp.swift:145-148`), so its presence is the "a recording runs" signal.
- These tests pin the old behaviour and change with R1 (a changed requirement): `testWhileRecordingStopWatchingStaysBelowTheFirstDivider` (now: no toggle anywhere while recording), `testTheWatchToggleAppearsExactlyOnceInEveryState` (recording cases expect 0; the `recording: false` case keeps 1), `testKeyboardShortcutsAreUnchanged` (drop the Stop Watching shortcut check during a recording; keep "." on Stop Recording and "s" on the toggle outside recordings). Name each in the done summary.

## Acceptance
- [ ] `MenuBarViewSessionControlsTests`: with the stop closure set (detected meeting, manual recording with watching off), no button labelled "Start Watching for Meetings" or "Stop Watching for Meetings" exists; without it (idle, watching), exactly one toggle, first under the status line, as today; "Stop Recording" still first under the status line while recording.
- [ ] Keyboard shortcuts: "." on Stop Recording, "s" on the toggle when shown.
- [ ] Changed tests named in the done summary with the reason (R1).
- [ ] Focused run green, read from the log file: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "MenuBarView" > /private/tmp/mt-gh105-t4.log 2>&1; echo "exit=$?"`.
- [ ] Lint 0 violations.

## Done summary
The menu no longer shows "Start Watching for Meetings" or "Stop Watching for Meetings" while any recording runs (R1): `MenuBarView.watchControls` lost its `if onStopManualRecording != nil { watchToggle }` branch, the record items keep their effective condition (no stop closure and not recording), and outside recordings the toggle stays the first line under the status with its "s" shortcut.

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

baseline: green via handoff (verified at fd9c8cb0 by the conductor's spec-base baseline, HEAD equal to it, no paths changed since); lint measured pre-edit: 0 violations in 893 files.

Changed tests (R1, a changed requirement), all in `app/MeetingTranscriber/Tests/MenuBarViewSessionControlsTests.swift`:
- `testWhileRecordingStopWatchingStaysBelowTheFirstDivider` -> `testWhileRecordingNoWatchToggleIsShown`: it pinned the toggle below the first divider while recording; it now asserts that neither toggle label exists for a detected meeting (watching on) and a manual recording (watching off), with "Stop Recording" present as a positive control so the absence check cannot pass vacuously.
- `testTheWatchToggleAppearsExactlyOnceInEveryState` -> `testTheWatchToggleAppearsOnceWithoutARecordingAndNeverDuringOne`: the two recording cases now expect 0 toggles; idle, watching, error and "recording without a stop" keep 1. Renamed because the old name claims "once in every state".
- `testKeyboardShortcutsAreUnchanged`: dropped the "s" on Stop Watching check during a recording; "." on Stop Recording and "s" on the toggle outside recordings are kept.
Red before the fix (measured, /private/tmp/mt-gh105/t4-red.log): only the first two failed, each in both recording cases, because a toggle still rendered. Green after (measured, /private/tmp/mt-gh105-t4.log): exit 0, 72/72 collected, 0 errors.
Unchanged and still green: `MenuBarViewTests.testStopRecordingReplacesRecordAppButton` (stop closure with state idle hides "Start Recording with Options…"), which is what pins the record items' combined condition.

Choices:
- DECIDED: the record items' condition is `onStopManualRecording == nil, state != .recording`, not the bare `state != .recording` · the task says keep the record items' condition as is; before, the `if/else if` chain hid them whenever the stop closure was set, and `MenuBarViewTests.testStopRecordingReplacesRecordAppButton` pins exactly that (R6: nothing else changes).
- DECIDED: removed the in-body comment "While a recording holds the line under the status, watching stays reachable here..." without replacement and rewrote the `watchToggle` doc comment to "Rendered by `sessionControls` only while no recording runs: a recording pauses watching, so the menu offers no watch control during one." · the old texts described the removed branch; the new doc names only what this code does, with no fork issue ids and no claim about the resume tasks .1-.3 deliver.
- DECIDED: kept `watchToggle` as its own property and kept the name `watchControls` · keeps the hoisted-section shape the type-check budget note asks for; a rename is unrequested.

Gates (worktree /Users/flach/.ai-sync/worktrees/-Users-flach-Sources-meeting-transcriber/gh-105-wave-task-4):
- `flowctl gate classify --base fd9c8cb0` -> FULL (Swift source), so the focused Quick commands ran.
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "MenuBarView" > /private/tmp/mt-gh105-t4.log 2>&1` -> exit=0, 72/72.
- `PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh` -> rc=0, 0 violations.
- Not run: `swiftlint analyze` (conductor runs it on the integrated branch; no declaration became unread: `Taps`, `Line.divider` and every label constant are still used). Live menu check not run: the menu-bar dropdown is manual-QA-only per CLAUDE.md, and the wave forbids pushing, which `mt-update` needs; the ViewInspector tests feed the view the same inputs the scene passes (`onStopManualRecording` from `appState.canStopRecording`).

User route changed: during a recording the menu no longer offers Start/Stop Watching; there is no `.flow/features/` map in this checkout to update.

Follow-ups (not fixed): none found.

stage: impl-review - ran [2026-10-20T11:34Z..2026-10-20T11:38Z] SHIP, 1 round, no findings, receipt /tmp/impl-review-receipt-0a7d6728fcc1-gh-105-watching-pauses-during-a-recording-and.4.json (model: gpt-6-astra:xhigh)
stage: plan-sync - skipped(config: planSync.enabled=false)
Integrated onto the spec branch by fast-forward (commit a15ef503 unchanged); focused integrated verify on the branch: swift test --filter "MenuBarView" exit=0, 0 failures (/private/tmp/mt-gh105/verify-t4.log).
## Evidence
- Commits: a15ef503d22e86f79de71431ae53897300747eba
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "MenuBarView" > /private/tmp/mt-gh105-t4.log 2>&1 (exit=0, 72/72 collected, 0 errors), PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh (rc=0, 0 violations in 893 files), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "MenuBarView" > /private/tmp/mt-gh105/verify-t4.log 2>&1 (integrated spec branch at a15ef503: exit=0, 0 failures), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "MenuBarView" (exit=0, 72 tests); PATH=lint-tools ./scripts/lint.sh (0 violations)
- PRs: