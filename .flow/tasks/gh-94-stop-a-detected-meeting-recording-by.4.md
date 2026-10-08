---
satisfies: [R8]
---
# gh-94-stop-a-detected-meeting-recording-by.4 Put the stop and watch controls directly under the menu's status line

## Description
Moves the control for the current state to directly under the menu's grey status line, above the first divider (R8; issue #98, owner 2026-10-08; decision D4). Today `MenuBarView.body` (`MenuBarView.swift:57-79`) renders `statusHeader`, `meetingInfo`, `errorInfo`, a `Divider`, and only then `watchControls`, whose first item is "Start/Stop Watching for Meetings" followed by "Stop Recording" or the two record starts, "Name Speakers..." and "Process Audio/Video Files...". Needs task .2, which makes "Stop Recording" appear for every recording.

**Size:** S
**Files:** `app/MeetingTranscriber/Sources/MenuBarView.swift`, new `app/MeetingTranscriber/Tests/MenuBarViewSessionControlsTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Tests/MenuBarViewSessionControlsTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift]

### Approach
- **New section `sessionControls`** (`@ViewBuilder private var`, like the other hoisted sections; type-check budget note at `MenuBarView.swift:51-56`), placed in `body` directly after `statusHeader` and before `meetingInfo`, `errorInfo` and the first `Divider`. New order: `statusHeader`, `sessionControls`, `meetingInfo`, `errorInfo`, `Divider`, `watchControls`, `processingQueue`, then the rest unchanged.
  - While the stop closure is set (any recording, after task .2): "Stop Recording" (`stop.circle.fill`, shortcut ".").
  - Otherwise: the watch toggle, "Stop Watching for Meetings" (`stop.fill`) while watching, "Start Watching for Meetings" (`play.fill`) when idle, shortcut "s".
- **`watchControls`** keeps everything else in its current order. The watch toggle stays there only while a recording runs (A7: Stop Watching stays reachable, below the divider, with the same label and shortcut); "Stop Recording" is no longer rendered there. Define the watch toggle once (a private helper or computed property) and use it from both places, so label, icon and shortcut cannot drift.
- **One item per line.** A menu-style `MenuBarExtra` cannot lay items side by side (note at `jobRow`, `MenuBarView.swift:249-252`); every control in `sessionControls` is its own line. gh-46 (pause and resume, planned) puts its "Pause Recording" / "Resume Recording" item directly under "Stop Recording" in this section; if gh-46 has already landed when this task runs, move its item here, directly under "Stop Recording". gh-49 (planned) puts its open-question section above `statusHeader`; this task does not touch that.
- No change to `MeetingTranscriberApp.swift`, the stop closure's label `onStopManualRecording`, or any callback.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/MenuBarView.swift:51-176` — section layout, type-check note, `watchControls`
- `app/MeetingTranscriber/Tests/MenuBarViewTests.swift:32-80, 220-240, 720-760, 835-860` — view construction helper, watch toggle tests, Stop Recording tests

**Optional** (reference as needed):
- `CLAUDE.md` "GUI Testing" — one ViewInspector wiring test per control; logic states belong in pure tests, order is pinned here because the order is the behaviour

### Key context
- `MenuBarViewTests.swift` is at about 980 lines: put new tests in the new file and reuse its construction pattern.
- An existing test that pins the old position (rather than presence or callback) is updated to the new order, not deleted; name each such test and the reason in the done summary (changed requirement, R8).

## Acceptance
- [ ] `MenuBarViewSessionControlsTests`: with the stop closure set, the first `Button` in document order is "Stop Recording" and no `Divider` comes between the status header and it; tapping it calls the stop closure.
- [ ] Watching without a recording: the first `Button` is "Stop Watching for Meetings" with no `Divider` before it; idle: "Start Watching for Meetings"; tapping either calls `onStartStop`.
- [ ] While recording, "Stop Watching for Meetings" is still in the menu, after the first `Divider`, and calls `onStartStop`; it appears exactly once in every state.
- [ ] Keyboard shortcuts unchanged: "." on Stop Recording, "s" on the watch toggle.
- [ ] Existing `MenuBarViewTests` pass; any test changed because it pinned the old position is named in the done summary with the reason.
- [ ] Focused run green, read from the log file: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "MenuBarView" > /private/tmp/mt-gh94-t4.log 2>&1; echo "exit=$?"` (never pipe the run into tail/head/grep).
- [ ] `PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh` reports 0 violations.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
