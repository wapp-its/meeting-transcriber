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
The menu view now takes one `MenuActions` value (21 members, built in `MeetingTranscriberApp.menuBarContent` through a separate `menuActions` getter) and renders the Microphone and Output entries with one `deviceSection`/`devicePicker` helper. `TranscriberStatus.protocolPath` and the negative finish rank in `TranscriptionList.finishOrders` are gone. No label, shortcut, order, icon or visibility in the menu changed.

- R9, actions value: `MenuBarView` stores no `on...` closures. Stop Recording, Pause/Resume and Name Speakers still hide on a nil member, and Install Update still disables on a nil `installUpdate` (`MenuBarViewTests/testInstallItemIsDisabledWhileBlockedCheckingOrUnwired`, its "no callback" row). The six menu test files start from `MenuActions.noop`; only their constructors changed, and no assertion line was removed.
- R9, shared picker: `MenuBarMicrophoneTests` and `MenuBarOutputTests` still find `A11yID.menuMicrophonePicker` / `A11yID.menuOutputPicker` on the `Picker` and select through it. A throwaway ViewInspector probe (deleted, not committed) read the entry icons as `mic`, `mic.slash`, `speaker.wave.2`, `exclamationmark.triangle` (Teams routing) and `speaker.slash` (no output), the same literals as before.
- R9, leftovers: `TranscriberStatus.protocolPath` is removed from Sources and Tests, and the `JobStatus.protocolPath` reads are untouched. The app has no encode or decode site for `TranscriberStatus`, so the "plain `JSONDecoder`" check had nothing to check. The negative-rank branch is removed. `TranscriptionListTests` pins it with three new tests, committed first (417d794a) and green before and after the removal (8593eaf3).
- `MenuBarView` type body is 350 of 400 lines. `./scripts/lint.sh` reports 0 violations in 905 files.

baseline: green via handoff (green, verified at 79481cc5 by the conductor's baseline run of the spec's first Quick command: 112 tests, rc=0). Lint baseline green (0 violations, 904 files).

Gates at HEAD: spec Quick command rc=0 with 115 tests (112 plus the three pins); `NotificationManagerTests|NotificationContentTests|TranscriberStatusTests` rc=0 with 59 tests; `flowctl gate classify` said FULL, so the focused Quick commands ran. Not run, per the dispatch: the clean `xcodebuild` build for `swiftlint analyze` (`unused_declaration`). Every `MenuActions` member is read in `MenuBarView` or `MenuBarView+Devices`, and `noop` is read by the tests.

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

Feature routes: none changed.

### Decisions

- DECIDED: every closure keeps the type it had in `MenuBarView`, so six members are optional (`installUpdate`, `stopManualRecording`, `togglePause`, `nameSpeakers`, `answerConsent`, `recordConsentWithOptions`), three more than the task named. The move preserves behaviour this way, and a non-optional `installUpdate` would need the "no callback" assertion changed.
- DECIDED: `MenuActions` is a `@MainActor` struct with plain closure types, which makes `static let noop` legal. The `DebugRPCServer.SpeakerDBActions` pattern (`@MainActor`-typed closures) was rejected because Swift 6.2 fails with "failed to produce diagnostic for expression" on an optional `@MainActor` closure chosen by a ternary (measured with `swiftc -swift-version 6 -typecheck`), which is how the stop, pause and name actions are built.
- DECIDED: the six test helpers keep their `on...` parameters and copy them onto `MenuActions.noop`, so no call site or assertion changed. The 12 inline constructors in `MenuBarViewTests` set only the action they assert.
- DECIDED: `menuActions` is its own getter in `MeetingTranscriberApp`, so it gets its own type-check budget like the scenes. Three closures moved to one line each to keep the file at 597 lines, because `file_length` warns at 600 and `lint.sh` runs `--strict`.
- DECIDED: the device helper takes two small protocols (`DeviceMenuState`, plus `DeviceMenuItem` for the item fields), declared with their conformances in `MenuBarView+Devices.swift`. The state files sit outside this task's Touches, and the picker reads the item fields.
- DECIDED: the icons travel as one `(enabled:, disabled:)` pair because SwiftLint's `function_parameter_count` caps at 5. The picker label is a `LocalizedStringKey`, so `Picker` takes the same initializer the old string literal did.
- ASSUMED: removed the negative-rank branch, since all three pinned cases keep their result. It also settled two ties between jobs added at the identical instant. For `lastFinished` between two unrecorded finished jobs, the earlier one in queue order now wins (before, the later one did). In "Needs you", an unrecorded failed job and a job waiting for names now keep queue order (before, the naming job came first). Production cannot reach either tie, because each job's `enqueuedAt` is its own `Date()` and the snapshot keeps full precision · alternatives: B - keep the branch with a comment naming `menuSections` and `lastFinished` as its readers · flip at: `TranscriptionList.finishOrders` · test: `TranscriptionListTests/testFailedJobsAddedTogetherListUnrecordedOnesFirstInQueueOrder`, `testTheLastFinishedJobIsARecordedOneBeforeALaterUnrecordedOne`, `testTheLastFinishedOfTwoUnrecordedJobsIsTheOneAddedLater`

stage: impl-review - ran [04204eab..c58d11e9] (codex:gpt-6-astra:xhigh, three draws correctness/contracts/integration, all SHIP; one P2 follow-up kept, not fixed: equal-enqueuedAt ties after the negative-rank removal, see Decisions; receipt /tmp/impl-review-receipt-d1cb77e1af10-gh-170-menu-sections-and-an-all-recordings.1.json)
stage: wave-join - ran (lane 417d794a..2ec35265 cherry-picked onto 04204eab as 464703da..c58d11e9; focused verify both Quick commands plus notification suites rc 0, 183 tests, log /private/tmp/mt-gh170/verify1/quick.log)

Follow-up (review P2, not fixed, reviewers kept SHIP): with two jobs enqueued at the identical instant and no history record, the removed negative rank used to decide the tie; now queue order does. The task defines the contract as the three pinned cases, which keep their result, and lets R9 choose removal; production gives every job its own enqueuedAt.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 464703da46aebc486f7b3724e590c7b22e779448, 58a2115e84d2b28fffdaf25bb3836269d5d852d3, 46009ecbb749cb105b2605cd731c0149af0c96d2, e6483593540bacfde2e0d17b77c4d3c5ce0dbb00, c58d11e932c16fabae5e9b209db1f79d191d0380
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh170/home swift test --parallel --filter '<spec Quick command 1 filter>|RecordingRowActionsTests|NotificationManagerTests|NotificationContentTests|TranscriberStatusTests' (rc 0, 183 tests); ./scripts/lint.sh (rc 0, 0 violations)
- PRs: