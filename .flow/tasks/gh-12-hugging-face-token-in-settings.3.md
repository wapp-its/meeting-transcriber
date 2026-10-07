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
The token saved in Settings now reaches every WhisperKit Hub request: `EngineController` points the engine's provider at `AppSettings.huggingFaceToken`, read at each request. A load Hugging Face refuses is named in Settings under "Load Model" and in a failed job's error. A request with a token gets "Hugging Face rejected the saved token. ...", one without gets "Hugging Face refused access without a token. ...". Any other failure keeps "WhisperKit model not loaded".

Tier: session (jev-unavailable(no_key)) (model: claude-opus-5-5)

stage: implement - ran (model: claude-opus-5-5; parallel-wave worker in lane/gh-12-hf-token.3, commits 997c977b and 7a966098 integrated by fast-forward, SHAs unchanged)
stage: impl-review - ran [2026-10-07T00:08Z..2026-10-07T00:22Z] (model: codex gpt-5.6-sol xhigh; round 1 three-draw fan-out, correctness and integration NEEDS_WORK on one P1 finding, contracts SHIP, validator kept it; one fix commit 07c04956; round 2 single re-review SHIP "Prior findings: all fixed", R1 to R6 met; 2 of 8 rounds; receipt /tmp/impl-review-receipt-2258e1b40fef-gh-12-hugging-face-token-in-settings.3.json, attempts a15d1cfe16a04972984745ace5988a06 and 7d327347 recorded in .flow/specs/gh-12-hugging-face-token-in-settings.json)
stage: plan-sync - skipped(config: planSync.enabled=false)

### Review finding fixed (round 1, P1, R5)
A load parked in its download when the user switched models, whose owner was then cancelled, wrote its eventual refusal into `lastLoadFailure` after `applyModelVariant` had cleared it, so Settings showed the old model's refusal under the new model's "Load Model". Fix (07c04956): the download `catch` records the failure only while the attempt's snapshotted variant and origin still equal the current selection. Pinned by `WhisperKitEngineSupersededLoadFailureTests` (own file, because `WhisperKitEngineModelSourceTests.swift` is 8 lines under the 600-line cap): red before (`XCTAssertNil failed: "tokenRejected"`), green after. Captured as a bug-track memory entry.

### What changed
- New `WhisperKitLoadFailure` (`.tokenRejected`, `.tokenRequired`) with the spec's exact messages as `errorDescription`, and `classify(_:tokenSent:)`. The reflected-name match `isRejectedToken` moved here from `WhisperKitModelSource` and is `private`, because `classify` is its only caller.
- `WhisperKitModelSource.classifyingHubFailure(token:_:)` wraps the variant download and both `makePipe` closures. The token is read once per step and handed to the step, so the token sent and the token judged are the same read.
- `WhisperKitEngine.lastLoadFailure` is cleared at the start of `performLoad` and when `applyModelVariant` changes the selection; the download `catch` sets it from `error as? WhisperKitLoadFailure` only for the still-selected model. `ensureModel` throws it ahead of `TranscriptionError.modelNotLoaded`. The local-snapshot branch records nothing, because its fallback download makes the same request and reports it.
- `TranscriptionSettingsView.whisperKitLoadFailureLine` is a red caption in the `.unloaded` case after "Load Model", shown only with WhisperKit selected. New identifier `A11yID.whisperKitLoadFailureMessage`, not on any `/ui/press` or `/ui/type` allowlist.
- `EngineController.init` sets `whisperKit.hubToken = { [settings] in settings.huggingFaceToken }`.
- README "Custom WhisperKit models" gains one paragraph naming the token field and the Keychain, and saying that with the field empty models download anonymously and a token in `HF_TOKEN` or `~/.cache/huggingface/token` is not used.
- Feature route (for the feature map): Settings → Transcription → engine WhisperKit → status area, the new red line under "Load Model" after a refused load.

### Tests (R5 error cases, R3/R4 wiring)
- `WhisperKitLoadFailureTests` (3): the refusal (`Hub.HubClientError.authorizationRequired`) gives `.tokenRejected` with a token sent and `.tokenRequired` without; `httpStatusCode(401)`, `httpStatusCode(500)`, `fileNotFound`, a `URLError` and an unrelated error give nil either way; each case's `errorDescription` and `localizedDescription` equal the exact spec message. Replaces the two `isRejectedToken` tests removed from `WhisperKitHubTokenTests`.
- `WhisperKitEngineModelSourceTests` (3 new): a refusal in the download (`.tokenRejected`) or in the pipe (`.tokenRequired`) sets `lastLoadFailure`, leaves `.unloaded`, and makes `transcribeSegments` throw that failure with its message; a model change clears it, and so does a later successful load; a `URLError` download failure leaves it nil and transcription throws `TranscriptionError.modelNotLoaded`.
- `WhisperKitEngineSupersededLoadFailureTests` (2, from the review fix).
- `EngineSettingsRuntimeSyncTests.test_whisperKitHubToken_isTheSavedToken`, on an in-memory `HuggingFaceTokenStoreFake`: `EngineController(settings:).whisperKit.hubToken()` returns the saved token, and `""` after `removeHuggingFaceToken()`.
- `TranscriptionSettingsHuggingFaceTokenTests.testTheLoadFailureLineNamesARefusalForWhisperKitOnly`: the line shows the refused engine's message, is absent for a fresh engine, and absent with Parakeet selected.
- Mutation check (worker, measured): five breaks applied together (no clear in `performLoad`, no clear in `applyModelVariant`, `ensureModel` always throwing `modelNotLoaded`, no wiring in `EngineController`, no engine check in the view) each failed its own assertion: 4 tests red, 8 failures; files restored and checksum-verified.

### Live test (opt-in, worker, fresh scratch home, rc=0, 3 tests), result lines verbatim
- `[HFLive] made-up token: error=MeetingTranscriber.WhisperKitLoadFailure.tokenRejected message=Hugging Face rejected the saved token. Check that it is valid and has access to this model, or remove it to download anonymously.`
- `[HFLive] tokenizer fetch, made-up token: error=MeetingTranscriber.WhisperKitLoadFailure.tokenRejected`
- `[HFLive] anonymous: variant=openai_whisper-tiny downloaded, tokenizerCachedBefore=false tokenizerLoaded=true with HF_TOKEN set to a made-up OAuth-shaped token`
The tokenizer-fetch case is one beyond the task's plan: it is the only test that reaches the production `makePipe` wrapping. That it would fail without the change is inferred from task .1's live result (the raw Hub error surfaced there), not measured by a live break.

### Gates (measured)
- Worker, lane 3 at 7a966098: baseline (task filter) rc=0, 531 tests; after rc=0, 538 tests; live test rc=0 (3 tests); `./scripts/lint.sh` (pinned SwiftFormat 0.63.0, SwiftLint 0.65.1) 0 violations; `./scripts/pre-push.sh --with-appstore` both release builds complete.
- Review wrapper, lane 3 at 07c04956: focused run `WhisperKitEngineSupersededLoadFailure|WhisperKitEngineModelSource|WhisperKitLoadFailure|TranscriptionSettingsHuggingFaceToken|EngineSettingsRuntimeSync` rc=0 (42 tests); lint 0 violations in 670 files.
- Conductor, integrated spec branch at 07c04956: serial `--filter "WhisperKitEngineTests/testTranscribe"` rc=0 (2 tests), then `CFFIXED_USER_HOME=/private/tmp/gh12-qc/home swift test --parallel --filter "WhisperKitLoadFailure|WhisperKitEngine|WhisperKitHubToken|WhisperTokenizerCache|EngineSettingsRuntimeSync|TranscriptionSettings|AppSettings|SettingsInteraction|SettingsView|RPC"` rc=0, 540 tests (log /private/tmp/gh12-qc/verify3.log).
- Not run per task: CI's `swiftlint analyze` (`unused_declaration`), which needs an xcodebuild clean build-for-testing; CI runs it on the PR. `pre-push.sh` was not re-run after the two-line review fix; the conductor runs it once on the final head at quiesce.

### For the PR body (behaviour change, spec D5)
WhisperKit downloads no longer use a token from `HF_TOKEN`, `HUGGING_FACE_HUB_TOKEN`, `HF_TOKEN_PATH`, `$HF_HOME/token`, `~/.cache/huggingface/token` or `~/.huggingface/token`. Anyone who relied on one saves it in Settings → Transcription → "Hugging Face token" instead. With the field empty, every WhisperKit Hub request is anonymous.

### Follow-ups
- `CLAUDE.md`, Architecture Notes ("An already-fetched WhisperKit model loads without the Hub"), still says WhisperKit fetches the tokenizer from the Hub itself; the fetch now runs through `HubTokenScopedWhisperKit` with the app's token. Not edited (fork rule).
- `WhisperKitEngineModelSourceTests.swift` is 8 lines under the strict `file_length` cap of 600; the next test for that class needs a new file (the review fix already started `WhisperKitEngineSupersededLoadFailureTests.swift`).
- FluidAudio (Parakeet, diarization) still reads only `HF_TOKEN` (spec Boundaries, unchanged).

### Notes
- The commit messages carry no `Task:` trailer and no spec id (fork rule, enforced by `submit.sh`).
## Evidence
- Commits: 997c977bfa65eefa0f266111a35884f59d1ed1e5, 7a966098f6dfb6ef8ce641a651c30ad319aa2ec1, 07c04956999a277674b9ba7ec2af42587abaf7b1
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh12-t3/home swift test --filter "WhisperKitEngineTests/testTranscribe" (worker: serial model pre-fetch; rc=0, 2 tests), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh12-t3/home swift test --parallel --filter "WhisperKitLoadFailure|WhisperKitEngine|WhisperKitHubToken|WhisperTokenizerCache|EngineSettingsRuntimeSync|TranscriptionSettings|AppSettings|SettingsInteraction|SettingsView|RPC" (worker, lane 3 at 7a966098: baseline rc=0 531 tests; after rc=0 538 tests), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh12-t3/live-home MEETINGTRANSCRIBER_HF_LIVE=1 swift test --filter WhisperKitHubTokenLiveTests (worker: rc=0, 3 tests, fresh home, network), PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh (worker and review wrapper: 0 violations), ./scripts/pre-push.sh --with-appstore (worker at 7a966098: both release builds complete), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh12-rev3/home swift test --parallel --filter "WhisperKitEngineSupersededLoadFailure|WhisperKitEngineModelSource|WhisperKitLoadFailure|TranscriptionSettingsHuggingFaceToken|EngineSettingsRuntimeSync" (review wrapper, lane 3 at 07c04956 after the fix: rc=0, 42 tests), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh12-qc/home swift test --filter "WhisperKitEngineTests/testTranscribe" (conductor, integrated spec branch at 07c04956: rc=0, 2 tests), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh12-qc/home swift test --parallel --filter "WhisperKitLoadFailure|WhisperKitEngine|WhisperKitHubToken|WhisperTokenizerCache|EngineSettingsRuntimeSync|TranscriptionSettings|AppSettings|SettingsInteraction|SettingsView|RPC" (conductor, integrated spec branch at 07c04956: rc=0, 540 tests)
- PRs: