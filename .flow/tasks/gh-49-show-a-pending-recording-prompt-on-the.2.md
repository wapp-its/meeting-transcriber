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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
