---
satisfies: [R1, R4, R5, R7]
---
# gh-10-vocabulary-from-a-central-url.3 Settings controls for the vocabulary source and docs

## Description
Adds the Settings controls for the vocabulary source and the status line (spec R1, R4, R5, R7), passes the controller from task .2 into the Settings window, and updates the two docs that describe the vocabulary and the Settings tabs. One task because the controls, their wiring and their docs change together and are small.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/Settings/VocabularySourceSettingsView.swift` (new), `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift`, `app/MeetingTranscriber/Sources/SettingsView.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `docs/architecture-macos.md`, `README.md`, tests below
**Touches:** [app/MeetingTranscriber/Sources/Settings/VocabularySourceSettingsView.swift, app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift, app/MeetingTranscriber/Sources/SettingsView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/VocabularySourceSettingsTests.swift, app/MeetingTranscriber/Tests/TranscriptionSettingsVocabularyTests.swift, docs/architecture-macos.md, README.md]

### Approach
1. **New view struct** `VocabularySourceSettingsView` (its own `View`, not more properties in `TranscriptionSettingsView`, whose section sits near the 300 ms type-check limit; spec gh-17): a "Vocabulary source" `Picker` over `VocabularySource.allCases` bound to `settings.vocabularySource`; when `.url`: a `TextField` "Vocabulary URL" (prompt `https://…`) bound to `settings.remoteVocabularyURL`, a `SecureField` "Access token (optional)" bound to `settings.remoteVocabularyToken` (pattern: `OutputSettingsView.swift:179-187`), an "Update now" button calling `remoteVocabulary?.refreshNow()` and disabled while `isChecking` or the address is invalid, the status line `remoteVocabulary?.status.message(...)` (dates formatted `.abbreviated` date + `.shortened` time), and a caption naming the address forms from spec R5 (GitHub `raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`; GitLab `https://<host>/api/v4/projects/<id or URL-encoded path>/repository/files/<URL-encoded path>/raw?ref=<branch>`, token with `read_api` scope). Takes `settings` and an optional `RemoteVocabularyController` (nil in previews/tests hides the status line and disables the button).
2. **Insert it** in `TranscriptionSettingsView.transcriptionSection` (`TranscriptionSettingsView.swift:38-51`) as one new child directly before `customVocabularyRow`; show `customVocabularyRow` and `customVocabularyValidation` only when the source is `.file`. The section then has 9 children (ViewBuilder limit is 10). `TranscriptionSettingsView` gets `var remoteVocabulary: RemoteVocabularyController? = nil` so existing call sites compile unchanged.
3. **Pass it through**: `SettingsView` gains `var remoteVocabulary: RemoteVocabularyController?` (default nil) forwarded to `TranscriptionSettingsView` (`SettingsView.swift:69-74`); `MeetingTranscriberApp` passes `appState.remoteVocabulary` (`MeetingTranscriberApp.swift:257-275`).
4. **Identifiers** in `A11yID.swift` (next to `customVocabularyPathField`, `:84`): source picker, URL field, token field, update button, status text, and the local-file row (`customVocabularyFileRow` on the existing HStack). Do not add any of them to the `/ui/type` or `/ui/press` allowlists (a secure field must never be typable; the button needs no live driver).
5. **Docs**: `docs/architecture-macos.md` — file-table rows for the new source files (near `:119-121` and `:158-162`), the custom-vocabulary bullet (`:501`, file or URL source, one source at a time, cached copy), the Settings UI table's Transcription row (`:713`, add `remoteVocabulary?`); `README.md` — the custom-vocabulary feature bullet (`:89`) and the Transcribe row (`:254`). `CLAUDE.md` / `AGENTS.md` stay untouched (fork rule).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift:1-160` — section structure, file row, why sections are split
- `app/MeetingTranscriber/Tests/TranscriptionSettingsVocabularyTests.swift:1-140` — existing vocabulary view tests incl. the positional locator
- `app/MeetingTranscriber/Sources/Settings/OutputSettingsView.swift:150-190` — SecureField + Keychain-backed binding
- `app/MeetingTranscriber/Sources/SettingsView.swift:1-95` — dependency passing

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/SettingsInteractionTests.swift:40-60`, `:160-180` — picker/toggle wiring tests located by identifier
- `app/MeetingTranscriber/Sources/DebugRPCServer+UIType.swift:90-100` — the "never a secure field" allowlist invariant

### Key context
- `testWhisperKitVocabularyControlAttachesTheBoundedPriorityHelp` reaches the file row positionally (`.form().section(0).hStack(3)`); the new child shifts it. Change only its locator to the new `customVocabularyFileRow` identifier and keep its `.help()` assertion (CLAUDE.md § GUI Testing: identifier lookup is the shape to copy). Do not weaken or drop it.
- One ViewInspector wiring test per new control, located by `A11yID` (CLAUDE.md § GUI Testing layer 2): picker selection writes `vocabularySource`; URL `setInput` writes `remoteVocabularyURL`; token `setInput` writes the Keychain-backed token (inject a unique Keychain account into `AppSettings` and delete it in `tearDown`); "Update now" tap reaches the controller (controller with a fake fetcher and temp cache; assert the fetcher was called); status text equals the controller's message; the URL controls are absent for `.file` and the file row absent for `.url`.
- Measure the type-check time of the touched bodies: `cd app/MeetingTranscriber && swift build -Xswiftc -Xfrontend -Xswiftc -debug-time-function-bodies > <your scratch dir>/typecheck.log 2>&1`, then read the lines for `TranscriptionSettingsView` and `VocabularySourceSettingsView`; keep each well under 300 ms (gh-17 aimed for under 150 ms on the runner).
- The settings window renders only the selected tab; nothing here needs a live `/ui/*` driver.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<your scratch dir>/home swift test --parallel --filter "VocabularySourceSettings|TranscriptionSettings|SettingsView|SettingsInteraction|RemoteVocabulary" > <your scratch dir>/t3.log 2>&1` and read the log.
- `./scripts/lint.sh` with the pinned tools (see task .1).
- `./scripts/pre-push.sh --with-appstore` clean.

## Acceptance
- [ ] Settings → Transcription shows a "Vocabulary source" picker (Local file default); Local file shows today's file row and validation line unchanged; URL shows the address field, the secure token field, "Update now", the status line and the address-forms caption.
- [ ] One ViewInspector wiring test per new control, located by `A11yID`, asserting the `AppSettings` / Keychain write-back or the controller call; visibility per source is tested.
- [ ] The positional help-text test locates the file row by identifier and still asserts the help text.
- [ ] "Update now" is disabled while a check runs or the address is invalid; with no controller (nil) the status line is hidden and the button disabled.
- [ ] None of the new identifiers is on the `/ui/type` or `/ui/press` allowlist.
- [ ] `SettingsView` and `MeetingTranscriberApp` pass `appState.remoteVocabulary` through; existing call sites compile unchanged.
- [ ] `docs/architecture-macos.md` and `README.md` describe the URL source; `CLAUDE.md` / `AGENTS.md` untouched.
- [ ] Measured type-check times for the touched bodies stay well under 300 ms; focused tests, lint and `./scripts/pre-push.sh --with-appstore` pass.


## Done summary
Settings → Transcription now has a "Vocabulary source" picker. Local file is the default and shows the file row and its validation line as before. URL shows the address field, a secure access-token field bound to the Keychain-backed setting (clearing it deletes the item), "Update now", the controller's status line and a caption naming the GitHub and GitLab address forms. The controller travels from `AppState` through `SettingsView` and `TranscriptionSettingsView` into the new `VocabularySourceSettingsView`, and the architecture doc and README describe the URL source.

stage: impl-review - ran [2026-10-09T11:44Z..2026-10-09T11:52Z]

Tier: session (jev-unavailable(no_key)); implementer opus at xhigh (project routing block) · actual: claude-opus-5-5 (host metadata)

Verification (all measured on the committed code; the code files are byte-identical to the runs below, checked with `cmp` after the mutation runs):
- baseline: green. Before any edit the task's focused filter ran 173 tests with suite_rc=0, and lint found 0 violations in 721 files.
- `swift test --parallel --filter "VocabularySourceSettings|TranscriptionSettings|SettingsView|SettingsInteraction|RemoteVocabulary"` on HEAD: suite_rc=0, 181 tests (173 existing + 8 new), 0 failed. No model-download test sits inside this filter. Log: /private/tmp/mt-gh10-t3-final.log.
- `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1: 0/723 files need formatting, 0 violations.
- `./scripts/pre-push.sh --with-appstore`: passed; both the Homebrew and the App Store release builds completed with no warnings. Log: /private/tmp/mt-gh10-prepush3.log.
- Type-check times (`swift build -v -Xswiftc -Xfrontend -Xswiftc -debug-time-function-bodies`, local debug build; plain `swift build` printed no timing lines, `-v` does): `VocabularySourceSettingsView.body` 54.19 ms, `.updateControls` 9.00 ms, `.addressControls` 3.18 ms; `TranscriptionSettingsView.transcriptionSection` 30.23 ms, `.customVocabularyRow` 19.94 ms, `.engineStatusView` 21.76 ms, `.body` 1.29 ms. All well under the 300 ms limit and under gh-17's 150 ms aim. Log: /private/tmp/mt-gh10-typecheck.log.
- Mutation checks, then restored: passing nil instead of the controller from `TranscriptionSettingsView` and showing the file row for both sources turned the update-now, status, disabled and visibility tests red; disabling "Update now" only for a missing controller turned the "address without https" and "while a check runs" assertions red.
- Not run: `swiftlint analyze` (CI only). Every new `A11yID` constant is attached to a control and used by a test; `formatDate` and `addressFormsCaption` are referenced.

Tests per acceptance criterion (Tests/VocabularySourceSettingsTests.swift, rendered through `TranscriptionSettingsView` so the controller hand-over is under test):
- Picker writes `vocabularySource`: `testSourcePickerSelectionWritesTheSource`.
- Visibility per source (file row, path field and validation line only for Local file; URL field, token field, "Update now", status line and caption only for URL): `testEachSourceShowsOnlyItsOwnControls`.
- URL field writes `remoteVocabularyURL`: `testURLFieldWritesTheAddress`.
- Token field writes the injected Keychain account, and clearing it deletes the item (R5): `testTokenFieldWritesTheKeychainAndClearingItDeletesTheItem`.
- "Update now" reaches the controller (fake fetcher records the request): `testUpdateNowAsksTheControllerForACheck`.
- Status text equals the controller's message, with the date formatter written independently in the test: `testStatusLineShowsTheControllersMessage`.
- Disabled with no controller (status hidden too), for an address without https, and while a check runs; enabled when idle with a valid address: `testUpdateNowIsDisabledWithoutAControllerWhileCheckingAndForAnInvalidAddress`.
- None of the new identifiers is on the `/ui/type` or `/ui/press` allowlist: `testNoVocabularySourceIdentifierIsOnTheUIDriverAllowlists` (`#if !APPSTORE`).
- The positional help-text test now finds the file row by `A11yID.customVocabularyFileRow` and keeps its `.help()` assertion: `TranscriptionSettingsVocabularyTests.testWhisperKitVocabularyControlAttachesTheBoundedPriorityHelp`.

Review: Codex `gpt-5.6-sol` at `xhigh`, confirmed in the receipt (/tmp/impl-review-receipt-3dc1fc7d306f-gh-10-vocabulary-from-a-central-url.3.json). Round 1, three draws (correctness, contracts, integration), all SHIP with no findings; no validator pass was needed. The reviewers' own test runs hit Keychain writes denied by their sandbox; that is their environment, the same tests are green locally.

Decisions:
1. (rule 1) The new view is one child of `transcriptionSection`, directly before `customVocabularyRow`, so the section has 9 children. The file row and its validation line are hidden for `.url` by an `if` inside their own properties, so the child count does not change.
2. (rule 1) "Update now" is disabled with no controller, while `isChecking`, and when `RemoteVocabulary.validateAddress` fails; no address is re-parsed in the view.
3. (rule 1) Dates use `.abbreviated` date and `.shortened` time; the sentence itself comes from `RemoteVocabularyStatus.message(formatDate:)`.
4. (rule 4) Layout and order inside the new view; see the first ASSUME line. The token field follows the gh-12 token row's shape (a titled `SecureField` with `.roundedBorder`), with the same Keychain-backed binding as `OutputSettingsView`'s API key field.
5. (rule 4) Caption wording; see the second ASSUME line.
6. (rule 6) `SettingsView`'s forwarding is checked by the compiler only. `SettingsView` renders the selected tab alone and its `@State` selection starts at General, so ViewInspector cannot reach the Transcription tab through it. `TranscriptionSettingsView`'s forwarding is under test.
7. (rule 6) Acceptance criterion 5 (no new identifier on the UI driver allowlists) is pinned by a test rather than left to a comment.
8. (rule 6) The doc comment on `transcriptionSection` said view tests reach controls by position. That stopped being true when the only positional locator was re-pointed, so the sentence now names the new view instead.
9. (rule 1) Docs: the view's row sits next to `TranscriptionSettingsView`'s, the controller's next to `AppSettings+Vocabulary.swift`, and `RemoteVocabulary.swift` / `RemoteVocabularyFetcher.swift` / `RemoteVocabularyCache.swift` after `VocabularyFileAccess.swift`, near `WhisperVocabularyPrompt.swift`. Tasks .1 and .2 added those files without rows. `CLAUDE.md` and `AGENTS.md` are untouched.
10. (rule 1) The review ran with `CODEX_SANDBOX=workspace-write`, as the dispatch requires; no network or full access was granted. The reviewers left only flowctl's `.flow/` bookkeeping, which is committed.
11. (rule 1) Commits carry `Task:` trailers, following the precedent of tasks .1 and .2.

ASSUME: the URL controls are separate form rows in this order: address field, secure token field, "Update now", status line (caption font, secondary colour, also for a failure), address-forms caption · alternatives: B — status line beside the button on one row; C — failure lines in red · flip at: app/MeetingTranscriber/Sources/Settings/VocabularySourceSettingsView.swift:VocabularySourceSettingsView.updateControls · test: VocabularySourceSettingsTests.testEachSourceShowsOnlyItsOwnControls
ASSUME: the caption reads "A text file with one term per line. GitHub: https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>, with a GitHub token for a private repository. GitLab: https://<host>/api/v4/projects/<id or URL-encoded path>/repository/files/<URL-encoded file path>/raw?ref=<branch>, with a GitLab token with the read_api scope. The token is kept in the Keychain." · alternatives: B — the same forms as a `.help()` tooltip on the address field; C — a short caption pointing to the README · flip at: app/MeetingTranscriber/Sources/Settings/VocabularySourceSettingsView.swift:VocabularySourceSettingsView.addressFormsCaption · test: VocabularySourceSettingsTests.testEachSourceShowsOnlyItsOwnControls

Follow-ups (not part of this task):
- New user route: Settings → Transcription → "Vocabulary source". The repository has no `.flow/features/` map, so there is nothing to update.
- A live check against a real public and a real private repository file is the owner's (spec § Verification).
- Instruction conflicts, as in tasks .1 and .2: the impl-review skill says never to set `CODEX_SANDBOX` while the dispatch requires it, and the fork rule forbids spec ids in commit messages while the worker template adds `Task:` trailers.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 30feb7dadf64bf1f785484e77b5be66766f31fa6, efc93a4037575c1283e11323dcf1fa8a6ceac13f
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh10-home swift test --parallel --filter "VocabularySourceSettings|TranscriptionSettings|SettingsView|SettingsInteraction|RemoteVocabulary" (suite_rc=0, 181 tests), PATH=<pinned tools>:$PATH ./scripts/lint.sh (0 violations), ./scripts/pre-push.sh --with-appstore (passed)
- PRs: