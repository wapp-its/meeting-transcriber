---
satisfies: [R1, R4, R5, R6]
---
# gh-9-find-and-preload-models-from-hugging.4 Wire the browser into the model picker, use a variant, docs

## Description
Wire the browser into Settings: the "From Hugging Face…" picker entry opens it (R1), "Use" writes the existing custom-model settings or the matching stock entry (R4), the browser's requests carry the gh-12 token (R6), and the load offer from task 2 follows the pick once the window has closed (R5). Also the docs. Needs gh-12 (Hugging Face token in Settings) merged first: the coordinator sets that spec dependency; this task reads the token accessor gh-12 added.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift`, `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView+ModelChoice.swift` (from task 2, if it exists), `app/MeetingTranscriber/Sources/WhisperKitModelChoice.swift`, `app/MeetingTranscriber/Sources/AppSettings+WhisperKitModel.swift`, `README.md`, `docs/architecture-macos.md`, `app/MeetingTranscriber/Tests/AppSettingsUseHubModelTests.swift` (new), `app/MeetingTranscriber/Tests/WhisperKitModelChoiceHubTests.swift` (new), `app/MeetingTranscriber/Tests/TranscriptionSettingsHuggingFaceEntryTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView*.swift, app/MeetingTranscriber/Sources/WhisperKitModelChoice.swift, app/MeetingTranscriber/Sources/AppSettings+WhisperKitModel.swift, README.md, docs/architecture-macos.md, app/MeetingTranscriber/Tests/AppSettingsUseHubModelTests.swift, app/MeetingTranscriber/Tests/WhisperKitModelChoiceHubTests.swift, app/MeetingTranscriber/Tests/TranscriptionSettingsHuggingFaceEntryTests.swift]

### Approach
- `AppSettings.useHubModel(repoID:variant:)` in `Sources/AppSettings+WhisperKitModel.swift`: first clear the custom folder in every case (`updateWhisperKitCustomModelFolder(path: "", bookmark: nil)`, `Sources/AppSettings.swift:377-381`; the folder takes precedence in `whisperKitModelSelection`, `:53-66`, and would otherwise come back when "Custom model…" is chosen again). Then, when `repoID == WhisperKitLocalSnapshot.repoID` and the variant is in the `WhisperKitStockModel` table → `whisperKitCustomModelEnabled = false`, `whisperKitModel = variant`; otherwise set `whisperKitCustomRepo`, `whisperKitCustomVariant`, `whisperKitCustomModelEnabled = true`. Tests first: custom case incl. a previously set folder being cleared and `whisperKitModelSelection` becoming `.hub(repoID:)` + variant; stock-repo stock variant → stock entry with the folder cleared too; stock-repo non-stock variant → custom.
- `WhisperKitModelChoice` gains `hubBrowser: HuggingFaceModelSearch?` and `pendingLoadOffer`; `use(_ variant:, in listing:, settings:, engine:, isOnDisk:)` calls `settings.useHubModel`, computes the offer for `settings.whisperKitModelSelection` with the variant's `sizeBytes` through the task-2 `shouldOffer` rule into `pendingLoadOffer`, and sets `hubBrowser = nil`; `browserDidDismiss()` moves `pendingLoadOffer` into `loadOffer`. Cancel only sets `hubBrowser = nil` (nothing pending, so no question).
- Picker entry: `static let huggingFaceTag = "huggingface"`, `Text("From Hugging Face\u{2026}")` as the last entry after "Custom model…" (`TranscriptionSettingsView.swift:78-84`). In the binding's setter the hub tag returns early without touching settings and sets `modelChoice.hubBrowser = HuggingFaceModelSearch(catalog: makeHubCatalog(), token: { <gh-12 accessor on settings> })`, so the picker keeps showing the current model. New stored property `var makeHubCatalog: () -> any HuggingFaceModelCataloging = { HuggingFaceModelCatalog() }` for tests.
- Present with `.sheet(item:onDismiss:)` (bind through `Bindable(modelChoice).hubBrowser`), `onDismiss: { modelChoice.browserDidDismiss() }`, content `HuggingFaceModelBrowserView(search:onUse:onCancel:)` with `onUse` → `modelChoice.use(…, settings: settings, engine: whisperKitEngine, isOnDisk: isModelOnDisk)`. Attach next to task 2's alert inside `whisperKitModelPicker`, never on `body`.
- Token (R6): find gh-12's accessor with `grep -n "huggingFace\|hfToken\|HuggingFace" app/MeetingTranscriber/Sources/AppSettings*.swift` and read it inside the closure, so the Keychain is only read when a search runs. If gh-12 is not merged, stop and report rather than adding a token store here.
- Tests: `WhisperKitModelChoiceHubTests` (`use` → settings written, browser closed, `loadOffer` still nil and `pendingLoadOffer` set with the variant size; `browserDidDismiss` publishes it; dismiss without `use` publishes nothing; a stock-repo pick offers for the stock selection). `TranscriptionSettingsHuggingFaceEntryTests` (ViewInspector, pattern `Tests/TranscriptionSettingsCustomModelTests.swift:35-55`): selecting `huggingFaceTag` sets `modelChoice.hubBrowser` and leaves `whisperKitModel`, `whisperKitCustomModelEnabled`, `whisperKitCustomRepo` and `whisperKitCustomVariant` unchanged; after `use`, the custom repo and variant fields show the picked values. Use a fake catalog through `makeHubCatalog`; no test runs a search through a view built on a production-account `AppSettings` (a Keychain read from the test binary can block on an authorization prompt, see `AppSettings.swift:125-131`).
- Docs: `README.md` "Custom WhisperKit models" (`:259-261`): one or two sentences on "From Hugging Face…" (search, size, license, gated needs the token) and the "Load now" question. `docs/architecture-macos.md` App Entry & UI table (`:85-125`): rows for `HuggingFaceModelCatalog.swift`, `HuggingFaceModelSearch.swift`, `Settings/HuggingFaceModelBrowserView.swift`, `WhisperKitModelChoice.swift`, `WhisperKitStockModel.swift`. Do not edit `CLAUDE.md` or `AGENTS.md` (fork rule, `.claude/rules/wapp-fork.md`).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift:74-89,167-212` — picker, binding, custom fields
- `app/MeetingTranscriber/Sources/AppSettings+WhisperKitModel.swift:45-105` — selection resolution and folder precedence
- `app/MeetingTranscriber/Sources/WhisperKitModelChoice.swift` — task 2's offer rule and helper
- `app/MeetingTranscriber/Sources/Settings/HuggingFaceModelBrowserView.swift` and `Sources/HuggingFaceModelSearch.swift` — task 3's view and model

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/Settings/SpeakersSettingsView.swift:3-8,90-99` — `sheet(item:)` with a freshly created object
- `app/MeetingTranscriber/Sources/EngineController.swift:123-144` — the engine follows the written settings one turn later

### Key context
- An alert presented while the sheet is still dismissing can be dropped on macOS: the offer reaches `loadOffer` only in `onDismiss`.
- Clearing the folder is not optional: with a folder set, `whisperKitModelSelection` ignores the repository and the pick would silently not take effect.
- Keep `body` and the struct body small (CI type-check limit, SwiftLint strict `type_body_length` 400): new members go into the `+ModelChoice` extension file or `WhisperKitModelChoice`.
- The real flow (live search, sheet, alert after it closes, download) is an owner check after merge; the worker confirms the live search and listing once with task 1's opt-in test.
## Acceptance
- [ ] Choosing "From Hugging Face…" opens the browser and changes no setting; Cancel closes it with no question (R1).
- [ ] "Use" clears any custom folder and writes the custom repo and variant or selects the matching stock entry, closes the browser, and the offer appears only after the dismissal (R4, R5).
- [ ] The browser's search reads its token through the gh-12 accessor (R6; the header rule itself is pinned in task 1). When that accessor takes an injectable Keychain account, as `openAIAPIKey` does, a test stores a token on a test account and checks the fake catalog receives it; otherwise the done summary says the wiring is covered by review only.
- [ ] README and `docs/architecture-macos.md` updated; `CLAUDE.md`/`AGENTS.md` untouched.
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t4-home swift test --parallel --filter 'HuggingFace|WhisperKitModelChoice|WhisperKitModelLoadOffer|AppSettingsUseHubModel|WhisperKitCustomModel|TranscriptionSettings|SettingsInteraction|SettingsView' > /private/tmp/gh9-t4.log 2>&1` green; `./scripts/lint.sh` clean with the pinned tools; `./scripts/pre-push.sh --with-appstore` clean (release build of both variants).
## Done summary
The model picker now has a "From Hugging Face…" entry. It opens the model browser as a sheet and changes no setting. "Use" on a variant writes the custom-model settings (repository and variant), or selects the stock entry when the variant is one the picker lists from `argmaxinc/whisperkit-coreml`. It always clears the custom model folder. The browser searches with the saved Hugging Face token, read for each request. The load question appears only after the sheet has closed. README and `docs/architecture-macos.md` describe the flow.

stage: impl-review - ran [a6662899..3a6e0f76] SHIP round 1, 0 findings (codex gpt-5.6-sol xhigh, 3-reviewer panel; receipt /tmp/impl-review-receipt-13d6800aa401-gh-9-find-and-preload-models-from-hugging.4.json). Integration: fast-forward of the lane (SHAs unchanged); bookkeeping 1b98038e.
Tier: implementer - opus at xhigh (explicit invocation) (model: claude-opus-5-5)

Commits (`a6662899..3a6e0f76`):
- `6f4aae1a` feat(app): pick a WhisperKit model from the Hugging Face browser
- `3a6e0f76` docs: describe picking a WhisperKit model from Hugging Face

Workspace: `/Users/flach/.ai-sync/worktrees/-Users-flach-Sources-meeting-transcriber/lane/gh-9-hf-model-search.4` (branch `lane/gh-9-hf-model-search.4`, clean).

### Evidence (all measured)

- **Baseline:** green via handoff (`BASELINE_HANDOFF`). Between `8449fe2e` and the lane base `a6662899`, only `.flow/` files changed (`git log --format= --name-only 8449fe2e..a6662899`), so the handoff holds.
- **Red-first:** I wrote the 3 new test files before the implementation. `swift build --build-tests` then failed with 39 error lines, all caused by the missing API: no member `useHubModel`, `hubBrowser`, `pendingLoadOffer` or `browserDidDismiss`, plus "failed to produce diagnostic" errors where `use(...)` and `makeHubCatalog` are called. Log: `/private/tmp/gh9tick/t4/red-first-build.log`.
- **Acceptance command:** `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t4-home swift test --parallel --filter 'HuggingFace|WhisperKitModelChoice|WhisperKitModelLoadOffer|AppSettingsUseHubModel|WhisperKitCustomModel|TranscriptionSettings|SettingsInteraction|SettingsView' > /private/tmp/gh9-t4.log 2>&1`. Result: exit 0, 226/226 tests ran, 0 failures. The 2 `HuggingFaceCatalogLiveTests` are included but skip without the env variable. The log is newer than every committed source file.
- **New tests:** 12 tests, 0 failures. They are `AppSettingsUseHubModelTests` (3), `WhisperKitModelChoiceHubTests` (5) and `TranscriptionSettingsHuggingFaceEntryTests` (4).
- **Live Hub test:** `MEETINGTRANSCRIBER_HF_LIVE_TESTS=1 CFFIXED_USER_HOME=/private/tmp/gh9-t4-home swift test --filter HuggingFaceCatalogLiveTests`. Result: exit 0, 2 tests passed against huggingface.co (not skipped).
- **Lint:** `PATH=/private/tmp/gh9tick/lint-bin:$PATH ./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1. Result: exit 0; 0/782 files require formatting; 0 violations in 782 files. The first runs found a `braces` format hit and a `multiple_closures_with_trailing_closure` hit, both fixed. The tests ran again after the fixes.
- **Release parity:** `./scripts/pre-push.sh --with-appstore` exited 0. Both release variants built without warnings.
- **CI Build & Analyze replay:** `xcodebuild build-for-testing` followed by `swiftlint analyze --strict` (script `/private/tmp/gh9tick/t4/analyze.sh`).
  - xcodebuild exited 0.
  - Analyze reports only 2 `unused_declaration` hits, in `Sources/RecordingProvider.swift:144,146`. This task does not touch that file. There are 0 hits in this task's files.
  - The slowest type-checked body in the touched files is 33.0 ms (`loadSelectedModel`, pre-existing). `openHuggingFaceBrowser` takes 9.8 ms, well under the 300 ms limit.
- **Mutation checks:** 7 changes; each one turned at least one test red. After each check the file was restored, and `cmp` confirmed the original. Script and summaries are in `/private/tmp/gh9tick/t4/mut/`.

  | Mutation | Tests red |
  |---|---|
  | m1 picker setter without the Hugging Face guard | 4 (all entry tests) |
  | m2 `useHubModel` without the folder clear | 2 |
  | m3 offer asked at "Use" instead of after dismissal | 4 |
  | m4 sheet without `onDismiss` | 1 (`testUseFillsTheCustomFieldsAndAsksOnceTheBrowserHasClosed`) |
  | m5b token closure returns nil | 1 (`testTheBrowserSearchesWithTheSavedHuggingFaceToken`) |
  | m6 `onUse` not called | 1 (`testUseFillsTheCustomFieldsAndAsksOnceTheBrowserHasClosed`) |
  | m7 token read once at open | 1 (`testTheBrowserSearchesWithTheSavedHuggingFaceToken`) |

  The first version of m5 (`{ nil }`) did not compile: warnings are errors, and an unused `let` broke the build. m5b is the version that compiles.

**Token wiring:** a test covers it, not review alone. `TranscriptionSettingsHuggingFaceEntryTests.testTheBrowserSearchesWithTheSavedHuggingFaceToken` opens the browser from the real picker and then saves a token through the injectable `HuggingFaceTokenStore` (the fake `HuggingFaceTokenStoreFake`). It then checks that the catalog received that token with the next search. Mutations m5b and m7 turn it red. No test reads the production Keychain account.

### Choices

- **DECIDED (rule 1)** — the `Task: gh-9-find-and-preload-models-from-hugging.4` trailer is in both commit bodies, as the dispatch instructed (the wapp/main precedent). Task .2 left it out, because `submit.sh` refuses commit messages that name spec ids. The conductor may need to remove it before any submission to the original.
- **DECIDED (rule 1)** — the token goes to the search exactly as saved, and "" when none is saved. The catalog from task .1 sends an `Authorization` header only for a non-empty trimmed token.
- **DECIDED (rule 1)** — "Use" defers the chosen model on the engine at once (assumption A6). A load still running for the previous model therefore cannot go on to it while the question waits.
- **DECIDED (rule 1)** — the load question names the listed variant's `sizeBytes`, also when "Use" selects a stock entry (task text).
- **DECIDED (rule 1)** — "Cancel" only closes the browser (`hubBrowser = nil`). It writes nothing and asks nothing.
- **DECIDED (rule 1)** — the live Hub test ran once, as the task's Key context says.
- **DECIDED (rule 6)** — `huggingFaceTag`, `openHuggingFaceBrowser` and `useHubVariant` live in the `+ModelChoice` extension. This keeps the main view's type body under SwiftLint's length limit.
- **DECIDED (rule 6)** — I added tests beyond the minimum: the Cancel sheet wiring, using the model that is already loaded (no question), and the token read at request time.
- **ASSUMED (rule 4)** — the README wording. Switch point: the "Custom WhisperKit models" section of `README.md`.
- **ASSUMED (rule 4)** — the 5 new rows in the App Entry & UI table, placed after the `Settings/TranscriptionSettingsView.swift` row. `+ModelChoice.swift` is named in the `WhisperKitModelChoice.swift` row instead of getting its own row. Switch point: that table in `docs/architecture-macos.md`.
- **OPEN CHOICE:** none. Nothing outside Touches was needed, and no new persisted key or format was added.

### Follow-ups (not built)

1. `Sources/RecordingProvider.swift:144,146` fail CI's `swiftlint analyze --strict` with `unused_declaration`. They are older than this task, but CI's Build & Analyze job may fail on them.
2. `Tests/ViewInspectorIdentifierTests.swift:45,53,64` print `ActorIsolatedCall` warnings in the xcodebuild replay. They are older than this task.
3. The owner's manual check of the live flow and look; the run note lists what is untested live.
4. Untested: if the Settings window closes while the sheet is open, the browser may appear again on reopen, because `WhisperKitModelChoice` is `@State` in `SettingsView` and keeps `hubBrowser` set.
5. The status-line follow-up from task .3 is still open.
6. The README Settings table's "Transcribe" row does not mention the new entry; the custom-model section does.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 6f4aae1ad0819bdf517a2cfd792969aea5c521a6, 3a6e0f76fea8d21a445881e3531f45354fa17151, 1b98038e
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t4-home swift test --parallel --filter 'HuggingFace|WhisperKitModelChoice|WhisperKitModelLoadOffer|AppSettingsUseHubModel|WhisperKitCustomModel|TranscriptionSettings|SettingsInteraction|SettingsView' > /private/tmp/gh9-t4.log 2>&1 -> exit 0, 226/226 tests ran, 0 failures (the 2 HuggingFaceCatalogLiveTests skip without the env variable); the 12 new tests are included, cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t4-home swift test --filter 'AppSettingsUseHubModelTests|WhisperKitModelChoiceHubTests|TranscriptionSettingsHuggingFaceEntryTests' -> exit 0, 12 tests, 0 failures (3 + 5 + 4), cd app/MeetingTranscriber && MEETINGTRANSCRIBER_HF_LIVE_TESTS=1 CFFIXED_USER_HOME=/private/tmp/gh9-t4-home swift test --filter HuggingFaceCatalogLiveTests -> exit 0, 2 tests passed against huggingface.co (not skipped), PATH=/private/tmp/gh9tick/lint-bin:$PATH ./scripts/lint.sh -> exit 0, swiftformat 0/782 files require formatting, swiftlint 0 violations in 782 files, ./scripts/pre-push.sh --with-appstore -> exit 0, release builds of both variants complete without warnings, CI Build & Analyze replay (xcodebuild build-for-testing + swiftlint analyze --strict) -> xcodebuild exit 0; analyze reports only 2 unused_declaration hits in Sources/RecordingProvider.swift:144,146, a file this task does not touch; 0 hits in this task's files; slowest type-checked body in touched files 33.0 ms (pre-existing loadSelectedModel), red-first: swift build --build-tests before the implementation -> failed with 39 error lines, all from the missing API: no member useHubModel, hubBrowser, pendingLoadOffer or browserDidDismiss, plus failed-to-produce-diagnostic errors where use(...) and makeHubCatalog are called, mutation checks, each restored with cmp clean: no hub-tag guard -> 4 tests red; no folder clear -> 2 red; offer asked immediately -> 4 red; no onDismiss -> 1 red; token closure returns nil -> 1 red; onUse not called -> 1 red; token read once at open -> 1 red, review wrapper on 1b98038e: acceptance filter 226/226 (exit 0); lint 0 violations in 782 files (exit 0); ./scripts/pre-push.sh --with-appstore exit 0 (both release variants), integrated at 1b98038eafa4a85c8f3449722c6d485b5af7b462: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t4-home swift test --parallel --filter 'HuggingFace|WhisperKitModelChoice|WhisperKitModelLoadOffer|AppSettingsUseHubModel|WhisperKitCustomModel|TranscriptionSettings|SettingsInteraction|SettingsView' (exit 0, no failures; parallel mode prints failures only); PATH=/private/tmp/gh9tick/lint-bin:$PATH ./scripts/lint.sh (exit 0, 0 violations)
- PRs: