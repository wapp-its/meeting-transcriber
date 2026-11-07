---
satisfies: [R3, R7, R14]
---
# gh-97-delete-recordings-by-hand-and-after-a.8 Multi-select, footer and docs

## Description
The last slice: several rows can be selected and moved to the Trash with one confirmation (R7), the window gets its footer (R3), and the docs are brought in line with what the spec built. Multi-select comes last because it changes the list's structure (`List(selection:)` and the selection context menu), which is easier on a window whose single-row actions are already proven.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/TranscriptionsView.swift`, `app/MeetingTranscriber/Sources/TranscriptionsSelection.swift` (new), `app/MeetingTranscriber/Sources/TrashConfirmationText.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Sources/RecordingFileSuffix.swift`, `docs/architecture-macos.md`, `docs/automation-api.md`, `README.md`, `app/MeetingTranscriber/Tests/TranscriptionsSelectionTests.swift` (new), `app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift`, `app/MeetingTranscriber/Tests/TrashConfirmationTextTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/TranscriptionsView.swift, app/MeetingTranscriber/Sources/TranscriptionsSelection.swift, app/MeetingTranscriber/Sources/TrashConfirmationText.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Sources/AllRecordingsActions.swift, app/MeetingTranscriber/Sources/RecordingFileSuffix.swift, docs/architecture-macos.md, docs/automation-api.md, README.md, app/MeetingTranscriber/Tests/TranscriptionsSelectionTests.swift, app/MeetingTranscriber/Tests/TranscriptionsViewTests.swift, app/MeetingTranscriber/Tests/TrashConfirmationTextTests.swift]

### Approach
- **Selection**: hold `Set<UUID>` in an `@Observable` `TranscriptionsSelection` the view owns (same reason as task .5's confirmation model), and turn the plain `List { ForEach }` (`TranscriptionsView.swift:138-151`) into `List(selection:)`, as `AppPickerView.swift:192` already does for a single selection on macOS 14; a `Set` binding makes it multi-select, with Shift and Command selection built in.
- **Menus**: replace the per-row `.contextMenu` with `.contextMenu(forSelectionType: UUID.self)`: one id → the row's full menu from task .4 (R4); several → only Move Audio to Trash… and Move Meeting to Trash…, applied to the selection. The "…" button on a row keeps acting on that row alone.
- **Plan, pure** (in `TranscriptionsSelection.swift`): from the selected entries, their records and audio sizes, and an action, return the meetings it applies to (R4's rules per meeting), how many are left out, the names of kept meetings, whether imports are among them, and the total audio size. The action is disabled when it applies to none.
- **Confirmation for several** (extend `TrashConfirmationText`): the mockup's "Move 3 meetings to the Trash?"; "Their audio (1.4 GB), transcripts and meeting notes go to the Trash, and the meetings leave this list."; "“Strategy offsite” is marked Keep. Keep only stops automatic deletion, so it goes too."; "Voice profiles learned from these meetings stay."; buttons "Cancel" and "Move to Trash". Add R7's lines for meetings left out and for imports whose files stay; the audio variant says that transcripts and meeting notes stay. Per-meeting failures follow task .3: each failed meeting stays as "Deletion incomplete".
- **Footer** below the list (`body`, `TranscriptionsView.swift:67-71`): the mockup's "8 recordings · audio 1.9 GB · recordings are deleted automatically after 30 days (Settings → Output)"; "… right after the notes …" for that value; no third part with Never; "3 of 8 selected" replaces the count while rows are selected. Count and size cover the rows shown by the current search; sizes come from the `RowAvailability` cache.
- **Docs**: `docs/architecture-macos.md` gets a short section on the meeting file record and the deletion rules near "Output Structure" (`:780`) and rows for the new types in its file tables, and its claim of a recordings retention policy (`:672-673`) is replaced by the real one; `docs/automation-api.md` adds a meeting moved to the Trash to the 404 reasons of `GET /v1/jobs/<id>` (`:171-174`); the comment at `RecordingFileSuffix.swift:28-30` stops saying the mic track stays in staging (all three tracks move); `README.md:282` names the Recordings section of the Output tab, and its sentence that the recording follows its own retention policy (`:309`) names that section. `CLAUDE.md` and `AGENTS.md` stay unchanged.
- **Tests, written first**: `TranscriptionsSelectionTests` for mixed selections (recorded, import, failed, no record, kept, live), the left-out count, imports and the disabled case; `TrashConfirmationTextTests` for the several-meetings texts; `TranscriptionsViewTests` for the footer text with and without a selection and for each retention value, and the selection confirmation landing in the model.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/TranscriptionsView.swift:60-160`, `:240-260` - body, list, row menu
- `app/MeetingTranscriber/Sources/AppPickerView.swift:180-200` - `List(selection:)` in this app
- `docs/architecture-macos.md:665-680`, `:780` - the wrong retention sentence and "Output Structure"
- `docs/automation-api.md:165-175` - the 404 list

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/RecordingFileSuffix.swift` - the stale comment
- `README.md:280-310` - the Output tab description

### Key context
- ViewInspector cannot drive a `List` selection or a selection context menu; set the selection through the `@Observable` model in tests and assert the plan and the footer, and leave the click itself to manual checking, as CLAUDE.md's GUI testing section allows.
- A row's inline buttons keep working inside `List(selection:)`; check that a click on the "…" button does not change the selection unexpectedly.
- The docs live in a public fork: describe the feature, not this spec or its task ids.

## Acceptance
- [ ] Rows can be selected with Shift and Command; with several selected the menu offers only the two Trash actions, applied after one confirmation that names kept meetings, says how many were left out and that imported files stay; the action is disabled when it applies to none; a failed meeting in the batch stays as "Deletion incomplete" (R7).
- [ ] The footer shows the count and total audio size of the rows shown, the retention sentence when the setting is not Never, and "N of M selected" while rows are selected (R3).
- [ ] `docs/architecture-macos.md`, `docs/automation-api.md`, the `RecordingFileSuffix` comment and `README.md` describe the record, the deletion rules and the 404 after Move Meeting to Trash; the false retention sentence is gone; `CLAUDE.md` and `AGENTS.md` are unchanged.
- [ ] `TranscriptionsSelectionTests` and the new view and text tests were written before the implementation and pass; the spec's quick command passes (R14).


## Done summary
The All Recordings window selects several rows with Shift and Command. Right-clicking a selection offers only Move Audio to Trash… and Move Meeting to Trash…, and one confirmation names the kept meetings, says how many selected meetings are left out and that imported files stay. A footer under the list shows the count of rows shown (or "N of M selected"), their audio on disk and what the retention setting deletes. The architecture overview, the automation API reference, the README and the RecordingFileSuffix comment now describe the meeting file record, the deletion rules and the 404 after Move Meeting to Trash.

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)
baseline: green via handoff (green (verified at 11a7db30 by the conductor; only .flow/ paths moved since))



### Commits (11a7db30..68c0fec4)

| Commit | What |
|---|---|
| 69e28903 | Extra 1: removes the unused `private struct Refused: Error {}` from the deletion flow tests |
| 8fb0882f | Extra 2: the comment on `AudioOnDisk.totalCount` says the count leaves out gone 16 kHz copies |
| 6bb70c87 | Multi-select, the selection menu, the confirmation for several meetings, the footer, with their tests |
| 68c0fec4 | Docs: architecture overview, automation API, README, RecordingFileSuffix comment |


### Gates (run on the committed code, no edits since)

- `gate classify`: FULL, exit 1, so the focused Quick classes ran.
- Spec's Quick filter: exit 0, 197 tests.
- New and changed classes (`TranscriptionsSelectionTests`, `TranscriptionsViewTests`, `TrashConfirmationTextTests`): exit 0, 72 tests; the two not in the Quick filter again at HEAD with `--parallel`: exit 0, 32 tests.
- `./scripts/lint.sh` with the pinned tools: exit 0, 0 violations.
- App Store variant, `swift build --build-tests -Xswiftc -DAPPSTORE` in a separate build folder: exit 0.
- `swiftlint analyze --strict` after a clean `xcodebuild clean build-for-testing`: exit 0, 0 violations in 1023 files. The unused `Refused` that task .7 reported is gone with extra 1.


### Tests first

- The 29 new tests ran first against compile-only stubs: all 29 failed, 109 failures, each on the stated values (the plan's meetings and counts, the footer text, the dialog lines, the menu items, the calls landing in the controller). The 43 existing tests in those classes passed.
- The first run against the implementation failed 2 new tests, both on my own just-written test code, and I corrected them without weakening an assertion. `testTheMenuFollowsHowManyRowsItIsFor`: ViewInspector cannot inspect a menu of nothing on its own, so the helper wraps the menu in a `VStack` and an empty menu reads as no items. `testEveryKeptMeetingIsNamed`: three meetings of 350 MB make 1.05 GB, not the 700 MB of the shared expected line, so the fixture sizes now add up to 700 MB.
- Existing tests updated because the spec adds the footer identifier: `TranscriptionsViewTests.testNoIdentifierCarriesATitleParticipantOrPath` and `TranscriptionsViewTests.testNoNewIdentifierCarriesATitleOrPath` (in `TranscriptionsViewTests+MeetingFiles.swift`) now also check `A11yID.transcriptionsFooter`. `makeView` takes an optional selection. No assertion was removed or loosened.
- Every test that moves files uses a temp folder under the scratch home and the injected `FakeTrash` of `MeetingDeletionHarness`; none reaches a real recordings folder, the real Trash or the installed app.


### Files outside the declared Touches

- `Tests/TranscriptionsViewTests+Selection.swift` (new): `TranscriptionsViewTests.swift` is at 487 lines, and the 371 lines of selection tests would break the lint's 600-line file limit. Same split as the existing `+MeetingFiles` and `+MeetingDeletion` files, as an extension of the same class.
- `Tests/TranscriptionsViewTests+MeetingFiles.swift`: one identifier added to an existing privacy test (above).
- The two named extras: `Tests/PipelineControllerTranscriptionsTests+MeetingDeletionFlows.swift` and `Sources/RecordingAudioLine.swift`.
- The several-meeting text tests went into the declared `TrashConfirmationTextTests.swift` as an extension, and the selection menu and confirmation code into an extension inside `TranscriptionsView.swift`, so no other source or test file was needed.


### Not run

- No real window was driven: Shift and Command selection, the real right-click menu over a selection, whether a click on a row's "…" button changes the selection, and the footer's cost with many rows are unverified. Selection comes from `List(selection:)` with a `Set` binding; the menu content is tested by calling `selectionMenu(for:)`, which `.contextMenu(forSelectionType:)` calls.
- The full suite and the sanitizers.


Feature-map route changed: in the All Recordings window, the Trash actions for several meetings are reached by selecting rows with Shift or Command and right-clicking the selection; the window now has a footer.

DECIDED: one file back stops the whole batch: if any meeting of the dialog would move a file the dialog did not count, nothing moves and the window says so (rule 1: conductor note, "when a file would move that the dialog did not name, nothing moves").
DECIDED: each selected meeting is judged by its own row's menu rule (`RecordingRowActions.menuItems`), and Move Meeting applies to none while Regenerate Notes runs (rule 1: R7 "R4's rules", conductor note on the window-wide regeneration rule).
DECIDED: the several-meeting dialog says that Notion pages stay and failed exports can no longer be retried, as the single dialog does (rule 1: R7 "per-meeting failures follow R5 and R6", R6, conductor note on `hasNotionPage`).
DECIDED: only rows the current search shows count as selected, for the footer and for the actions (rule 1: R3 "the count and size cover the rows shown"; rule 6 for the actions, so a hidden row is never acted on).
DECIDED: meetings acted on leave the selection; a left-out meeting, and every meeting of a stopped dialog, stays selected (rule 6).
DECIDED: the several-meeting dialog names no files, unlike the single dialogs; the plan keeps each meeting's counted paths for the stop check (rule 6: R7's mockup shape names none).
DECIDED: `TrashConfirmationPrompt` moved into `TranscriptionsSelection.swift` and the selection menu and confirmation code into an extension in `TranscriptionsView.swift`, to meet the lint's type and file length limits without a new source file (rule 6).
ASSUMED: the footer says "no audio" when the rows shown have none on disk · alternatives: B — "audio Zero KB"; C — leave the size part out · flip at: TranscriptionsSelection.swift:TranscriptionsFooter.text · test: TranscriptionsSelectionTests.testTheFooterSaysTheCountTheSizeAndWhatTheSettingDoes
ASSUMED: wording of the lines R7 names without words: "1 selected meeting is left out, as this action does not apply to it." / "N selected meetings are left out, as this action does not apply to them.", "Imported files stay where they are.", and the audio variant "Their audio (700 MB) goes to the Trash. Their transcripts and meeting notes stay." followed by the single dialog's "cannot transcribe again" line in the plural · alternatives: B — name the left-out meetings; C — no audio-variant loss line · flip at: TrashConfirmationText.swift:forSelection · test: TrashConfirmationTextTests.testItSaysHowManyWereLeftOut, testTheAudioOfSeveralSaysWhatStaysAndWhatIsLost
ASSUMED: a selection that leaves one meeting for the action keeps the selection dialog, in the singular ("Move 1 meeting to the Trash?" plus the left-out line) · alternatives: B — show that meeting's single dialog with its title and file names · flip at: TrashConfirmationText.swift:forSelection · test: TrashConfirmationTextTests.testASelectionLeavingOneMeetingReadsInTheSingular
ASSUMED: the stop message for a selection reads "Nothing was moved: the files of a selected meeting changed while the dialog was open. Choose the action again to see what it moves now." · alternatives: B — name the meeting · flip at: TrashConfirmationText.swift:nothingMoved · test: TranscriptionsViewTests.testAFileThatCameBackStopsTheWholeSelection
FOLLOW-UP: the footer reads the audio of every row the search shows, not only the visible ones, through `RowAvailability` on the main actor: once per refresh (tested), but on window open that is a disk probe per meeting, up to a thousand, and a network volume can block. Not measured. Moving the read off the main actor would cover the existing rows' reads too.
FOLLOW-UP: a Regenerate Notes started after a Trash dialog opened is not checked again at confirm; this held for the single dialog and now holds for a selection too.
FOLLOW-UP: a selection's moves to the Trash run on the main actor, one meeting after another.
FOLLOW-UP: drive the window once by hand or by event injection: Shift and Command selection, the right-click menu over a selection, the "…" button during a selection, and the footer with many rows.

stage: impl-review - ran (model: codex:gpt-6-astra:xhigh); verdict SHIP after 2 round(s)
DECIDED: the up-front check over every meeting of the dialog stays, so a file back while the dialog was open still moves nothing (rule 1: conductor note "when a file would move that the dialog did not name, nothing moves"); each meeting after the first is checked again right before its own action and the batch stops there, keeping the meetings not acted on selected (rule 6, and rule 1 for "every meeting of a stopped dialog stays selected")
DECIDED: the first meeting is not read again inside the loop, as nothing moved before it; this keeps the existing one-read-per-confirm behaviour that TranscriptionsViewTests.testConfirmingReadsTheRowsFilesAgain asserts (rule 6)
ASSUMED: the window's message when a selection stops part-way reads "Stopped after N of M meetings: the files of the next one changed meanwhile. Choose the action again to see what it moves now." · alternatives: B — name the meeting it stopped at; C — reuse the "Nothing was moved" line with a count of moved meetings · flip at: TrashConfirmationText.swift:stopped(after:of:) · test: TranscriptionsViewTests.testAFileThatComesBackDuringTheBatchStopsItBeforeThatMeeting
FOLLOW-UP: TranscriptionsView.confirm / PipelineController.moveAudioToTrash and moveMeetingToTrash (spec gh-97): the view checks a meeting's files and then the controller works them out again in the same main-actor call, so another process restoring a file in that instant could still move an uncounted file, as for the single-row dialog since task .5. Carrying each meeting's confirmed paths into the controller action would close it; matters if files of a meeting can reappear from outside the app within that window (a sync client restoring them, say).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 69e28903c5d7ef465db8bafaecb1d58e1129bea7, 8fb0882f2014d5a0c13fc553c08abb2fbd0936b1, 6bb70c877ebb392a77ae269beaae18c6caa3dd74, 68c0fec43104faeab1e84538a89ff9b7c797cb36, a6b7a9cb780412b02546db0053b77d4e29b5425a, 5f26c01116947e8fc9bd5876a293458fad623286
- Tests: baseline: green via handoff (verified at 11a7db30 by the conductor; only .flow/ paths moved since), CFFIXED_USER_HOME=<scratch> swift test --filter 'TranscriptionsSelectionTests|TrashConfirmationTextSelectionTests|TranscriptionsViewTests|TrashConfirmationTextTests' against compile-only stubs (exit 1, all 29 new tests failed with 109 failures on the stated values; the 43 existing tests passed), flowctl gate classify --base 11a7db30 (exit 1, FULL: code files changed), CFFIXED_USER_HOME=<scratch> swift test --filter 'TranscriptionsSelectionTests|TranscriptionsViewTests|TrashConfirmationTextTests' (exit 0, 72 tests), CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'TranscriptionsViewTests|TranscriptionListTests|RecordingRowActionsTests|RowAvailabilityTests|PipelineControllerTranscriptionsTests|TranscriptionsWindowPrivacyTests|TerminalJobStoreTests|TerminalJobRecordTests|AudioPersistencePolicyTests|OutputSettingsViewTests|SpeakerNamingStoreTests|ProcessedRecordingsLedgerTests' (exit 0, 197 tests), CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'TranscriptionsSelectionTests|TrashConfirmationTextTests' (exit 0, 32 tests), ./scripts/lint.sh with the pinned SwiftFormat and SwiftLint (exit 0, 0 violations), swift build --build-tests -Xswiftc -DAPPSTORE in a separate build folder (exit 0), swiftlint analyze --strict --compiler-log-path <clean xcodebuild clean build-for-testing log> (exit 0, 0 violations in 1023 files)
- PRs: