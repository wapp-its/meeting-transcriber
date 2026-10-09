---
satisfies: [R3, R4]
---
# gh-49-show-a-pending-recording-prompt-on-the.2 Offer Record and Ignore for the open prompt at the top of the menu

## Description
Show the open recording prompt at the top of the menu bar menu with "Record" and "Ignore", wired to `AppState.answerConsentQuestion` from task .1 (spec "Architecture & Data Models", bullet "Menu section"; R3, R4).

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/MenuBarView.swift`, `Sources/A11yID.swift`, `Sources/MeetingTranscriberApp.swift`, `docs/architecture-macos.md`, `Tests/MenuBarViewConsentPromptTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, docs/architecture-macos.md, app/MeetingTranscriber/Tests/MenuBarViewConsentPromptTests.swift]

All source and test paths below are relative to `app/MeetingTranscriber/`.

### Approach
Write the ViewInspector tests first (the wiring contract is clear), then the view.

1. `Sources/MenuBarView.swift`: add as the LAST stored properties, after `let onQuit` (`:28`): `var consentQuestion: ConsentQuestion?` and `var onAnswerConsent: ((ConsentQuestion, Bool) -> Void)?`. Optional `var`s default to nil in the synthesized memberwise init, so the existing constructions in `Tests/MenuBarViewTests.swift` and `Tests/MenuBarJobMenuTests.swift` compile unchanged; a `let` with a default would drop out of the init.
2. A new hoisted `@ViewBuilder private var consentPrompt: some View`, shaped like `meetingInfo` (`:96-111`) and `statusHeader` (`:82-94`): when a question is set, its title (headline) and body (caption, secondary) in a leading `VStack` with the same horizontal padding, then a "Record" button (`record.circle`) calling `onAnswerConsent?(question, true)`, an "Ignore" button (`xmark.circle`) calling `onAnswerConsent?(question, false)`, then `Divider()`. Each button carries its `A11yID`. Make it the first line of `body` (`:56-78`). No keyboard shortcuts: r, s, m, n, p, o, comma, period and q are taken.
3. `Sources/A11yID.swift`: `static let consentPromptRecord = "consentPromptRecord"` and `static let consentPromptIgnore = "consentPromptIgnore"` next to `jobRetryButton` (`:55-60`), with a one-line comment that the identifiers carry no app name (reason at `:26-31`).
4. `Sources/MeetingTranscriberApp.swift` `menuBarContent` (`:133-160`): pass `consentQuestion: appState.pendingConsentQuestion` and `onAnswerConsent: { question, granted in appState.answerConsentQuestion(question, granted: granted) }` after `onQuit:`, as a closure literal like the neighbouring `onRecordMicrophone:` (a bare method reference of a `@MainActor` method may trip Swift 6 isolation checks). Read only single-member `AppState` accessors here (type-check budget note at `:111-118`).
5. `docs/architecture-macos.md:95` (the `MenuBarView.swift` row): add "open recording prompt with Record / Ignore". Do not edit `CLAUDE.md` (fork rule).

Tests, in `Tests/MenuBarViewConsentPromptTests.swift` (new: `MenuBarViewTests.swift` is at 980 lines, 20 below SwiftLint's `file_length` error even with the warning disabled). Build `MenuBarView` with the same arguments as `makeView` in `Tests/MenuBarViewTests.swift:32-60` (copy; it is private) plus the two new ones. One test per behaviour:
- no question: `find(viewWithAccessibilityIdentifier: A11yID.consentPromptRecord)` throws;
- with a question: `find(text:)` finds its title and its body;
- Record: tap it the way `Tests/MenuBarViewTests.swift:599-612` taps the Retry button; the closure ran once with the displayed question (same `id`) and `true`;
- Ignore: same with `false`.

### Investigation targets
**Required** (read before coding):
- `Sources/MenuBarView.swift:1-120` — properties, `body`, hoisted sections and the type-check note
- `Sources/MeetingTranscriberApp.swift:107-160` — `menuBarContent` and the scene budget note
- `Sources/AppState+ConsentPrompt.swift` — accessors from task .1
- `Tests/MenuBarViewTests.swift:1-60, 595-615` — view construction and identifier tap

**Optional:**
- `Sources/MenuBarView.swift:240-262` — why a menu-style menu bar extra renders each element as its own menu item

### Key context
- The menu is a menu-style `MenuBarExtra`: every `Text` and `Button` becomes its own menu item, and an `HStack` row does not lay out side by side. Some styling may be ignored by `NSMenu`; that is fine.
- A stale menu (question expired or replaced while open) is handled by task .1's identity check; do not add refresh machinery.
- Verification:
  - `mkdir -p /private/tmp/mt-gh49/home`
  - `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh49/home swift test --parallel --filter 'MenuBarViewConsentPromptTests|MenuBarViewTests|MenuBarJobMenuTests' > /private/tmp/mt-gh49/t2.log 2>&1` and read the log.
  - `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (fetch them into a temp dir if missing, never `brew install`).
  - `./scripts/pre-push.sh --with-appstore` (both variants in release; the menu-bar scene's type-check budget fails the build there if exceeded).

## Acceptance
- [ ] Without an open question the menu has no consent section (R3).
- [ ] With an open question the menu's first section shows its title and body as posted, then Record and Ignore (R3).
- [ ] Record and Ignore, found by `A11yID.consentPromptRecord` / `consentPromptIgnore`, call `onAnswerConsent` once with the displayed question and true / false (R4).
- [ ] The app scene passes `AppState.pendingConsentQuestion` and routes answers to `AppState.answerConsentQuestion`; existing `MenuBarView` constructions compile unchanged.
- [ ] `docs/architecture-macos.md` names the menu's consent section; `CLAUDE.md` untouched.
- [ ] `./scripts/lint.sh` and `./scripts/pre-push.sh --with-appstore` pass.


## Done summary
The menu bar menu now opens with the open "Record <App> meeting?" prompt when one is waiting: its title and body exactly as the notification posts them, then "Record" and "Ignore", then a divider above the status line. Each button hands the question it displayed to `AppState.answerConsentQuestion`, so a click on a menu that went stale answers nothing; without an open prompt the section is absent.

Tests per acceptance item (`Tests/MenuBarViewConsentPromptTests.swift`): no section without a question (`testWithoutAQuestionTheMenuHasNoConsentSection`: both identifiers absent, status line first); title, body, Record, Ignore, divider, then the status line, in that order (`testWithAQuestionTheMenuOpensWithItsTextThenRecordAndIgnore`); Record / Ignore found by `A11yID.consentPromptRecord` / `consentPromptIgnore` call `onAnswerConsent` once with the displayed question (same id) and true / false (`testRecordAnswersTheDisplayedQuestionWithYes`, `testIgnoreAnswersTheDisplayedQuestionWithNo`). Red first, observed: with the two properties in place and no section, the order test and both button tests failed and the no-question test passed. Existing `MenuBarView` constructions (`MenuBarViewTests`, `MenuBarJobMenuTests`, `MenuBarViewSessionControlsTests`) compile and pass unchanged.

Gates: baseline green (68 tests, `MenuBarViewConsentPromptTests|MenuBarViewTests|MenuBarJobMenuTests|MenuBarViewSessionControlsTests`). Final: same filter 72 tests rc 0; spec quick command 73 tests rc 0; `./scripts/lint.sh` with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 0 violations; `./scripts/pre-push.sh --with-appstore` rc 0 (both release builds, type-check budget enforced). `CLAUDE.md` untouched; `docs/architecture-macos.md` names the menu's prompt section.

Decisions:
- `consentQuestion` / `onAnswerConsent` sit just before `onQuit`, not after it as the task's step 1 said: SwiftLint `trailing_closure` (`--strict`) flagged `MenuBarViewConsentPromptTests.swift:59` and `MeetingTranscriberApp.swift:161` with the pair last, because a closure literal as the last argument is flagged unless the argument before it is a closure too. Before `onQuit` every label stays, nothing is suppressed, and existing constructions still compile because a defaulted memberwise parameter can be omitted in any position.
- The "with a question" test reads the menu in document order (the `MenuBarViewSessionControlsTests` pattern) so it pins "first section" and "then Record and Ignore" from the acceptance, and that gh-94's status line still follows the divider directly.
- One reviewer (correctness draw) per the impl-review panel rule: one area (the menu), no persisted or shared state, concurrency, security or data layout in the diff.
- The review ran with `CODEX_SANDBOX=workspace-write`, the owner's standing setting the conductor named; the reviewer left no files in the tree.
- Lint ran with the cached pinned binaries in `~/Library/Caches/MeetingTranscriber/lint-tools/bin` (versions checked: 0.63.0 / 0.65.1).

Tier: session (jev-unavailable(no_key)); project routing block: implementer opus at xhigh

stage: impl-review - ran [..2026-10-09T04:50:17Z] (codex:gpt-5.6-sol:xhigh, 1 draw correctness, SHIP, 0 findings; --validate had nothing to validate)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 4ee0773bbf6f30fc3f12805c73e177d40ad8a03e, 1b29c845d6b2fdc05c26b07b9742a27b2d118d30, 295d6f58823d5e8432435c449b057296d72865eb
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh49/home swift test --parallel --filter 'MenuBarViewConsentPromptTests|MenuBarViewTests|MenuBarJobMenuTests|MenuBarViewSessionControlsTests' (72 tests, rc 0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh49/home swift test --parallel --filter 'WatchLoopAskBeforeRecordingTests|MenuBarViewConsentPromptTests|MenuBarIconQuestionTests|AppStateConsentPromptTests|NotificationManagerSchedulingTests|ConsentPromptCoordinatorTests|MenuBarIconWatchingTests|WatchLoopBrowserConsentTests' (spec quick command, 73 tests, rc 0), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (0 violations, rc 0), ./scripts/pre-push.sh --with-appstore (rc 0)
- PRs: