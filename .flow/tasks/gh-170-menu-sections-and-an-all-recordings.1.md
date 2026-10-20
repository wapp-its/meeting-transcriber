---
satisfies: [R9]
---
# gh-170-menu-sections-and-an-all-recordings.1 One MenuActions value, one shared device picker, and the two leftovers settled

Touches: app/MeetingTranscriber/Sources/MenuActions.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MenuBarView+Devices.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/TranscriberStatus.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/TranscriptionList.swift, app/MeetingTranscriber/Tests/MenuBar*.swift, app/MeetingTranscriber/Tests/Notification*.swift, app/MeetingTranscriber/Tests/TranscriptionListTests.swift

## Description
The behaviour-preserving half of the menu work (#156 and #140's leftovers), done before the layout changes so task .2 edits a menu view with one dependency on the outside world instead of 21 closures. Nothing a user sees changes in this task: no label, shortcut, order or visibility moves.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/MenuActions.swift` (new), `app/MeetingTranscriber/Sources/MenuBarView.swift`, `app/MeetingTranscriber/Sources/MenuBarView+Devices.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/TranscriberStatus.swift`, `app/MeetingTranscriber/Sources/AppState.swift`, `app/MeetingTranscriber/Sources/TranscriptionList.swift`, the six menu test files, `Tests/NotificationManagerTests.swift`, `Tests/NotificationContentTests.swift`, `Tests/TranscriptionListTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/MenuActions.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MenuBarView+Devices.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/TranscriberStatus.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/TranscriptionList.swift, app/MeetingTranscriber/Tests/MenuBar*.swift, app/MeetingTranscriber/Tests/Notification*.swift, app/MeetingTranscriber/Tests/TranscriptionListTests.swift]

### Approach
- **The actions value.** A `MenuActions` struct (own file) carries the 21 closures that `MenuBarView` stores today (`MenuBarView.swift:4-72`), named without the `on` prefix (`startStop`, `recordApp`, `openLastProtocol`, ...). The three optional ones stay optional with the same meaning, because nil is what hides the item: `stopManualRecording` (Stop Recording, `:214-227`), `togglePause` (`:229-240`) and `nameSpeakers` (`:263-270`). A plain no-op default would make Name Speakers permanently visible. Give it a `static let noop` (every closure does nothing, optionals nil) so the six test files set only what they assert. `MenuBarView` keeps its data inputs (`status`, `isWatching`, `pipelineQueue`, `updateChecker`, `history`, `noMic`, `manualRecordingPendingOrActive`, `isRecordingPaused`, `consentQuestion`, `microphoneMenu`, `outputMenu`) and its direct `pipelineQueue` calls (`cancelJob`, `canRetryJob`, `retryJob`, `stageClock`, `:467-511`): those are state reads and queue calls, not callbacks, and moving them is not asked for.
- **Construction.** `MeetingTranscriberApp.menuBarContent` (`MeetingTranscriberApp.swift:149-198`) is the only production site; it builds the value with the same closures it passes today, `openLastProtocol` and `openProtocol` kept as two closures with their different missing-file handling (`:166-175`, `:589-598`). Migrate every test constructor: `Tests/MenuBarViewTests.swift:52` (`makeView`) plus the one site each in `MenuBarViewConsentPromptTests`, `MenuBarViewSessionControlsTests`, `MenuBarMicrophoneTests`, `MenuBarOutputTests`, `MenuBarJobMenuTests`, in the same commit as the view change.
- **The shared device picker.** `microphoneSection`/`microphonePicker` (`MenuBarView+Devices.swift:9-40`) and `outputSection`/`outputPicker` (`:44-74`) are the same shape; the differences are the enabled icon (`mic` vs `speaker.wave.2`, or `exclamationmark.triangle` when `outputMenu.warning`), the disabled icon (`mic.slash` vs `speaker.slash`), the Picker label string, the a11y id and the select closure. Replace the pair with one `deviceSection(...)` + `devicePicker(...)` parametrised by exactly those, fed by the existing `MicrophoneMenuState` and `OutputMenuState` (both unchanged; a tiny shared protocol over `title`, `isEnabled`, `items`, `checkedUID`, `hint` is fine if it keeps the files short). The a11y id must land on the `Picker` itself, where `Tests/MenuBarMicrophoneTests.swift:47` and `Tests/MenuBarOutputTests.swift:37` find it in two steps.
- **Leftover 1, `TranscriberStatus.protocolPath`** (`TranscriberStatus.swift:8`, coding key `:15`): no reader in Sources (the `status.protocolPath` reads in `TranscriptionList.swift:70` and `ProtocolRegeneration.swift:159,179` are on `JobStatus`, a different type; leave them). Remove the field and its writer `AppState.swift:577` (`protocolPath: nil`) and the test constructors that pass it (`Tests/MenuBarViewTests.swift:12-26` `makeStatus`, `MenuBarViewConsentPromptTests.swift:38`, `MenuBarViewSessionControlsTests.swift:44`, `NotificationManagerTests.swift` near 57-80, 181, 290, 299, `NotificationContentTests.swift:11`). The type stays `Codable`; a stored status file with the old key still decodes because unknown keys are ignored by `Codable` by default (check the decoder is a plain `JSONDecoder`).
- **Leftover 2, the negative-rank branch** (`TranscriptionList.swift:127-132` in `finishOrders`): its only reader is the `menuSections` tie-break (`:161`, `finishOrder ?? .min`) between terminal jobs with an equal enqueue time; `lastFinished` (`:177`) ignores failed jobs. Pin the contract first, as a refactor must: add tests to `Tests/TranscriptionListTests.swift` for (a) `menuSections` order of two failed live jobs with the same `enqueuedAt` and no history record, (b) `lastFinished` with one finished live job without a record next to a recorded one, (c) two unrecorded finished live jobs. Run them green on the current code, then remove the branch (R9 allows either outcome) and keep them green. If any of the three changes result without the branch, keep the branch instead, with a comment naming `menuSections` as its reader, and keep the tests.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/MenuBarView.swift:4-72` - the closures to move, and which optionals double as visibility
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:149-198` - the one construction site
- `app/MeetingTranscriber/Sources/MenuBarView+Devices.swift:1-75` - the two picker paths to merge
- `app/MeetingTranscriber/Sources/TranscriptionList.swift:118-180` - `finishOrders`, `menuSections`, `lastFinished`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/MenuBarMicrophoneTests.swift:47` and `Tests/MenuBarOutputTests.swift:37` - the two-step picker lookup the shared view must keep working
- `app/MeetingTranscriber/Tests/MenuBarViewTests.swift:12-60` - `makeStatus` / `makeView` helpers to migrate

### Key context
- `MenuBarView.swift` is near SwiftLint's `type_body_length` limit of 400 (it reached 417 after a merge in October); keep `MenuActions` in its own file and the device helpers in the `+Devices` extension. The `body` is hoisted into computed properties for the 300 ms type-check budget (`MenuBarView.swift:94-99`); keep that shape.
- CI's `swiftlint analyze` (`unused_declaration`) fails on a `MenuActions` member nothing reads; every member must be wired. Reproduce it locally with a clean `xcodebuild ... build-for-testing` log before the review, since `./scripts/lint.sh` does not run it.
- Working rules: match the surrounding code; no renames beyond the move, no new abstractions beyond the two named here.

### Acceptance
- [ ] `MenuBarView` stores no `on...` closures; it takes one `MenuActions` value, built in `MeetingTranscriberApp.menuBarContent`, and the three optional members still decide whether Stop Recording, Pause/Resume and Name Speakers are shown (R9).
- [ ] The Microphone and Output entries are rendered by one shared section/picker helper; `MenuBarMicrophoneTests` and `MenuBarOutputTests` still select through `A11yID.menuMicrophonePicker` / `A11yID.menuOutputPicker` found on the `Picker`, with the warning icon and the disabled icons unchanged (R9).
- [ ] `TranscriberStatus.protocolPath` is removed from Sources and Tests (no reader exists), and the `JobStatus.protocolPath` reads are untouched (R9).
- [ ] The negative-rank branch in `TranscriptionList.finishOrders` is removed, or kept with a comment naming `menuSections`' tie-break as its reader; `TranscriptionListTests` pins the tie-break order and `lastFinished` for unrecorded finished jobs, written before the change and green before and after (R9).
- [ ] No menu label, shortcut, order or visibility changes in this task; the existing menu tests keep their assertions and only their constructors change; the spec's Quick command is green.
- [ ] `./scripts/lint.sh` is clean and `MenuBarView.swift` stays under the `type_body_length` limit.

## Acceptance
- [ ] TBD

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
