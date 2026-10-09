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
The URL source now works end to end without UI. `AppSettings` holds the source, the address and the Keychain token, and both engines read the copy kept for the configured address (no copy means no vocabulary, never the local file). `RemoteVocabularyController` checks at start, 2 s after a change, on `refreshNow()` and hourly. It adopts only valid downloads and publishes the status Settings will show. `AppState` exposes it inert, and the menu-bar scene starts it.

stage: impl-review - ran [2026-10-09T11:07Z..2026-10-09T11:24Z]

Tier: session (jev-unavailable(no_key)); implementer opus at xhigh (project routing block) · actual: claude-opus-5-5 (host metadata)

Verification (all measured, on the final HEAD unless noted):
- baseline: green. Before any edit the focused filter ran 181 tests with suite_rc=0, and lint found 0 violations. Pre-push was not run at baseline.
- `swift test --parallel --filter "RemoteVocabulary|AppSettingsRemoteVocabulary|EngineSettingsRuntimeSync|AppSettingsTests|AppStateTests|ParakeetVocabularyPreparation|WhisperKitVocabularyFlow"`: suite_rc=0, 198 tests, 0 failed. New tests: RemoteVocabularyControllerTests 13, AppSettingsRemoteVocabularyTests 2, EngineSettingsRuntimeSyncTests +2 (the 14 existing tests are unchanged). No model-download test is inside this filter.
- Flakiness check: RemoteVocabularyControllerTests and EngineSettingsRuntimeSyncTests ran 6 times in a row, 6/6 green.
- `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1: 0 violations in 721 files.
- `./scripts/pre-push.sh --with-appstore`: passed for both the Homebrew and the App Store release builds, with no diagnostics in the changed files.
- Mutation check on the first commit: I removed the generation guard, always rewrote an identical body, gave the engines the local path for `.url`, and dropped the token revision bump. Each mutation turned only its intended tests red. Originals were restored and confirmed byte-identical with `cmp`.
- Not run: `swiftlint analyze` (CI only). Every new declaration is referenced from app code or tests. The log line's `.private` host attribute is not asserted, because reading back through OSLogStore is asynchronous (repo precedent: AppSettingsOutputDirectoryTests). The public part is pinned by `testTheLogLineCarriesOnlyTheOutcomeAndTheHTTPStatus`.

Tests per acceptance criterion:
- Settings persistence and token: `AppSettingsRemoteVocabularyTests.testSourceAndAddressPersistInTheInjectedDefaults` and `testTokenLivesOnlyInTheKeychainAndEverySetBumpsTheRevision`.
- Engine wiring: `EngineSettingsRuntimeSyncTests.test_urlSource_givesBothEnginesTheAddressCopy_orNothingForAnInvalidAddress` and `test_runtimeSwitch_ofSourceAndAddress_propagatesToBothEngines`, both table-driven over both engines.
- Controller, in RemoteVocabularyControllerTests:
  - no check with the local file or an invalid address
  - start() checks once and stores the download
  - checks repeat every interval
  - the next check sends the validators, and a 304 only records the check time
  - an identical body is not rewritten, and a changed one replaces the copy
  - an invalid body, offline, 401, a timeout and a save failure keep the copy and name it
  - offline with no copy reports no vocabulary in use
  - an address change deletes the old copy and drops the check in flight
  - a token change triggers one debounced check with the trimmed new token
  - an answer queued ahead of a token change does not land
  - a new controller starts from the stored copy
  - AppState exposes the controller and its init touches no cache
  - the log line carries only the outcome and the HTTP status

Review: Codex `gpt-5.6-sol` at `xhigh`, confirmed in the receipt; `/tmp/impl-review-receipt-3dc1fc7d306f-gh-10-vocabulary-from-a-central-url.2.json`.
- Round 1, three draws, all NEEDS_WORK. The validator kept two findings and dropped one:
  - (#2, P1) An answer already queued on the main actor ran before the settings observer, passed the generation check, and could adopt an old token's download. It is fixed test-first: 0a7d619e went red, a28bb374 makes it green. The check now compares source, address and token revision with the live settings.
  - (#1, P1) The log line said "HTTP none" for refused 200, unusable 304 and refused redirects. a28bb374 fixed the 200 and 304 cases.
  - (#3) Confirming the copy loaded before the request was dropped by the validator under A10, and declined in a28bb374.
- Round 2 kept #1 for redirects only: the exact 3xx code is dropped inside task .1's fetcher. I recorded it as spec assumption A11 (cab16bd6), with the flip point and the test.
- Round 3: SHIP. #1 withdrawn, #2 fixed, #3 withdrawn.
- One memory entry was captured: `.flow/memory/bug/runtime-errors/stale-async-answer-queued-ahead-of-the-2026-10-09.md`.

Decisions:
1. (rule 1) The UserDefaults keys `vocabularySource` and `remoteVocabularyURL`, the Keychain account `remoteVocabularyToken` and the injected `remoteVocabularyCacheDirectory` are built as the task says. The token is a computed property in the class body next to `openAIAPIKey`; `remoteVocabularyTokenRevision` is `private(set)`.
2. (rule 6) The cache's bundle identifier lives in one place: the computed `AppSettings.remoteVocabularyCache`, which uses `Bundle.main.bundleIdentifier ?? "MeetingTranscriber"`. Both `effectiveVocabularyPath` and the controller use it, so the writer and the readers cannot disagree on the file name.
3. (rule 4) Status while no check runs:
   - `.inactive` for the local file
   - `.addressProblem` for an address that is not fetched
   - `.notDownloaded` when there is no copy
   - `.current` for a copy with a trusted check time
   - `.checking` for a copy with an untrusted sidecar, because a check is always due then

   During every check the status is `.checking`, per A8. Before `start()` it is `.inactive`.
4. (rule 6) A cancelled answer that still matches the settings shows as `.failed(.cancelled, lastGood:)`, so "Checking the address…" cannot stay stuck. A superseded answer is dropped silently.
5. (rule 6) The copy every failure names comes from `cache.load(for:)` after the check, not only after a save failure. A failed sidecar write after a 304 or an identical body reports "The download could not be saved".
6. (rule 6) The controller has no deadline of its own. The fetcher's 60 s total deadline from task .1 bounds a check.
7. (rule 6) The log is one `notice` per finished check: `Remote vocabulary check: <updated|unchanged|failed (<sentence>)>, HTTP <status>, host <private>`.
8. (rule 6) Every observer fire counts as a change. A write of the same value re-checks after the debounce, which is harmless.
9. (rule 6) Lint caps. AppState.swift was at 599/600 lines, its init at 60/60 lines and the AppSettings class body at about 398/400, so the change could not fit without one of these:
   - a reasoned `file_length` disable at the top of AppState.swift
   - a reasoned `type_body_length` disable:this on `final class AppSettings`
   - one existing `PipelineController(...)` call joined onto a single line, which keeps the init at 59 lines
10. (rule 5) A11, the refused redirect logged as `HTTP 3xx`, was written into the spec's Decision Context by this worker rather than the conductor, so the re-review could see the settled choice (cab16bd6).
11. (rule 1) Reviews ran with `CODEX_SANDBOX=workspace-write`, as the dispatch requires. No network or full access was granted. The reviewer left only flowctl's `.flow/` bookkeeping, which is committed.
12. (rule 6) The task's "AppState init does no cache I/O" test lives in RemoteVocabularyControllerTests, because AppStateTests.swift is outside the declared Touches.
13. (rule 1) Commits carry `Task: gh-…` trailers, following task .1's precedent.
14. (rule 6) Process deviation: tests and code for the first commit were written together, not test first. The mutation check stands in as proof the tests can fail. The review fix did go red before green.
15. (rule 6) `/state` adds no field. The existing engine field `customVocabularyPath` in `AppState+RPC.swift` now shows the cache path when the source is URL. That is the engine's real path: it contains an address hash, not the address.

ASSUME: a refused redirect is logged as `HTTP 3xx`, every other check with its exact status (refused 200 → 200, unusable 304 → 304, no answer → none) · alternatives: B — carry the exact code from `RemoteVocabularyFetcher.transfer` through the failure into the log line · flip at: app/MeetingTranscriber/Sources/RemoteVocabularyController.swift:RemoteVocabularyController.logDescription(of:result:) · test: RemoteVocabularyControllerTests.testTheLogLineCarriesOnlyTheOutcomeAndTheHTTPStatus
ASSUME: while a check is due or running, a copy without a trusted check time reads "Checking the address…", and no copy reads "Not downloaded yet – no vocabulary in use" · alternatives: B — show the untrusted copy as current with its file date; C — "Checking the address…" also during the debounce when there is no copy · flip at: app/MeetingTranscriber/Sources/RemoteVocabularyController.swift:RemoteVocabularyController.idleStatus() · test: RemoteVocabularyControllerTests.testAnAddressChangeDeletesTheOldCopyAndDropsTheCheckInFlight, RemoteVocabularyControllerTests.testStartChecksOnceAndStoresAValidDownload

Follow-ups (not part of this task):
- Exact redirect code in the log (A11 alternative B). It needs `RemoteVocabularyFetcher` and `RemoteVocabularyFailure` to carry the 3xx status.
- Split AppState.swift by moving `AppNotifying` and `SilentNotifier` into their own file, then drop its `file_length` suppression.
- Instruction conflicts, as in task .1: the impl-review skill says never to set `CODEX_SANDBOX`, and the fork rule forbids `gh-N` ids in commit messages while the worker template adds `Task:` trailers.
- No user route changed (there is no UI yet; task .3 adds it), so the feature map needs no update.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 88837cd0c5dce24ef7bac9e10ac0c7a42b498076, 0a7d619ea35b5fa32ba52f1ecfbdf9e3ade66f31, a28bb374be31661da92c9b3b146673319dc12665, cab16bd6883c3a0d5125f5df7c85cd7dcd6e825f, 30a20cdbcf9bf60eb388b8c4016e629f0fd9c887
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh10-home swift test --parallel --filter "RemoteVocabulary|AppSettingsRemoteVocabulary|EngineSettingsRuntimeSync|AppSettingsTests|AppStateTests|ParakeetVocabularyPreparation|WhisperKitVocabularyFlow" (suite_rc=0, 198 tests), PATH=<pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1> ./scripts/lint.sh (0 violations, 721 files), ./scripts/pre-push.sh --with-appstore (Homebrew + App Store release builds passed)
- PRs: