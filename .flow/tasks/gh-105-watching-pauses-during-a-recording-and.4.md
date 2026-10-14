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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
