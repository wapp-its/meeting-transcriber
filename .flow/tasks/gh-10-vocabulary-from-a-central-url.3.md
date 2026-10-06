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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
