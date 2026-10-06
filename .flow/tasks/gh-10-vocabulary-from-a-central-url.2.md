---
satisfies: [R1, R2, R3, R4, R6, R8]
---
# gh-10-vocabulary-from-a-central-url.2 Use the remote copy: settings, engine wiring and refresh controller

## Description
Wires task .1's pieces into the app: the new settings (source, address, Keychain token), the effective vocabulary the engines receive, and `RemoteVocabularyController`, which runs the checks, adopts valid downloads into the cache and publishes the status. After this task a URL source works end to end without UI (settable through `AppSettings`); task .3 adds the Settings controls.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/AppSettings.swift`, `app/MeetingTranscriber/Sources/AppSettings+Vocabulary.swift`, `app/MeetingTranscriber/Sources/EngineController.swift`, `app/MeetingTranscriber/Sources/RemoteVocabularyController.swift` (new), `app/MeetingTranscriber/Sources/AppState.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, tests below
**Touches:** [app/MeetingTranscriber/Sources/AppSettings.swift, app/MeetingTranscriber/Sources/AppSettings+Vocabulary.swift, app/MeetingTranscriber/Sources/EngineController.swift, app/MeetingTranscriber/Sources/RemoteVocabularyController.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Tests/AppSettingsRemoteVocabularyTests.swift, app/MeetingTranscriber/Tests/RemoteVocabularyControllerTests.swift, app/MeetingTranscriber/Tests/EngineSettingsRuntimeSyncTests.swift]

### Approach
Tests first (controller and settings have clear contracts: spec R1–R4, R6, R8).

1. **Settings** (`AppSettings.swift`, stored properties must live in the class body for `@Observable`): `vocabularySource` (UserDefaults key `vocabularySource`, default `.file`), `remoteVocabularyURL` (key `remoteVocabularyURL`, default ""), an in-memory observable `remoteVocabularyTokenRevision: Int`, `@ObservationIgnored private let remoteVocabularyTokenAccount: String` and `let remoteVocabularyCacheDirectory: URL`, both new `init` parameters with production defaults (`"remoteVocabularyToken"`, `AppPaths.remoteVocabularyCacheDirectory`), following `apiKeyAccount` / `defaultOutputDir` (`AppSettings.swift:125-131`, `593-599`, `634-642`). Init reads at `AppSettings.swift:684-690`.
2. **Token** (`AppSettings.swift`, in the class body next to `openAIAPIKey`, because it reads the `private` account and Swift lets an extension in another file see no `private` member): `remoteVocabularyToken` computed through `KeychainHelper` exactly like `openAIAPIKey` (`AppSettings.swift:560-569`: empty deletes the item), and its setter bumps `remoteVocabularyTokenRevision`. Never persisted elsewhere.
3. **Effective vocabulary** (`AppSettings+Vocabulary.swift`): `effectiveVocabularyPath` (local path for `.file`; for `.url` the path of `RemoteVocabularyCache.textFile(in: remoteVocabularyCacheDirectory, bundleID:, address:)` for the trimmed `remoteVocabularyURL`, or "" when the address is invalid) and `effectiveVocabularyBookmark` (local bookmark / nil). `EngineController.syncEngineSettings()` (`EngineController.swift:94-118`) uses these for both engines instead of `customVocabularyPath` / `customVocabularyBookmark`; `observeEngineSettings()` (`:123-144`) also reads `settings.vocabularySource` and `settings.remoteVocabularyURL`. Engines stay untouched.
4. **`RemoteVocabularyController`** (`@MainActor @Observable final class`, pattern: `UpdateChecker.swift:108-179` for the task/loop shape, `EngineController.swift:120-144` for self-rearming `withObservationTracking`). Init takes `settings`, a `RemoteVocabularyFetching` (default the URLSession fetcher), `debounce` (2 s), `interval` (60 min) and a `now` clock; the cache is built from `settings.remoteVocabularyCacheDirectory` and the bundle identifier. Publishes `status` and `isChecking`. API: `start()` (idempotent: delete this bundle's copies for other addresses, load/repair the copy for the configured address, set the status, arm the observer, check now when the source is URL and the address valid, then loop every `interval`) and `refreshNow()` (no-op while a check runs, when the source is Local file or the address is invalid; cancels a pending debounce).
   - Observer fires on `vocabularySource`, `remoteVocabularyURL`, `remoteVocabularyTokenRevision`: bump a generation, cancel the in-flight and pending checks, on an address change delete this bundle's copies for every other address (`discardAll(except:)`, spec R6; the engines already read only the new address's file), recompute the status, schedule a check after `debounce` if the source is URL and the address valid.
   - One check (generation g, address, trimmed token): re-read the copy with `cache.load(for:)` at the start of every check (never trust in-memory validators: the load is what drops validators for mismatched text); send its validators only when it returned some; await the fetcher; drop the result if the generation moved or the task was cancelled. Not modified → update `checkedAt` (no copy or no validators sent → failed, unexpected 304). Modified → validate with task .1's validation (invalid → failed, copy kept); identical bytes to the cached text → sidecar-only update (hash, validators, `checkedAt`; `updatedAt` kept), no text rewrite; otherwise `store` (`updatedAt` = `checkedAt` = now). A `store` throw → status failed "could not save", and the last good copy shown is whatever `cache.load(for:)` returns afterwards, so the status always names the text the engines actually read. Failed → keep the copy, status failed with the last good copy. Cancelled → nothing. Timed out (total deadline) → failed; `isChecking` returns to false.
   - One log line per finished check: `Logger(subsystem: AppPaths.logSubsystem, category: "RemoteVocabulary")`, outcome and HTTP status `.public`, host `.private`; never the path, query, token or terms (spec R8).
5. **App wiring**: `AppState` gets `let remoteVocabulary: RemoteVocabularyController`, built through an explicitly typed factory helper like `makeUpdateChecker()` (`AppState.swift:207-209`) to keep `AppState.init`'s type-check under the 300 ms budget; `MeetingTranscriberApp` starts it in a menu-bar `.task` next to `startPeriodicChecks` (`MeetingTranscriberApp.swift:195-197`).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/EngineController.swift:90-144` — sync + observer to change
- `app/MeetingTranscriber/Sources/AppSettings.swift:118-140`, `:360-400`, `:555-600`, `:630-745` — accounts, vocabulary props, Keychain-backed key, init
- `app/MeetingTranscriber/Sources/UpdateChecker.swift:106-179` — controller task/loop shape
- `app/MeetingTranscriber/Sources/AppState.swift:180-245` — factories and init wiring
- `app/MeetingTranscriber/Tests/EngineSettingsRuntimeSyncTests.swift:1-60`, `:125-150` — sync test pattern and `waitFor`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/AppSettingsClaudeAPIKeyTests.swift:1-45` — unique Keychain account + defaults suite per test
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:185-200` — launch `.task`s

### Key context
- **Never touch the real cache from tests.** `AppSettings()` defaults to the real `AppPaths.remoteVocabularyCacheDirectory`, and `AppState` is constructed by many unit tests. So the controller does no file I/O and arms no observer in `init`; only `start()` (called by the scene, never by `AppState.init`) does. Otherwise a test `AppState` with an empty address would delete the user's real copy as "belonging to another address". Every controller test passes its own temporary cache directory and a unique Keychain account, and deletes that account in `tearDown`.
- Reading `remoteVocabularyToken` hits the Keychain; a test that constructs `AppSettings` without an injected account must not read or write it (the production item belongs to the app's signature and raises an authorization prompt in a test process, see `AppSettings.swift:125-131`).
- The fake fetcher must be able to hold a fetch open (a continuation) so a test can change the address mid-check and prove the stale result is discarded.
- Debounce and interval are injected as short durations in tests; do not sleep for real seconds.
- The existing `EngineSettingsRuntimeSyncTests` stay green unmodified (default source is `.file`); add: `.url` gives both engines the current address's cache file path and a nil bookmark, an invalid address gives "", and switching the source or the address at runtime propagates.
- Do not edit `CLAUDE.md` or `AGENTS.md` (fork rule).

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<your scratch dir>/home swift test --parallel --filter "RemoteVocabulary|AppSettingsRemoteVocabulary|EngineSettingsRuntimeSync|AppSettingsTests|AppStateTests|ParakeetVocabularyPreparation|WhisperKitVocabularyFlow" > <your scratch dir>/t2.log 2>&1` and read the log.
- `./scripts/lint.sh` with the pinned tools (see task .1).
- `./scripts/pre-push.sh --with-appstore` (release build plus App Store variant) clean.
## Acceptance
- [ ] `vocabularySource` (default `.file`) and `remoteVocabularyURL` persist in the injected `UserDefaults`; the token lives only in the Keychain under the injected account, an empty value deletes it, and each set bumps `remoteVocabularyTokenRevision`.
- [ ] `EngineController` gives both engines the local path and bookmark for `.file`, and for `.url` the current address's cache file path (or "" for an invalid address) with a nil bookmark, at init and after a runtime switch of source or address; existing sync tests unchanged and green.
- [ ] Controller tests (fake fetcher, temp cache, unique Keychain account, short debounce/interval) prove: no check while the source is Local file or the address invalid; `start()` checks once and stores a valid download; the next check sends that response's validators; 304 keeps the text file untouched and updates `checkedAt`; an identical 200 does not rewrite the text file; an invalid body, offline, 401, a timeout and a save failure keep the previous copy with a failed status naming the copy the engines actually read, and `isChecking` returns to false; offline with no copy reports no vocabulary in use; an address change deletes the old address's copy and discards a check still in flight for the old address, so its result never lands; a token change triggers a debounced check that sends the new token; a new controller on the same cache starts from the stored copy.
- [ ] `AppState` exposes `remoteVocabulary`, its `init` does no cache I/O, and the scene starts it in a `.task`.
- [ ] Each finished check logs one line with outcome and status, host private, no path/query/token/terms.
- [ ] Focused tests, lint and `./scripts/pre-push.sh --with-appstore` pass.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
