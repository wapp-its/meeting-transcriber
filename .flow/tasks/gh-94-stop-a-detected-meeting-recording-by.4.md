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
The menu now shows the control for the current state directly under the grey status line, above the first divider: "Stop Recording" while any recording runs, otherwise "Stop Watching for Meetings" / "Start Watching for Meetings" (D4). While a recording runs, the watch toggle stays below the first divider with the same label, icon and shortcut (A7); it is one private `watchToggle` property that `sessionControls` and `watchControls` render on complementary conditions, so it appears exactly once in every state.

Integrated onto feat/gh-94-stop-detected-recording as 45b41bf8 (feat: put the stop and watch controls directly under the menu's status line); base 093c2cc0. Worker commit 309caa57 on wave/gh-94.4 was cherry-picked unchanged. Only `Sources/MenuBarView.swift` and the new `Tests/MenuBarViewSessionControlsTests.swift` changed.

stage: impl-review - ran [22:27:19..22:29:37] SHIP, 0 findings, 1 draw (correctness; panel rule: one view, no shared state); receipt /tmp/impl-review-receipt-846594bd1b60-gh-94-stop-a-detected-meeting-recording-by.4.json (model: codex gpt-5.6-sol xhigh)
stage: wave-join - ran (cherry-pick of 1 commit, no collision; built concurrently with task .3 in its own worktree)

Tier: session (jev-unavailable(no_key)); explicit invocation: opus at xhigh; actual model: claude-opus-5-5 (host-reported model id; effort not exposed by the host)

Gates (logs under /private/tmp)
- baseline: green via handoff (verified at 86a651a4; since then only `.flow/` paths changed). Lint baseline exit 0 (`mt-gh94-t4-lint-baseline.log`).
- Task acceptance command (`mt-gh94-t4.log`) exit 0, 62 tests, all 5 new ones included.
- `MenuBarJobMenuTests` (`mt-gh94-t4-jobmenu.log`) exit 0, 6 tests (also constructs `MenuBarView`; the acceptance filter does not match its name).
- Conductor's integrated verify on the target (`mt-gh94-verify-t4.log`, filter "MenuBarView|MenuBarJobMenu|WatchingControllerStopRecording") exit 0, 73 tests.
- `./scripts/lint.sh` with the pinned tools (`mt-gh94-t4-lint.log`) exit 0, 0 violations, 0/708 files to format.
- `./scripts/pre-push.sh --with-appstore` (`mt-gh94-t4-prepush.log`) exit 0, both release variants, 0 warnings; the extra `body` section passed the 300 ms type-check budget.
- `flowctl gate classify` returned FULL (Swift changed). No GATE_SKIPPED lines.
- Mutation check (`/tmp/mt-gh94-tick/t4-mutants.sh`): each of 3 mutants turned the new suite red (pre-change layout; toggle duplicated below the divider plus both shortcuts changed; toggle dropped below the divider while recording); source restored byte-identically.
- Not run: CI's `swiftlint analyze` (needs a clean xcodebuild).

Tests per acceptance criterion (Tests/MenuBarViewSessionControlsTests.swift)
- Stop closure set: testWhileRecordingStopRecordingIsTheFirstLineUnderTheStatus (lines in document order begin [status, "Stop Recording"]; tapping the first button calls the stop closure once and `onStartStop` never).
- Watching / idle / error: testWithoutARecordingTheWatchToggleIsTheFirstLineUnderTheStatus.
- Recording keeps Stop Watching below the first divider: testWhileRecordingStopWatchingStaysBelowTheFirstDivider; exactly once in every state: testTheWatchToggleAppearsExactlyOnceInEveryState.
- Shortcuts unchanged ("." and "s"): testKeyboardShortcutsAreUnchanged.
- Existing `MenuBarViewTests` (57) unchanged and green: none pinned the old position.

Decisions (worker, rule 6)
- `watchControls` shows the toggle when the stop closure is set, the exact complement of `sessionControls`' condition, so the toggle appears once even when the status says recording but no stop closure was passed.
- The planned pause / resume control is not in the code yet, so nothing was moved under "Stop Recording"; the `sessionControls` doc comment says a control added there goes on its own line.
- The body's hoisting note was kept as is.
- The shortcut test walks the view value with `Mirror` for `KeyEquivalent`s because ViewInspector 0.10.5 has no keyboard-shortcut reader; if a ViewInspector upgrade breaks something, look at this test first.
- The test helper takes `recording: Bool` and a `Taps` recorder instead of closure literals (an unlabeled trailing closure bound to the wrong parameter at the first run; SwiftLint's `trailing_closure` rule flags the labelled form).

No feature map exists (`.flow/features/` absent), so there is no mapped route to update.

stage: plan-sync - skipped(config: planSync.enabled=false)
## Evidence
- Commits: 45b41bf8538582f1e3f12f626a26cbc0ab6eb6ed
- Tests: worker (wave/gh-94.4): cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "MenuBarView" > /private/tmp/mt-gh94-t4.log 2>&1 (exit 0, 62 tests, 5 new), worker (wave/gh-94.4): cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "MenuBarJobMenu" > /private/tmp/mt-gh94-t4-jobmenu.log 2>&1 (exit 0, 6 tests), worker (wave/gh-94.4): PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh > /private/tmp/mt-gh94-t4-lint.log 2>&1 (exit 0, 0 violations, 0/708 files to format), worker (wave/gh-94.4): ./scripts/pre-push.sh --with-appstore > /private/tmp/mt-gh94-t4-prepush.log 2>&1 (exit 0, both release variants, 0 warnings), worker (wave/gh-94.4): bash /tmp/mt-gh94-tick/t4-mutants.sh (3 mutants, each turned the new suite red; source restored byte-identically; logs /private/tmp/mt-gh94-t4-mutant-*.log), conductor integrated verify (feat/gh-94-stop-detected-recording @ 45b41bf8): cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "MenuBarView|MenuBarJobMenu|WatchingControllerStopRecording" > /private/tmp/mt-gh94-verify-t4.log 2>&1 (exit 0, 73 tests), impl-review receipt: /tmp/impl-review-receipt-846594bd1b60-gh-94-stop-a-detected-meeting-recording-by.4.json -> SHIP (codex gpt-5.6-sol xhigh, 1 draw: correctness SHIP, 0 findings)
- PRs: