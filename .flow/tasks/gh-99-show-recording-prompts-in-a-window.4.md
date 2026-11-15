---
satisfies: [R1, R2, R3, R4, R5, R6, R7, R8, R9]
---
# gh-99-show-recording-prompts-in-a-window.4 Show the open questions in the window, wired into the app, with docs

## Description
Puts it together: the pure show decision, the SwiftUI view with the accepted layout (D6 to D8), the controller that renders the decision into the `PromptPanel` from .1, counts the time left down every second and hides closed and answered questions, the wiring into the app, the live checks, and the docs (spec Architecture & Data Models, "What the window shows" and "Time left"; R1 to R9).

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/PromptWindowContent.swift` (new), `Sources/PromptWindowView.swift` (new), `Sources/PromptWindowController.swift` (new), `Sources/AppState+PromptWindow.swift` (new), `Sources/MeetingTranscriberApp+PromptWindow.swift` (new), `Sources/MeetingTranscriberApp.swift`, `Sources/A11yID.swift`, `docs/architecture/detection.md`, `docs/architecture-macos.md`, `Tests/PromptWindowContentTests.swift` (new), `Tests/PromptWindowViewTests.swift` (new), `Tests/PromptWindowControllerTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/PromptWindowContent.swift, app/MeetingTranscriber/Sources/PromptWindowView.swift, app/MeetingTranscriber/Sources/PromptWindowController.swift, app/MeetingTranscriber/Sources/AppState+PromptWindow.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp+PromptWindow.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/A11yID.swift, docs/architecture/detection.md, docs/architecture-macos.md, app/MeetingTranscriber/Tests/PromptWindowContentTests.swift, app/MeetingTranscriber/Tests/PromptWindowViewTests.swift, app/MeetingTranscriber/Tests/PromptWindowControllerTests.swift]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first for the decision and the controller; the view gets one wiring test per control.
1. **Decision** (`PromptWindowContent.swift`, pure): inputs are the setting, the open `ConsentQuestion?`, the open `MeetingEndQuestion?` (from .2) and the hidden ids; output is the ordered list of items, the countdown first, empty when the setting is off. An item's identity is its question's id, never the app or the text, so a new question about the same app with the same text is a new item and shows again after a ✕ on the earlier one.
2. **Input** (`AppState+PromptWindow.swift`): one computed, `Equatable` input built from the setting (.3), `pendingConsentQuestion` and the countdown question (.2), read when the app renders rather than at ask time: turning the setting on shows an open question, turning it off empties the list at once (R1), and no watch loop means nothing to show.
3. **View** (`PromptWindowView.swift`): small subviews per question kind, because a body over 300 ms of type-checking fails the build (`Sources/MeetingTranscriberApp.swift:105-115`). Layout and wording per D6 to D8: bold title, the body as posted, ✕ with the label "Hide this question" at the top right, the microphone tile only when one question shows, the buttons in the drawn order with the prominent one styled as the default but with no keyboard shortcut, "Ends in m:ss" with fixed-width digits, a divider between two questions. A11yIDs for Record, Ignore, Never for this app, Keep recording, Stop now and the ✕ of each kind.
4. **Controller** (`PromptWindowController.swift`): owns one `PromptPanel` (.1), places it with `PromptWindowPlacement` and `MenuBarIconFrame` (.1) whenever it is shown or its size changes, shows it with `orderFrontRegardless` and orders it out when the list is empty. It holds the hidden ids: ✕ adds the id and answers nothing (A4); an answer call (.2) that returns true adds the id at once, so the window closes without waiting for the loop's poll; one that returns false leaves the item (spec Edge Cases, "Between setting and parking"). The time left comes from the question's deadline and an injected clock (production: the current date), refreshed once per second only while a countdown shows, and never below 0:00; it feeds nothing back into the loop.
5. **Wiring** (`MeetingTranscriberApp+PromptWindow.swift`): a view modifier that creates the controller once and follows the input with `.onChange(of:initial: true)`, applied next to the captions `.onChange` (`Sources/MeetingTranscriberApp.swift:293-308`); that file (592 lines, its struct body about 392 of the 400 code lines `type_body_length` allows, 2026-11-15) gains one line.
6. **Docs**, in the same change: the consent prompt paragraph of `docs/architecture/detection.md` and the file table and menu bar sections of `docs/architecture-macos.md`; `CLAUDE.md` is not edited.

Tests:
- Decision: setting off → empty; one prompt; one countdown; both → countdown first; a hidden id hides only that question; a new id shows again after a ✕ on an earlier one; no loop → empty.
- View (ViewInspector, by A11yID): each button calls its answer with the right `ConsentAnswer` or `MeetingEndAnswer`; each ✕ hides and answers nothing; title and body as given; "Ends in 1:42" at 102 s before the deadline and "Ends in 0:00" after it.
- Controller with an injected clock and fake answer calls: true hides at once, false keeps the item, an empty list orders the panel out, the hidden set does not hide a new id.
- Live, in the Homebrew dev build with the debug RPC server on: the spec's Verification "Live" step and its real click, the frontmost app unchanged; record each result, or "blocked from verification" with the reason, in the done summary.

### Investigation targets
**Required** (read before coding):
- `Sources/AppState+ConsentPrompt.swift` — accessor pattern and the menu's answer call
- `Sources/MeetingTranscriberApp.swift:260-300` — where the captions panel is wired
- `Sources/MenuBarView.swift` — how the menu shows the open prompt (same texts)
- `Tests/GeneralSettingsSilencePromptTests.swift` — ViewInspector lookup by A11yID
- `docs/architecture/gui-testing.md` — wiring tests, live assertions, allowlists

**Optional** (reference as needed):
- `Sources/LiveCaptionsWindowController.swift:100-160` — show, hide and screen handling of a panel controller
- `docs/architecture/detection.md:8-14` — the consent paragraph to update

### Key context
- An `@Observable` change reaches an observer only after work already queued on the main actor (project memory, "Stale async answer queued ahead of the settings observer"). Read the setting from the live value when rendering, so a queued update can never show the window after the setting went off.
- The countdown question ends at most one poll after its end (the loop sleeps a poll between decisions, `Sources/WatchLoop+MeetingEnd.swift:137`); that is R6's bound, so no extra timer is needed for closing.
- The window stays off the `/ui/tree` window allowlist and its buttons off `/ui/press` (`docs/architecture/gui-testing.md`); the live checks use `/state.windows` and `POST /action/confirmBrowserConsent`.
- The App Store build has the window but no debug RPC, so its checks are the unit tests.

## Acceptance
- [ ] Decision and controller tests were written first and seen failing, then pass; each view wiring test fails when its control's action is unwired.
- [ ] Live: with the setting on, a simulated prompt shows the window in `/state.windows` (`isVisible`), answering it through `POST /action/confirmBrowserConsent` closes it, and the frontmost app is unchanged; the real click result is recorded, or reported as blocked from verification with the reason.
- [ ] `docs/architecture/detection.md` and `docs/architecture-macos.md` describe the window in the same change.
- [ ] Quick commands green; `./scripts/lint.sh` clean with the pinned tools; `./scripts/pre-push.sh --with-appstore` passes.

## Done summary
With Settings → General → "Show prompts below the menu bar icon" on, the "Record <App> meeting?" prompt and the "Meeting seems to have ended" countdown now also show in a small window below the menu bar icon. The window shows each question's texts and answers, "Ends in m:ss" counting down every second, and a ✕ that hides a question without answering it. Answers go through the same calls a notification tap uses, and the window closes at once when the app took the answer. One modifier line on the menu bar label wires it in, and the two architecture docs describe it in the same commit.


stage: implement - ran (model: claude-opus-5-5; delegated: 0)

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

### Acceptance

- AC1, test first and wiring tests. `0c315b7a` holds the decision, view and controller tests on their own; at that commit they did not compile ("cannot find type 'PromptWindowInput' in scope", "value of type 'AppState' has no member 'promptWindowInput'"). On `c8084922` they pass. Mutation rounds, each reverted before the commit:
  - View: all 7 controls unwired → `PromptWindowViewTests.testEachControlAsksForItsAnswerOrForHidingAndNothingElse` fails 7 times, once per control (Record, Ignore, Never, Keep recording, Stop now, both ✕).
  - Logic: 11 mutations in one run → 20 failures, each mutation caught by at least one test:
    - an answer taken does not hide → `testAnAnswerTakenHidesItsQuestionAtOnce`
    - a refused answer hides anyway → `testAnAnswerRefusedKeepsItsQuestion`
    - ✕ hides nothing → `testHidingAnswersNothingAndANewQuestionShowsAgain`
    - no timer → `testTheTimeLeftRefreshesEverySecondWhileACountdownShows`
    - placed only when first shown → placement count 1 instead of 3 in `testFollowsTheOpenQuestionsAndTheSetting`
    - an empty list leaves the panel up → "nothing left to show" in the same test
    - setting ignored → `testShowsTheOpenQuestionsCountdownFirstAndNothingWhileTheSettingIsOff` and "setting off"
    - the prompt shown before the countdown → the same content test
    - time left rounded down → `testTimeLeftCountsDownToZeroAndStaysThere` ("1:41", "0:00")
    - the app's input ignores the setting → `testTheAppsInputFollowsTheSettingAndTheCurrentLoop`
    - the wiring never renders → `testTheAppsWiringFollowsTheSettingAndAnswersThroughTheApp`
  - The app wiring test (`testTheAppsWiringFollowsTheSettingAndAnswersThroughTheApp`) came with the feat commit, not the test commit. It hosts the real `MeetingTranscriberApp.PromptWindowWiring` on an `AppState` with a test watch loop, follows the setting off/on/off/on, and taps Never. The loop's notifier then receives `.never` for that prompt's id, and the window closes. Dropping `controller.update()` makes it fail.
- AC2, live: **blocked from verification.** The steps are `/state.windows` showing `recording-prompts` with `isVisible`, `POST /action/confirmBrowserConsent` closing the window with the frontmost app unchanged, and a real click. They are blocked because the installed dev app cannot run branch code and is not replaced during a build, and a second copy of the meeting app is not started. The unit tests cover the same chain up to the panel: input → decision → controller → panel → answer call by id. Task .1 already measured the panel's first click and that the frontmost app stays unchanged, using a throwaway probe; that was not repeated here. Run them after the merge and `mt-update`.
- AC3, docs in the same commit (`c8084922`):
  - `docs/architecture/detection.md`: a "The prompt window (issue #99)" passage after the consent prompt paragraph.
  - `docs/architecture-macos.md`: 8 file-table rows, the Prompts group in the GeneralSettingsView row and in the Settings UI General row, and a paragraph in "Menu Bar Icon Animations".
- AC4, gates (see Verification).

### Verification

- baseline: green. At `a5fd687a` the Quick command passed (exit 0, 215 tests, 0 failures) and lint passed (0 violations).
- Quick command, with `-j 6` in both places: `cd app/MeetingTranscriber && mkdir -p .build/test-home && swift build --build-tests -j 6 && CFFIXED_USER_HOME="$PWD/.build/test-home" swift test -j 6 --filter '<the spec filter>'`. Result: exit 0, 231 tests, 0 failures on the final tree, which was then committed unchanged as `c8084922`.
- `./scripts/lint.sh` with the pinned tools: exit 0, 0 violations in 1287 files, 0/1308 files need formatting. The first run found 3 violations in the new files, all fixed: `file_name`, `type_name` for `ID`, and `attributes`.
- `./scripts/pre-push.sh --with-appstore` on `c8084922`: exit 0 ("OK — pre-push parity check passed"). The Homebrew and App Store release builds passed, and the local model helper built and passed its tests (21 tests, 3 skipped, 0 failures). The App Store build printed one warning, in the existing `Settings/Notification+SettingsWindow.swift`, which this task did not touch; the new files caused none.
- not run: `swiftlint analyze` (CI's `unused_declaration`). Every new declaration is used from production or a test. One shape to watch: `MeetingTranscriberApp.PromptWindowWiring` is a struct nested in `extension MeetingTranscriberApp`, which the `file_name` rule needs. It is referenced from the `MeetingTranscriberApp` struct body and from a test, not from inside an extension.
- not run: a look check. Per the spec's Verification, the look is checked after the merge.
- Privacy: no new log line. The tests use made-up prompts.

### Choices

- (1) An item's identity is a typed id per kind, `PromptWindowItem.QuestionID` (`.meetingEnd(String)`, `.consent(UUID)`): from the task text "identity is its question's id". It is named `QuestionID`, not `ID`, because the `type_name` lint requires at least 3 characters.
- (1) Controls draw as in an active window, `.environment(\.controlActiveState, .key)` on the view. D7 asks for the accent-coloured default button, and a throwaway probe measured that in a never-key panel of an inactive app `.borderedProminent` draws like a plain button. `testTheProminentButtonsDrawAsInAnActiveWindow` pins it.
- (1) Menu bar height is `max(shown menu bar, notch inset, status bar thickness)`, from task .1's note. `testMenuBarHeightIsTheShownMenuBarElseTheNotchElseTheStatusBar` pins it.
- (1) The Settings UI table row in architecture-macos.md gains "Prompts": the CLAUDE.md upkeep rule.
- (4) Window background follows the system appearance (`windowBackgroundColor`). Switch point: the `.background` in `PromptWindowView.body`. Test: none, because the look is checked after the merge.
- (4) The tile is SF Symbol `mic.fill` in white on an accent rounded square, shown only when one question is open. Switch point: the `if showsTile` block in `PromptRowText`. Test: `testEachQuestionShowsItsTextAndItsButtonsInTheDrawnOrder` checks that it shows only when one question is open.
- (6) Time left rounds whole seconds up, so "0:00" first shows at the deadline.
- (6) Hidden ids are cut down to the open questions on each render, so the set stays small.
- (6) The controller compares the measured size against the size it last placed for, not against the panel frame: the hosting view resizes the panel to new content by itself.
- (6) Fonts headline/callout, padding 14, corner radius 12, width 340 (the look is checked after the merge).
- (6) A11yID names `promptWindow*`, all kept off the `/ui/tree` and `/ui/press` allowlists, as the task requires.
- (6) The wiring modifier is nested in `extension MeetingTranscriberApp`, because the `file_name` rule needs a type or extension that matches the file name.

### For the conductor

- Live checks for after the merge and `mt-update`: `/state.windows` lists `recording-prompts` with `isVisible`; `POST /action/confirmBrowserConsent` closes it; the frontmost app is unchanged; a real click on "Ignore".
- If CI's `swiftlint analyze` reports `PromptWindowWiring` as unused: move the struct to the top level and keep an empty-bodied `extension MeetingTranscriberApp` in the file for `file_name`. Notes: `task-4-window.md` in this run's NOTES_DIR.
- Follow-ups: none filed.

Integrated verify on the spec branch: the spec's Quick command with -j 6 at c8084922 (fast-forward, commit ids unchanged), exit 0, 231 tests, 0 failures

stage: impl-review - ran [2026-11-15T19:17:06Z..2026-11-15T19:25:30Z] SHIP, three draws (correctness, contracts, integration), no findings (model: gpt-6.1-sol at xhigh)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 0c315b7a08ed261e2a16b08a39f7a478d2dabe01, c8084922ffbf38d848002990572779512846a57c
- Tests: cd app/MeetingTranscriber && mkdir -p .build/test-home && swift build --build-tests -j 6 && CFFIXED_USER_HOME="$PWD/.build/test-home" swift test -j 6 --filter 'PromptWindow|PromptPanel|MenuBarIconFrame|MeetingEndQuestion|WatchLoopMeetingEnd|NotificationManagerMeetingEndTests|NotificationManagerSchedulingTests|ConsentPromptCoordinatorTests|WatchLoopAskBeforeRecordingTests|WatchLoopBrowserConsentTests|AppStateConsentPromptTests|NamingWindowPolicyTests|GeneralSettings|AppSettingsTests|MenuBarIconCountdownTests' (exit 0; 231 tests, 0 failures; baseline 215, 0 failures at a5fd687a), ./scripts/lint.sh with pinned SwiftFormat and SwiftLint 0.65.1 (exit 0; 0 violations in 1287 files, 0/1308 files need formatting), ./scripts/pre-push.sh --with-appstore (exit 0; Homebrew and App Store release builds, local model helper build and tests 21 run, 3 skipped, 0 failures), live: /state.windows and POST /action/confirmBrowserConsent blocked from verification - the installed Dev app cannot run branch code and must not be restarted, and no second app copy may run, integrated verify: the spec's Quick command with -j 6 at c8084922 (fast-forward, commit ids unchanged), exit 0, 231 tests, 0 failures
- PRs: