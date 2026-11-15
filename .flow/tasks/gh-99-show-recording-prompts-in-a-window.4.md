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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
