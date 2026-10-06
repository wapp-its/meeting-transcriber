---
satisfies: [R3, R4, R5]
---
# gh-12-hugging-face-token-in-settings.3 Wire the saved token to the engine and name a refused token

## Description
Connect the saved token to the engine, so R3 and R4 hold in the running app, and name a refused request in Settings and in a failed job (spec "Refused-token message"; R5; D4, D5, A5). Also the README note. Last in order because it joins task 1's engine provider with task 2's Keychain accessor and adds a line to the view task 2 extended.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/EngineController.swift`, `app/MeetingTranscriber/Sources/WhisperKitLoadFailure.swift` (new), `app/MeetingTranscriber/Sources/WhisperKitModelSource.swift`, `app/MeetingTranscriber/Sources/WhisperKitEngine.swift`, `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `README.md`, tests: `app/MeetingTranscriber/Tests/WhisperKitLoadFailureTests.swift` (new), `app/MeetingTranscriber/Tests/WhisperKitEngineModelSourceTests.swift`, `app/MeetingTranscriber/Tests/TranscriptionSettingsHuggingFaceTokenTests.swift`, `app/MeetingTranscriber/Tests/EngineSettingsRuntimeSyncTests.swift`, `app/MeetingTranscriber/Tests/WhisperKitHubTokenTests.swift`, `app/MeetingTranscriber/Tests/WhisperKitHubTokenLiveTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/EngineController.swift, app/MeetingTranscriber/Sources/WhisperKitLoadFailure.swift, app/MeetingTranscriber/Sources/WhisperKitModelSource.swift, app/MeetingTranscriber/Sources/WhisperKitEngine.swift, app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift, app/MeetingTranscriber/Sources/A11yID.swift, README.md, app/MeetingTranscriber/Tests/WhisperKitLoadFailureTests.swift, app/MeetingTranscriber/Tests/WhisperKitEngineModelSourceTests.swift, app/MeetingTranscriber/Tests/TranscriptionSettingsHuggingFaceTokenTests.swift, app/MeetingTranscriber/Tests/EngineSettingsRuntimeSyncTests.swift, app/MeetingTranscriber/Tests/WhisperKitHubTokenTests.swift, app/MeetingTranscriber/Tests/WhisperKitHubTokenLiveTests.swift]

### Approach
1. **Tests first.**
   - `WhisperKitLoadFailureTests` (new, `@testable import ArgmaxCore` for `Hub.HubClientError` as in `Tests/WhisperKitHubTokenTests.swift`): `classify(.authorizationRequired, tokenSent: true)` is `.tokenRejected`, with `tokenSent: false` it is `.tokenRequired`; `httpStatusCode(500)`, `fileNotFound`, a `URLError` and an unrelated error give nil; each case's `errorDescription` is the exact spec message.
   - `WhisperKitEngineModelSourceTests`: a source whose download throws `WhisperKitLoadFailure.tokenRejected` leaves `lastLoadFailure == .tokenRejected` and `modelState == .unloaded`, and `transcribeSegments` then throws that failure (its `localizedDescription` is the message); a following successful load clears it; `applyModelVariant` to another variant clears it; a non-auth download failure leaves it nil and transcription throws `TranscriptionError.modelNotLoaded`.
   - `EngineSettingsRuntimeSyncTests`: with an `AppSettings` built on an in-memory `HuggingFaceTokenStore` (task 2) and a saved token, `EngineController(settings:).whisperKit.hubToken()` returns it; after `removeHuggingFaceToken()` it returns `""`.
   - `TranscriptionSettingsHuggingFaceTokenTests`: with a WhisperKit engine whose load failed as above, `A11yID.whisperKitLoadFailureMessage` shows the exact message; absent when there is no failure and when Parakeet is selected.
2. **`WhisperKitLoadFailure.swift` (new).** The enum, its messages and `classify` as specified; style of `WhisperKitModelError` (`WhisperKitModelOrigin.swift:24-45`). Move `isRejectedToken` from `WhisperKitModelSource` onto `WhisperKitLoadFailure` (and its two tests in `WhisperKitHubTokenTests`, plus the live test's use), so the source depends on the failure type and not the other way round.
3. **Source.** One shared helper in `WhisperKitModelSource` (e.g. `classifyingHubFailure(token:_:)`) runs a Hub step, and on a thrown error rethrows `WhisperKitLoadFailure.classify(error, tokenSent: !token.isEmpty) ?? error`. The hub download and both `makePipe` closures (around the `HubTokenScopedWhisperKit` init, where the tokenizer fetch throws) go through it; no second copy of the catch.
4. **Engine.** `private(set) var lastLoadFailure: WhisperKitLoadFailure?`: set to `nil` at the top of `performLoad` (`WhisperKitEngine.swift:208-217`), set from `error as? WhisperKitLoadFailure` in its download `catch` (`:233-253`), set to `nil` in `applyModelVariant` when the selection actually changes (`:267-273`). `ensureModel` (`:286-298`) throws `lastLoadFailure ?? TranscriptionError.modelNotLoaded`. Do not set it in the local-snapshot branch (`:120-140`): that branch swallows errors by design and falls back to the download, which reports the refusal.
5. **Wiring.** In `EngineController.init` (`EngineController.swift:51-62`) set `whisperKit.hubToken = { [settings] in settings.huggingFaceToken }` before `syncEngineSettings()`.
6. **View.** In `engineStatusView`'s `.unloaded` case (`TranscriptionSettingsView.swift:375-408`), after "Load Model", the caption line in red when `settings.transcriptionEngine == .whisperKit` and `whisperKitEngine.lastLoadFailure` is set, identifier `A11yID.whisperKitLoadFailureMessage` (new constant next to `A11yID.swift:86-89`). Hoist it into its own property if the body's type-check slows.
7. **README.** In "Custom WhisperKit models" (`README.md:261`), one or two sentences: the optional Hugging Face token under Settings → Transcription for private or gated models, kept in the Keychain; with the field empty the app downloads anonymously and does not use `HF_TOKEN` or `~/.cache/huggingface/token`.
8. **Live test.** Tighten case (b) of `WhisperKitHubTokenLiveTests` to expect `WhisperKitLoadFailure.tokenRejected`, and rerun it once.
9. **Done summary.** State the behaviour change for the PR body (spec D5: a token from `HF_TOKEN`, `HUGGING_FACE_HUB_TOKEN`, `HF_TOKEN_PATH`, `$HF_HOME/token`, `~/.cache/huggingface/token` or `~/.huggingface/token` is no longer used; save it in the field instead) and the follow-up that `CLAUDE.md`'s Architecture note on the tokenizer fetch is now stale.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WhisperKitEngine.swift:120-140, 208-298, 515-525`
- `app/MeetingTranscriber/Sources/EngineController.swift:51-62`
- `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift:375-408`
- `app/MeetingTranscriber/Sources/WhisperKitModelOrigin.swift:24-45`
- `app/MeetingTranscriber/Tests/EngineSettingsRuntimeSyncTests.swift:13-60`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift:240-252`: a job's error text is the thrown error's `localizedDescription`
- `README.md:255-265`

### Key context
- `Hub.HubClientError` is internal to ArgmaxCore: production code matches it only through `WhisperKitLoadFailure.isRejectedToken` (reflected type name); tests reach it with `@testable import ArgmaxCore`.
- HTTP 401 and 403 both arrive as `authorizationRequired`, so "rejected" also covers a valid token without access to a gated model; the message says "valid and has access".
- Do not touch `CLAUDE.md` / `AGENTS.md` (fork rule).

### Verification
```bash
cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh12-t3/home swift test --parallel --filter "WhisperKitLoadFailure|WhisperKitEngine|WhisperKitHubToken|WhisperTokenizerCache|EngineSettingsRuntimeSync|TranscriptionSettings|AppSettings|SettingsInteraction|SettingsView|RPC" > /private/tmp/gh12-t3/unit.log 2>&1
```
```bash
cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh12-t3/live-home MEETINGTRANSCRIBER_HF_LIVE=1 swift test --filter WhisperKitHubTokenLiveTests > /private/tmp/gh12-t3/live.log 2>&1
```
Lint: `./scripts/lint.sh` with the pinned tools on `PATH`. Release parity: `./scripts/pre-push.sh --with-appstore`. Read the log files; never pipe a test run into `tail`/`head`/`grep`.
## Acceptance
- [ ] `WhisperKitLoadFailureTests` green: the classification table and the exact messages.
- [ ] Engine tests green: a refused download sets `lastLoadFailure` and makes transcription throw it; a later successful load and a model change clear it; a non-auth failure keeps `TranscriptionError.modelNotLoaded`.
- [ ] `EngineController` hands the engine the saved token (and `""` after Remove), checked without network.
- [ ] The Settings failure line shows the exact message for a refused load and is absent otherwise and for Parakeet.
- [ ] The opt-in live test ran once more: a made-up token now fails with `WhisperKitLoadFailure.tokenRejected`; result lines quoted in the done summary.
- [ ] README states the field, the Keychain, and that machine tokens are no longer used; `CLAUDE.md` / `AGENTS.md` untouched.
- [ ] The done summary carries the PR-body behaviour-change note (spec D5) and the stale `CLAUDE.md` follow-up.
- [ ] `./scripts/lint.sh` (pinned tools) and `./scripts/pre-push.sh --with-appstore` are clean.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
