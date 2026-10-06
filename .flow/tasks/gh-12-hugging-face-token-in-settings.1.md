---
satisfies: [R3, R4, R6]
---
# gh-12-hugging-face-token-in-settings.1 Send only the app's token on every WhisperKit Hub request

## Description
Route a token, supplied by a provider on the engine, to every Hugging Face request the WhisperKit path makes, and stop WhisperKit from ever falling back to the machine's own token: the variant download gets the token explicitly, the tokenizer is pre-fetched with it by a WhisperKit subclass, and the stale-token retry goes (spec "Token routing in the engine", D1, D2, D6, A1). The provider defaults to anonymous (`{ "" }`); connecting it to the Keychain is task 3, so this task stands alone and is the early proof point for the tokenizer approach.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WhisperKitModelSource.swift`, `app/MeetingTranscriber/Sources/WhisperKitEngine.swift`, `app/MeetingTranscriber/Sources/HubTokenScopedWhisperKit.swift` (new), `app/MeetingTranscriber/Sources/WhisperKitLocalSnapshot.swift` (doc comments only), `app/MeetingTranscriber/Tests/WhisperKitHubTokenTests.swift`, `app/MeetingTranscriber/Tests/WhisperTokenizerCacheTests.swift` (new), `app/MeetingTranscriber/Tests/WhisperKitHubTokenLiveTests.swift` (new), `app/MeetingTranscriber/Tests/WhisperKitEngineModelSourceTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/WhisperKitModelSource.swift, app/MeetingTranscriber/Sources/WhisperKitEngine.swift, app/MeetingTranscriber/Sources/HubTokenScopedWhisperKit.swift, app/MeetingTranscriber/Sources/WhisperKitLocalSnapshot.swift, app/MeetingTranscriber/Tests/WhisperKitHubTokenTests.swift, app/MeetingTranscriber/Tests/WhisperTokenizerCacheTests.swift, app/MeetingTranscriber/Tests/WhisperKitHubTokenLiveTests.swift, app/MeetingTranscriber/Tests/WhisperKitEngineModelSourceTests.swift]

### Approach
Tests first (the contracts are known up front), then the code.

1. **Tests.**
   - `WhisperTokenizerCacheTests` (new): `repository(logitsDim:encoderDim:)` equals `ModelUtilities.tokenizerNameForVariant(ModelUtilities.detectVariant(logitsDim:encoderDim:))` for every pair of logitsDim {51864, 51865, 51866, 50000} × encoderDim {384, 512, 768, 1024, 1280, 999}. Both functions are `internal` to WhisperKit: reach them with `@testable import WhisperKit` (the same mechanism as `@testable import ArgmaxCore` at `Tests/WhisperKitHubTokenTests.swift:1`). Then `searchPaths(...)` order on a temp layout, and `ensureLoadable(...)` with an injected fetch that records (repository, download base, token) and an injected trial load: nothing local → exactly one fetch carrying the given token, `""` included, then a trial of the first search path; a loadable `tokenizer.json` in any of the four paths → no fetch; found but the trial throws → one fetch into the first search path, then a second trial; the fetched copy's trial throws too → that error propagates; a throwing fetch → the error propagates; `mayFetch: false` with nothing loadable → `WhisperKitModelError.folderNotLoadable` and no fetch. Plus two cases with the real trial (`AutoTokenizerWrapper.from(modelFolder:hubApi:)`) on real files in a temp dir: a malformed `tokenizer.json` leads to a fetch (Hub origin) or `folderNotLoadable` (picked folder).
   - `WhisperKitHubTokenTests`: delete the four retry tests (`testRejectedTokenRetriesWithoutAToken`, `testAcceptedTokenDownloadsOnce`, `testOtherFailureIsNotRetried`, `testFailedRetryReportsTheRejectedToken`); keep the two `isRejectedToken` tests. Add the pin that D1 rests on: with `setenv("HF_TOKEN", <planted>, 1)` (previous value restored in `tearDown`), `HubApiWrapper(hfToken: nil).hubApi.hfToken == <planted>` (proves the machine lookup is live in this process) and `HubApiWrapper(hfToken: "").hubApi.hfToken == ""`.
   - `WhisperKitEngineModelSourceTests`: one test that an installed test source never calls the provider: `engine.hubToken = { XCTFail("…"); return "" }`, then load through the existing recording source (`Tests/WhisperKitEngineModelSourceTests.swift:85-130`).
2. **`WhisperKitModelSource`.** `production(for:hubToken:)` takes `hubToken: @escaping @MainActor () -> String = { "" }` (the anonymous default keeps its existing direct callers in `WhisperKitEngineModelOriginTests`, `WhisperKitLocalSnapshotTests` and `WhisperKitCustomModelSmokeTests` compiling unchanged) and passes it to `hub(repoID:hubToken:)` and `localFolder(path:bookmark:hubToken:)`. The hub download (`:85-98`) calls `WhisperKit.download(variant:from:token: hubToken(), progressCallback:)` directly. Both `makePipe` closures (`:99-101`, `:129-138`) read the token once and build `HubTokenScopedWhisperKit(WhisperKitConfig(model:modelFolder:), hubToken:, mayFetchTokenizer:)`, `true` for the Hub origin and `false` for a picked folder. Delete `downloadRetryingAnonymously` and its doc comment (`:32-59`); keep `isRejectedToken` (`:61-67`), task 3 uses it.
3. **`WhisperKitEngine`.** Add `var hubToken: @MainActor () -> String = { "" }`. Change `modelSource` (`:82-85`) to `(WhisperKitModelOrigin, @escaping @MainActor () -> String) -> WhisperKitModelSource`, default `WhisperKitModelSource.production(for:hubToken:)`, and have `performLoad` (`:215-217`) pass `hubToken`. The two `installModelSourceForTesting` overloads (`:313-320`) keep their signatures and ignore the provider, so existing engine tests compile unchanged.
4. **`HubTokenScopedWhisperKit.swift` (new).** The subclass and the `WhisperTokenizerCache` value type as specified in the spec's Architecture section (the five numbered steps). The subclass's designated `init(_ config: WhisperKitConfig, hubToken: String, mayFetchTokenizer: Bool) async throws` assigns its stored `let`s before `super.init(config)`. The override of `loadTokenizerIfNeeded()` calls super unchanged when `tokenizer != nil` or either dimension is nil, otherwise `try await WhisperTokenizerCache.ensureLoadable(...)` with `textDecoder.logitsSize`, `audioEncoder.embedSize`, `modelFolder`, `tokenizerFolder`, the token and `mayFetchTokenizer`, then super. Production closures: the trial is `AutoTokenizerWrapper.from(modelFolder: folder, hubApi: HubApiWrapper(downloadBase: tokenizerFolder, hfToken: token))` (local parsing only), the fetch is `HubApiWrapper(downloadBase: tokenizerFolder, hfToken: token).snapshot(from: .init(id: repository), matching: ["config.json", "tokenizer_config.json", "tokenizer.json"])`, the files `LanguageModelConfigurationFromHub` reads. Doc comment: why the subclass exists (spec A1), that super is reached only after a passing trial because WhisperKit's local branch falls back to a machine-token fetch on any error, and when to delete it.
5. **`WhisperKitLocalSnapshot`.** Update the doc comments at `:42-47` and `:67-72` that say WhisperKit fetches the tokenizer from the Hub itself.
6. **Live test (new, opt-in).** `WhisperKitHubTokenLiveTests`, skipped unless `MEETINGTRANSCRIBER_HF_LIVE=1` (gating pattern: `Tests/WhisperKitCustomModelSmokeTests.swift:17-24`). (a) With `HF_TOKEN` set in-process to a made-up value, `WhisperKitModelSource.production(for: .stock, hubToken: { "" })` downloads `openai_whisper-tiny`, `makePipe` returns a pipe whose `tokenizer` is non-nil. (b) With `hubToken: { "hf_madeUpInvalidToken000" }`, the download throws an error for which `isRejectedToken` is true. Run it once under a fresh scratch home (empty Documents, so no tokenizer is cached) and quote its result lines in the done summary.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WhisperKitModelSource.swift:1-141`: the whole boundary
- `app/MeetingTranscriber/Sources/WhisperKitEngine.swift:82-140, 208-256, 311-320`: source, load path, test installers
- WhisperKit checkout (after `swift build`, under `app/MeetingTranscriber/.build/checkouts/WhisperKit/Sources/`): `WhisperKit/Core/WhisperKit.swift` `init` (~:62-100), `loadModels` and `loadTokenizerIfNeeded` (~:390-490); `WhisperKit/Utilities/ModelUtilities.swift` `loadTokenizer` (~:17-75), `detectVariant` and `tokenizerNameForVariant` (~:128-205)
- `app/MeetingTranscriber/Tests/WhisperKitHubTokenTests.swift`
- `app/MeetingTranscriber/Tests/WhisperKitEngineModelSourceTests.swift:40-130`

**Optional** (reference as needed):
- ArgmaxCore `External/Hub/HubApi.swift` (~:90-160, token lookup and the 401/403 mapping), `HubWrapper.swift` (~:13-110)
- `app/MeetingTranscriber/Tests/WhisperKitCustomModelSmokeTests.swift`: env-gated live test shape

### Key context
- `WhisperKitConfig(modelToken:)` is not a way in: WhisperKit uses it only when no `modelFolder` is passed, and this app always passes one (spec Goal & Context).
- Swift 6 language mode with warnings as errors. The provider is `@MainActor`: read it inside the source's closures (formed in the `@MainActor` source type) and hand a plain `String` to the nonisolated subclass.
- The override runs inside `super.init`: WhisperKit's `init` calls `loadModels()` when `modelFolder` is set, and `loadModels()` calls `loadTokenizerIfNeeded()` last. That is why the token is a stored `let` assigned before `super.init`.
- Reach `super.loadTokenizerIfNeeded()` only after a passing trial load of the exact folder WhisperKit will pick. `ModelUtilities.loadTokenizer` wraps its local load in `do/catch` and on any error downloads through a client built without a token, which means the machine token; a mere `tokenizer.json` existence check is not enough (a malformed file, or a cache missing its config, takes that path). `WhisperTokenizerWrapper`'s wrapping init does not throw and is `internal`, so the public `AutoTokenizerWrapper.from(modelFolder:hubApi:)` is the whole of what can fail there.
- `WhisperKitLocalSnapshot.repoRoot` keeps using `HubApiWrapper.shared` only for paths; it makes no request.
- `WhisperKitLocalSnapshotTests.testProductionLocatesARealFetchedModel` and other model-download tests fail under a scratch `CFFIXED_USER_HOME` (no models there); that is environmental, not a regression.

### Verification
```bash
cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh12-t1/home swift test --parallel --filter "WhisperKitHubToken|WhisperTokenizerCache|WhisperKitEngine|WhisperKitLocalSnapshot|EngineSettingsRuntimeSync" > /private/tmp/gh12-t1/unit.log 2>&1
```
```bash
cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh12-t1/live-home MEETINGTRANSCRIBER_HF_LIVE=1 swift test --filter WhisperKitHubTokenLiveTests > /private/tmp/gh12-t1/live.log 2>&1
```
Lint: `./scripts/lint.sh` with SwiftFormat 0.63.0 and SwiftLint 0.65.1 from `scripts/tool-versions.sh` on `PATH` (not installed globally; fetch the pinned release assets into a temp dir). Release parity: `./scripts/pre-push.sh`. Never pipe a test run into `tail`/`head`/`grep`; read the log file.
## Acceptance
- [ ] `downloadRetryingAnonymously` is gone, and no WhisperKit Hub call or pipe construction in `Sources/` passes a `nil` token or builds a plain `WhisperKit` pipe (grep `WhisperKit.download(`, `WhisperKit(WhisperKitConfig`).
- [ ] `WhisperTokenizerCacheTests` green: the repository mapping matches WhisperKit's internal `detectVariant` + `tokenizerNameForVariant` over the whole grid; the search-path order and every `ensureLoadable` branch hold (absent → one fetch with the given token, `""` included; loadable copy → no fetch; broken copy → fetch and re-trial; fetch or re-trial error → propagated; picked folder → `folderNotLoadable`, never a fetch), including the real-trial cases on a malformed `tokenizer.json`.
- [ ] `super.loadTokenizerIfNeeded()` is reached only after a passing trial (or for the unchanged `tokenizer != nil` / unknown-dimension cases), by reading the override.
- [ ] The empty-token pin in `WhisperKitHubTokenTests` is green: `hfToken: nil` picks up the planted `HF_TOKEN`, `hfToken: ""` stays empty.
- [ ] An engine with an installed test source loads without ever calling `hubToken`; every existing WhisperKit engine, model-source, model-origin and local-snapshot test is green (environmental model-download failures under a scratch home excepted and named).
- [ ] The opt-in live test ran once with network under a fresh scratch home: (a) `openai_whisper-tiny` downloaded and loaded with its tokenizer while `HF_TOKEN` held a made-up token and the provider returned `""`; (b) a made-up provider token was refused (`isRejectedToken` true). Its result lines are quoted in the done summary.
- [ ] `./scripts/lint.sh` (pinned tools) and `./scripts/pre-push.sh --with-appstore` are clean.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
