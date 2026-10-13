---
satisfies: [R5]
---
# gh-9-find-and-preload-models-from-hugging.2 Offer to load a newly picked stock model

## Description
Offer to load a newly picked stock WhisperKit model right away (R5 for stock picks), and lay the shared ground task 4 builds on: the stock-model table with sizes, the model-choice state object that holds the pending offer, and one helper that applies a selection to the engine and loads it (also used by the existing "Load Model" button). Independent of the Hugging Face client; the browser's "Use" joins this offer in task 4.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WhisperKitStockModel.swift` (new), `app/MeetingTranscriber/Sources/WhisperKitModelChoice.swift` (new), `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift`, `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView+ModelChoice.swift` (new, optional extension file), `app/MeetingTranscriber/Sources/SettingsView.swift`, `app/MeetingTranscriber/Tests/WhisperKitModelChoiceTests.swift` (new), `app/MeetingTranscriber/Tests/WhisperKitModelLoadOfferTests.swift` (new), `app/MeetingTranscriber/Tests/TranscriptionSettingsLoadOfferTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/WhisperKitStockModel.swift, app/MeetingTranscriber/Sources/WhisperKitModelChoice.swift, app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView*.swift, app/MeetingTranscriber/Sources/SettingsView.swift, app/MeetingTranscriber/Tests/WhisperKitModelChoiceTests.swift, app/MeetingTranscriber/Tests/WhisperKitModelLoadOfferTests.swift, app/MeetingTranscriber/Tests/TranscriptionSettingsLoadOfferTests.swift]

### Approach
- `WhisperKitStockModel`: move the six entries of `TranscriptionSettingsView.whisperKitModels` (`Sources/Settings/TranscriptionSettingsView.swift:14-21`) into one shared table (variant, label, `approximateBytes: Int64` from the spec's Architecture list) plus a lookup by variant; the picker reads it. Labels and order unchanged.
- `WhisperKitModelLoadOffer` (struct: `selection: WhisperKitModelSelection`, `sizeBytes: Int64?`, `isOnDisk: Bool`) with `title` "Load the new model now?" and `message`: on disk → "The model is already on this Mac; loading takes up to a minute."; not on disk with a size → "About <size>, downloaded once. This takes a few minutes; afterwards the model loads offline." (size via `ByteCountFormatter` `.file`); without a size → "It is downloaded once and takes a few minutes; afterwards it loads offline."
- `WhisperKitModelChoice`: `@Observable @MainActor final class` (no-argument init) holding `loadOffer: WhisperKitModelLoadOffer?`. Methods: `offerLoad(for selection:, sizeBytes:, engine:, isOnDisk:)` sets the offer unless `shouldOffer` says no; `static func shouldOffer(chosen:, engineVariant:, engineOrigin:, engineState:) -> Bool` is false only when the engine already requests exactly this variant and origin and its state is not `.unloaded` (re-picking the loaded or loading model); `@discardableResult func accept(_ offer:, engine:) -> Task<Void, Never>` clears the offer and starts the load; `decline()` clears it. `static func isOnDiskInProduction(_:)`: `.hub(repoID)` → `WhisperKitLocalSnapshot.locate(variant:in: WhisperKitLocalSnapshot.repoRoot(for:)) != nil`; `.localFolder` → true.
- Shared load helper: `extension WhisperKitEngine { func loadModel(for selection: WhisperKitModelSelection) async }` = `applyModelVariant(selection.variant, origin: selection.origin)` then `loadModel()`. Put the extension in `WhisperKitModelChoice.swift`, not in `WhisperKitEngine.swift` (558 lines, near the 600-line `file_length` limit). Switch the `.unloaded` "Load Model" button (`TranscriptionSettingsView.swift:399-406`) to it for WhisperKit; Parakeet unchanged.
- View: `TranscriptionSettingsView` gains `var modelChoice = WhisperKitModelChoice()` and `var isModelOnDisk: (WhisperKitModelSelection) -> Bool = WhisperKitModelChoice.isOnDiskInProduction` (defaults keep every existing call site compiling). In the picker binding's setter (`whisperKitModelPickerSelection`, `:171-179`), after a stock tag is written, call `modelChoice.offerLoad(for: settings.whisperKitModelSelection, sizeBytes: <table size>, engine: whisperKitEngine, isOnDisk: isModelOnDisk)`; the custom tag never offers. `SettingsView` (`Sources/SettingsView.swift:29,69-74`) owns `@State private var whisperKitModelChoice = WhisperKitModelChoice()` and passes it in, so the offer survives body re-evaluations.
- Alert: `.alert(_:isPresented:presenting:actions:message:)` attached inside `whisperKitModelPicker` (`:76-89`), never on `body`. `isPresented` reads `modelChoice.loadOffer != nil` and its setter calls `decline()` on false. Buttons "Load now" (calls `accept(offer, engine:)` with the `presenting` value) and "Later" (`role: .cancel`).
- Tests first for the pure parts: `WhisperKitModelLoadOfferTests` (three messages; compare the size text against `ByteCountFormatter` output, never a locale-dependent literal); `WhisperKitModelChoiceTests` (`shouldOffer` table; `offerLoad` with an `isOnDisk` stub; `accept` loads exactly the offered selection: install a source with `engine.installModelSourceForTesting { origin in … }` that records the origin and the variant passed to `locateLocal`, then `await accept(...).value` and assert; `decline` clears with no source call; already-loaded case via the idle-pipe trick in `Tests/WhisperKitEngineModelOriginTests.swift:13-31`). `TranscriptionSettingsLoadOfferTests` (ViewInspector, one wiring test each): selecting `openai_whisper-small` on a default settings object sets `modelChoice.loadOffer` with that variant and the table size; selecting `TranscriptionSettingsView.customModelTag` leaves it nil. Use `isModelOnDisk: { _ in false }` and a `UserDefaults(suiteName:)` per test as in `Tests/TranscriptionSettingsCustomModelTests.swift:8-40`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift:14-89,167-212,368-408` — stock list, picker, binding, status row
- `app/MeetingTranscriber/Sources/WhisperKitEngine.swift:142-283` — `loadModel`, `applyModelVariant`, state rules
- `app/MeetingTranscriber/Tests/TranscriptionSettingsCustomModelTests.swift` — picker ViewInspector pattern
- `app/MeetingTranscriber/Tests/WhisperKitEngineModelOriginTests.swift:1-60` — model-source seam and idle pipe

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/SettingsView.swift:29-96` — where the state object is owned
- `app/MeetingTranscriber/Sources/EngineController.swift:94-144` — the settings observer syncs the engine one main-actor turn later

### Key context
- The settings observer (`EngineController.observeEngineSettings`) applies a new model in a later `Task`, so at offer and accept time the engine may still hold the old model: always load through the helper, which applies the selection first (the existing "Load Model" button already does this by hand).
- SwiftUI sets `isPresented` to false after any alert button, which calls `decline()`; "Load now" must use the `presenting` value it receives, not re-read `loadOffer` later.
- `TranscriptionSettingsView` is near the CI's 300 ms per-body type-check limit (issues #17/#20) and SwiftLint strict `type_body_length` (400): add no code inline in `body`; put new helpers in the extension file or in `WhisperKitModelChoice`.
- The alert itself (look, buttons in a real window) is manual QA per CLAUDE.md "GUI Testing"; its actions are covered through `WhisperKitModelChoice`.

## Acceptance
- [ ] Picking a different stock entry sets an offer with that model, its table size and the on-disk flag; re-picking the model the engine already loaded or is loading sets none; the "Custom model…" entry sets none.
- [ ] `accept` loads exactly the offered variant and origin even when the engine still held another model; `decline` loads nothing.
- [ ] The existing "Load Model" button loads through the same helper; existing `TranscriptionSettings*`, `SettingsInteractionTests` and `SettingsViewTests` stay green.
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t2-home swift test --parallel --filter 'WhisperKitModelChoice|WhisperKitModelLoadOffer|TranscriptionSettings|SettingsInteraction|SettingsView|WhisperKitEngine' > /private/tmp/gh9-t2.log 2>&1` green (environmental model-download failures listed in the done summary, see the fork's local-verification notes); `./scripts/lint.sh` clean with the pinned tools; `swift build -c release` clean.


## Done summary
Picking another stock WhisperKit model in Settings -> Transcription now sets a load offer ("Load the new model now?") that names the stock-table download size, or says the model is already on this Mac. "Load now" and the existing "Load Model" button both load through `WhisperKitEngine.loadModel(for:)`, which applies the selection before loading. The six stock entries moved into `WhisperKitStockModel` with their measured sizes, and `SettingsView` owns the `WhisperKitModelChoice` state object that task 4 extends.

Tier: implementer - opus at xhigh (explicit invocation) (model: claude-opus-5-5)

stage: impl-review - ran [a971da58..7a29f0cc in lane .2] SHIP round 4 after 3 NEEDS_WORK rounds (codex gpt-5.6-sol xhigh; receipt /tmp/impl-review-receipt-4c2b6b7cd60e-gh-9-find-and-preload-models-from-hugging.2.json). Fix commits cherry-picked onto the spec branch as 0fb6b35a, c9f22297, 40eb15c8; review bookkeeping merged by the conductor. Assumption A6 (deferred load on "Later") recorded in the spec.

### Acceptance

- AC1 (offer set with model, table size and on-disk flag; none for the loaded or loading model; none for "Custom model..."): `TranscriptionSettingsLoadOfferTests.testPickingAStockModelOffersToLoadItWithItsTableSize`, `testPickingTheCustomEntryOffersNothing`; `WhisperKitModelChoiceTests.testShouldOfferOnlyWhenTheChosenModelIsNotAlreadyLoadedOrLoading` (7-row table), `testOfferLoadRecordsTheModelItsSizeAndWhetherItIsOnDisk`, `testRepickingTheLoadedModelOffersNothing` (idle-pipe trick).
- AC2 (`accept` loads exactly the offered variant and origin while the engine held another; `decline` loads nothing): `WhisperKitModelChoiceTests.testAcceptLoadsExactlyTheOfferedModelWhileTheEngineHeldAnother` (source records `[turbo, swissGerman]`), `testDeclineClearsTheOfferAndLoadsNothing`.
- AC3 ("Load Model" through the same helper; existing settings tests green): `TranscriptionSettingsLoadOfferTests.testLoadModelLoadsTheSelectedModelThroughTheSharedHelper`. A mutation run that bypassed the helper's apply step turned it red (located turbo instead of the custom selection), and restoring the helper turned it green again.
- AC4: the acceptance command ran 179 tests, 178 passed. The one failure is environmental (below). `./scripts/lint.sh` with the pinned tools reported 0 violations in 771 files. `swift build -c release` exited 0.
- A4 (stock table lists all six entries with a size): `WhisperKitModelChoiceTests.testTheStockTableListsThePickerEntriesInOrderWithASize`.

### Environmental failures

- `WhisperKitEngineTests.testTranscribeGermanAudio` failed with "unloaded is not equal to loaded" in the parallel run. Two parallel test processes downloaded `openai_whisper-small` into the fresh scratch home at the same time. The log shows NSURLError -1005 and a NSCocoaErrorDomain Code=4 move of a `weight.bin.*.incomplete` file. Run alone afterwards it passed in 6.9 s (rc=0). The test sets `engine.modelVariant` and calls `loadModel()` directly, so it never reaches this task's code.

### Extra checks

- I ran a clean `xcodebuild build-for-testing` followed by `swiftlint analyze --strict`, the CI-only step. Analyze found 0 `unused_declaration` hits in this task's files and 2 in `Sources/RecordingProvider.swift:144,146` (the `storePendingCut` / `recordPendingCutResolution` default bodies). This task does not touch that file. I infer the two hits predate this task and did not measure them at the base.
- Type-check timings in the touched files peak at 31.7 ms (`loadSelectedModel()`). `whisperKitModelPicker` and `body` stay under 11 ms, far below the 300 ms gate.

### Choices

- DECIDED (rule 1): the commit message carries no `Task:` trailer and no spec or issue id. Rule source is the fork's working rules ("write commit messages for the original's readers: no gh-N/fn-N ids"), and `submit.sh` refuses such messages. The evidence file names the commit explicitly.
- DECIDED (rule 1): re-picking the selected stock entry while the engine is `.unloaded` makes an offer. The task's `shouldOffer` definition returns false only when the engine requests exactly this model and its state is not `.unloaded`.
- DECIDED (rule 6): `offerLoad` leaves an existing offer in place when `shouldOffer` says no, matching the task text ("sets the offer unless shouldOffer says no"). The alert is modal, so a second pick cannot happen while an offer is pending.
- DECIDED (rule 6): the alert attaches inside `whisperKitModelPicker`, on the Picker, through `View.whisperKitLoadOfferAlert(_:engine:)` in `TranscriptionSettingsView+ModelChoice.swift`. Putting it there keeps the alert's generic closures out of the picker's type-check and out of the struct's type body. The "Load Model" action moved to the same file as `loadSelectedModel()`.
- DECIDED (rule 6): `WhisperKitModelChoice.isOnDiskInProduction` is `nonisolated`. The view's default value for `isModelOnDisk` is a non-isolated closure, and a main-actor static func would not convert to that type.
- DECIDED (rule 6): I added one wiring test for "Load Model" beyond the two picker tests the task lists, because AC3 names the button and no test covered its action. The A4 table test lives in `WhisperKitModelChoiceTests`, since Touches names no stock-model test file.

### For task 4

- `WhisperKitModelChoice` holds only `loadOffer` today. Task 4 adds the open-browser state to it. "Use" then calls `modelChoice.offerLoad(for:sizeBytes:engine:isOnDisk:)` with the listed variant's size from the sheet's `onDismiss`.
- `TranscriptionSettingsView` gained `modelChoice` and `isModelOnDisk` properties, both with defaults, so every existing call site still compiles.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: e8937d792c8dfdb333160c98936666fdeb35e0f2, 0fb6b35ac399c5e5825d14f1ab9f1b06a1290d45, c9f222970ccd668a8c0aa259b2ece555e5f0b4e8, 40eb15c8043072c4c53efe68f4165a425c185ed8, 1305c3b50b48243065167570ec08967a288e249a
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t2-home swift test --parallel --filter 'WhisperKitModelChoice|WhisperKitModelLoadOffer|TranscriptionSettings|SettingsInteraction|SettingsView|WhisperKitEngine' > /private/tmp/gh9-t2.log 2>&1 (rc=1: 179 tests, 178 passed; 1 environmental: WhisperKitEngineTests.testTranscribeGermanAudio, parallel first download of openai_whisper-small in the fresh scratch home; green alone afterwards, rc=0, 6.9 s), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t2-home swift test --parallel --filter 'WhisperKitModelChoiceTests|TranscriptionSettingsLoadOfferTests' (rc=0, 10 tests, after the lint-driven test edits), PATH=/private/tmp/gh9tick/lint-bin:$PATH ./scripts/lint.sh (rc=0, 0 violations in 771 files), cd app/MeetingTranscriber && swift build -c release (rc=0), xcodebuild clean build-for-testing + swiftlint analyze --strict (build rc=0; analyze rc=2: 2 unused_declaration in Sources/RecordingProvider.swift:144,146, a file this task does not touch; none in this task's files), integrated at 1556c5e9ce847abe949067186653fb535a37730d: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t2-home swift test --parallel --filter 'WhisperKitModelChoice|WhisperKitModelLoadOffer|TranscriptionSettings|SettingsInteraction|SettingsView|WhisperKitEngine' (exit 0, no failures; parallel mode prints failures only); PATH=/private/tmp/gh9tick/lint-bin:$PATH ./scripts/lint.sh (exit 0, 0 violations)
- PRs: