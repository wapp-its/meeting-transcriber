---
satisfies: [R1, R2]
---
# gh-12-hugging-face-token-in-settings.2 Keychain-backed Hugging Face token and its Settings row

## Description
Add the Keychain-backed token to `AppSettings` and its write-only row next to the WhisperKit model picker (spec "Token storage" and "Settings row"; R1, R2; D3, A2, A4). No engine wiring here: task 3 connects the saved token to the engine. Independent of task 1 (disjoint files), so both can run in parallel.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/AppSettings.swift`, `app/MeetingTranscriber/Sources/AppSettings+HuggingFaceToken.swift` (new, also holds `HuggingFaceTokenStore`), `app/MeetingTranscriber/Sources/KeychainHelper.swift`, `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Tests/AppSettingsHuggingFaceTokenTests.swift` (new), `app/MeetingTranscriber/Tests/TranscriptionSettingsHuggingFaceTokenTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/AppSettings.swift, app/MeetingTranscriber/Sources/AppSettings+HuggingFaceToken.swift, app/MeetingTranscriber/Sources/KeychainHelper.swift, app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/AppSettingsHuggingFaceTokenTests.swift, app/MeetingTranscriber/Tests/TranscriptionSettingsHuggingFaceTokenTests.swift]

### Approach
1. **Tests first.**
   - `AppSettingsHuggingFaceTokenTests` (new; per-test defaults suite, pattern `Tests/AppSettingsClaudeAPIKeyTests.swift:1-60`; an in-memory `HuggingFaceTokenStore` for most cases): saving `"  hf_abc\n"` stores `hf_abc`, `huggingFaceToken` reads it back, `huggingFaceTokenSaved` is true, the draft and the problem are cleared; a whitespace-only draft stores nothing; remove deletes and the flag goes false; `refreshHuggingFaceTokenSaved()` reflects the store; with a store whose `save` returns false while an older token exists, the draft is kept, the problem reads "The token could not be saved to the Keychain." and `huggingFaceTokenSaved` stays true; with a failing `delete`, the problem reads "The token could not be removed from the Keychain."; no value in `defaults.dictionaryRepresentation()` equals the token. One round trip through `.keychain(account:)` on a unique account, deleted in `tearDown` (save, read back, delete, `KeychainHelper.read(key:)` nil).
   - `TranscriptionSettingsHuggingFaceTokenTests` (new; ViewInspector, settings built with an in-memory store, pattern `Tests/TranscriptionSettingsCustomModelTests.swift:27-105`): typing into the field (`find(viewWithAccessibilityIdentifier: A11yID.huggingFaceTokenField)` then `.find(ViewType.SecureField.self).setInput(...)`) writes `huggingFaceTokenDraft`; tapping Save stores the draft in the store; with a saved token, tapping Remove deletes it; Remove is absent when nothing is saved; with a failing store, the problem line (`A11yID.huggingFaceTokenProblem`) shows after Save; the row is absent with `transcriptionEngine = .parakeet` and present for both a stock model and the custom model.
2. **`KeychainHelper`** (`KeychainHelper.swift:19-52`). `save` and `delete` gain `@discardableResult` `Bool` results as specified (`delete` treats `errSecItemNotFound` as success) and log a failed delete like a failed save (account name and `OSStatus`, never the value). Existing callers stay unchanged.
3. **`AppSettings`.** Add `huggingFaceTokenStore: HuggingFaceTokenStore = .keychain(account: "huggingFaceToken")` to `init` after `claudeAPIKeyAccount` (`AppSettings.swift:634-642`), stored as `@ObservationIgnored let huggingFaceTokenStore` (internal, so the extension file can reach it) with a doc comment pointing at `apiKeyAccount`'s reasoning (`:125-131`). Add the stored, non-persisted `var huggingFaceTokenDraft = ""`, `var huggingFaceTokenSaved = false` and `var huggingFaceTokenProblem: String?` (no `didSet`, nothing in `UserDefaults`).
4. **`AppSettings+HuggingFaceToken.swift` (new).** `HuggingFaceTokenStore` (four closures plus `static func keychain(account:)`), then `huggingFaceToken`, `saveHuggingFaceTokenDraft()`, `removeHuggingFaceToken()` and `refreshHuggingFaceTokenSaved()` as specified. Keychain pattern: `openAIAPIKey` at `AppSettings.swift:560-568`. Doc comment on `huggingFaceToken`: the one accessor for the token, read only right before a Hugging Face request, also meant for issue #9's model search.
5. **View.** A hoisted `huggingFaceTokenRow` appended at the end of `whisperKitModelPicker` (`TranscriptionSettingsView.swift:74-89`), so it sits inside the WhisperKit-only branch (`:61-72`) and shows for stock and custom models alike. `SecureField` bound to `$settings.huggingFaceTokenDraft` with `.onSubmit { settings.saveHuggingFaceTokenDraft() }`; a Save button disabled while the trimmed draft is empty; a Remove button only while `huggingFaceTokenSaved`; the caption from the spec, with `.onAppear { settings.refreshHuggingFaceTokenSaved() }` as at `:122-130`; the problem line when `huggingFaceTokenProblem` is set.
6. **`A11yID`.** `huggingFaceTokenField`, `huggingFaceTokenSaveButton`, `huggingFaceTokenRemoveButton`, `huggingFaceTokenProblem` next to the WhisperKit entries (`A11yID.swift:86-89`). No `/ui/press` allowlist entry.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/AppSettings.swift:118-140, 555-590, 630-645`: accounts, Keychain-backed keys, init
- `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift:23-130, 167-212`: section layout, refresh-on-appear pattern, custom model fields
- `app/MeetingTranscriber/Sources/KeychainHelper.swift`
- `app/MeetingTranscriber/Tests/TranscriptionSettingsCustomModelTests.swift`
- `app/MeetingTranscriber/Tests/AppSettingsClaudeAPIKeyTests.swift:1-70`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/RPCSettingsStateTests.swift:200-240`: exact settings allowlist that keeps secrets out of `/state`

### Key context
- Never read `huggingFaceToken` (the Keychain data) in a view body or in `AppSettings.init`. Existing view tests build `AppSettings(defaults:)` with the production store, and a test binary reading the app's own Keychain item raises a prompt that blocks `swift test` (`AppSettings.swift:125-131`; spec A2). `exists` is an attribute-only query and is fine from `.onAppear` (ViewInspector does not run `.onAppear` unless a test asks it to).
- Keep the section's direct children unchanged (`TranscriptionSettingsView.swift:31-51`): some existing tests locate controls by position, and CI fails a body that takes over 300 ms to type-check.
- Do not add the new properties to `AppSettings+RPC`. `RPCSettingsStateTests.test_snapshot_settingsKeysAreExactlyTheAllowlist` must stay green unchanged.
- ViewInspector reads `@State` from a copy (CLAUDE.md "GUI Testing", point 2); that is why the draft lives on `AppSettings`.
- `AppSettingsTests` sits at SwiftLint's 600-line cap, hence the separate test file.

### Verification
```bash
cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh12-t2/home swift test --parallel --filter "AppSettings|TranscriptionSettings|SettingsInteraction|SettingsView|RPCSettingsState" > /private/tmp/gh12-t2/unit.log 2>&1
```
Lint: `./scripts/lint.sh` with the pinned SwiftFormat/SwiftLint from `scripts/tool-versions.sh` on `PATH`. Release parity: `./scripts/pre-push.sh --with-appstore`. Read the log file; never pipe a test run into `tail`/`head`/`grep`.
## Acceptance
- [ ] `AppSettingsHuggingFaceTokenTests` green: trimmed save, read-back, empty-draft no-op, remove, refresh, failing save (draft kept, problem shown, older token still reported saved), failing delete (problem shown), no `UserDefaults` value equals the token, and one real Keychain round trip on a unique account.
- [ ] `KeychainHelper.save` / `delete` report success; a failed delete is logged with its status and without the value; existing callers unchanged.
- [ ] `TranscriptionSettingsHuggingFaceTokenTests` green: field writes the draft, Save stores it, Remove deletes it, Remove hidden without a saved token, problem line after a failing store, row hidden for Parakeet and shown for stock and custom WhisperKit models.
- [ ] No view body and no `AppSettings.init` reads the token's data (grep `huggingFaceToken` under `Sources/Settings/` shows only the draft, the saved flag, the problem and the save/remove/refresh calls).
- [ ] Existing `AppSettings*`, `TranscriptionSettings*`, `SettingsInteractionTests`, `SettingsViewTests` and `RPCSettingsStateTests` green, the RPC allowlist test unchanged.
- [ ] `./scripts/lint.sh` (pinned tools) and `./scripts/pre-push.sh --with-appstore` are clean.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
