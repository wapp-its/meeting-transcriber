---
satisfies: [R2, R3]
---
# gh-9-find-and-preload-models-from-hugging.3 Hugging Face browser window and search model

## Description
Build the browser window on its own, against the catalog protocol from task 1: the observable search model (pause before searching, minimum length, stale-result guard, listing, messages, cancel) and the sheet view (search field, results, variants with size, license, gated notice, model-card link, "Use", "Cancel"). It reports a chosen variant through a closure and touches no settings; task 4 wires it into the picker. Split this way so the window is tested completely with a fake catalog before it can change anything.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/HuggingFaceModelSearch.swift` (new), `app/MeetingTranscriber/Sources/Settings/HuggingFaceModelBrowserView.swift` (new), `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Tests/HuggingFaceModelSearchTests.swift` (new), `app/MeetingTranscriber/Tests/HuggingFaceModelBrowserViewTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/HuggingFaceModelSearch.swift, app/MeetingTranscriber/Sources/Settings/HuggingFaceModelBrowserView.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/HuggingFaceModelSearchTests.swift, app/MeetingTranscriber/Tests/HuggingFaceModelBrowserViewTests.swift]

### Approach
- `HuggingFaceModelSearch`: `@Observable @MainActor final class … : Identifiable` (a `UUID` id, so task 4 can present it with `sheet(item:)`). `init(catalog: any HuggingFaceModelCataloging, token: @escaping @MainActor () -> String?, debounce: Duration = .milliseconds(350))`. State: `query` (its `didSet` drives the search), read-only `results`, `listing: HuggingFaceRepositoryListing?`, `isSearching`, `isListing`, `message: String?`. Internal read-only `searchTask` / `listingTask` so tests await them instead of sleeping.
- Rules (R2, R3, spec Edge Cases): on a query change cancel `searchTask` and `listingTask`, clear `listing` and forget the chosen repository (so a late listing success or failure is discarded); trimmed length < 2 → empty results, nil message, no request; otherwise start a task that sleeps `debounce`, returns if cancelled, then calls `performSearch(trimmed)`. `performSearch` reads `token()` per call, applies the outcome only when the query it ran for is still the current trimmed query; success → results, message "No WhisperKit models match \"<query>\"." when empty; `HuggingFaceCatalogError` → results cleared, `message = error.message`; cancellation → no change. `choose(_ summary:)` cancels any earlier listing and starts `listingTask`; its result is applied only while that summary is still the one chosen (a `backToResults()` or another `choose` in between discards it); failure → `message`. `cancel()` cancels both tasks (the view calls it in `onDisappear`).
- `HuggingFaceModelBrowserView(search:, onUse: (HuggingFaceModelVariant, HuggingFaceRepositoryListing) -> Void, onCancel: () -> Void)`: one column, about 520×440 minimum. Search `TextField` bound to `search.query` (use `@Bindable`). Without a listing: one button row per result (repo id, download count) calling `search.choose`. With a listing: the repo id, a "Back to results" button, the license display text or "License not stated — check the model card", for a gated repository "Gated: accept the terms on huggingface.co and add your Hugging Face token in Settings.", a `Link` "Model card on Hugging Face" to the listing's model card URL, and one row per variant (name, size via `ByteCountFormatter` `.file` or "size unknown", a "Use" button calling `onUse`). No variants → "No variant this app can load. The model files have to sit in one folder per variant." and no "Use". `search.message` as a caption line; a small `ProgressView` while searching or listing. "Cancel" with `.keyboardShortcut(.cancelAction)` calls `onCancel`.
- `A11yID` (`Sources/A11yID.swift:84-90` style, one constant per control, dynamic rows as functions like `play(_:)` at `:114-116`): `huggingFaceSearchField`, `huggingFaceResult(_ repoID:)`, `huggingFaceBackButton`, `huggingFaceModelCardLink`, `huggingFaceUseVariant(_ name:)`, `huggingFaceCancelButton`. Do not add them to the `/ui/press` allowlist.
- Tests first for the model (`HuggingFaceModelSearchTests`, a fake `HuggingFaceModelCataloging` actor or `@unchecked Sendable` class that records calls and returns scripted results or errors, debounce `.zero`): under 2 characters → no call; a query change cancels the pending search (two quick changes → one call, for the last query); stale guard (first query's response arrives after the second query was set → results are the second's; script it with a continuation-gated fake); empty results message; each error case's message; token read per call (closure returning nil, then "abc" → recorded tokens); `choose` → listing; back, choose-again and a query edit or clear each discard a late listing success and a late listing failure (continuation-gated fake; results and message stay those of the current query); `cancel` stops a pending search.
- `HuggingFaceModelBrowserViewTests` (ViewInspector, one wiring test per control, located by the `A11yID` constants as in `Tests/TranscriptionSettingsCustomModelTests.swift:35-40,82-94`): the search field's `setInput` writes `search.query`; tapping a result row starts the listing for that repo (await `search.listingTask`); "Use" calls `onUse` with that variant and listing; "Cancel" calls `onCancel`; a non-commercial license shows its "— non-commercial" text; a listing without variants shows the no-variant line and no "Use" button; "Back to results" clears the listing. Prepare state by driving the model with the fake catalog, not by setting private fields.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/HuggingFaceModelCatalog.swift` — task 1's protocol, types and error messages
- `app/MeetingTranscriber/Tests/TranscriptionSettingsCustomModelTests.swift` — ViewInspector lookups by identifier
- `app/MeetingTranscriber/Sources/A11yID.swift:80-149` — identifier conventions
- `app/MeetingTranscriber/Sources/Settings/SpeakersSettingsView.swift:3-8,90-99` — sheet presented from a freshly created object (`sheet(item:)` pattern task 4 reuses)

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/AsyncGate.swift` — gating helper for ordering async test steps
- `app/MeetingTranscriber/Sources/AppPickerView.swift` — an existing sheet's layout and Cancel handling

### Key context
- A `@State` mutation is not observable from ViewInspector (CLAUDE.md "GUI Testing", layer 2): all mutable browser state lives in `HuggingFaceModelSearch`, which the test holds.
- Anonymous Hugging Face API calls are limited to 500 per 5 minutes; the pause before searching is what keeps typing well below that.
- No network in these tests; the live API is covered by task 1's opt-in test.
## Acceptance
- [ ] Typing sends one search per pause for the last query only, never for fewer than 2 characters, and an older response never replaces newer results; editing or clearing the query cancels a pending listing, and a late listing success or failure changes nothing.
- [ ] Each catalog error shows its one-line message; an empty result shows the no-match line; cancel stops pending work.
- [ ] Choosing a repository shows its variants with size, the license (with "— non-commercial" where it applies), the gated notice and the model-card link; no variants shows the no-variant line without "Use"; "Use" and "Cancel" report through their closures and change no setting.
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t3-home swift test --parallel --filter 'HuggingFace' > /private/tmp/gh9-t3.log 2>&1` green; `./scripts/lint.sh` clean with the pinned tools; `swift build -c release` clean.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
