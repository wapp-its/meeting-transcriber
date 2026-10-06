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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
