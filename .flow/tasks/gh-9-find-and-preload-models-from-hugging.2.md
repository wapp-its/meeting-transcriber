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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
