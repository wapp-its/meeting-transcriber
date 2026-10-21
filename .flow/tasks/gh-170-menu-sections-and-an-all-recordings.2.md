---
satisfies: [R1, R2, R3, R4]
---
# gh-170-menu-sections-and-an-all-recordings.2 Menu sections, the two renames, and Name Speakers inside Needs you

Touches: app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MenuBarView+Sections.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Sources/AppPickerView.swift, app/MeetingTranscriber/Tests/MenuBar*.swift

## Description
The menu the owner accepted in the mockup: three headed sections, two renamed items, "All Recordings…", and "Name Speakers…" as the first line of "Needs you". "Open Protocols Folder" and "Regenerate Protocol…" stay in the Recordings section for now; each leaves the menu in the task that gives it its new home (.4 the folder, .5 regenerate), so the app is whole after every task.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/MenuBarView.swift`, `app/MeetingTranscriber/Sources/MenuBarView+Sections.swift` (new, if the body outgrows the type), `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Sources/AppPickerView.swift` (one comment, `:84`), `app/MeetingTranscriber/Tests/MenuBarViewTests.swift`, `Tests/MenuBarMenuOrderTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MenuBarView+Sections.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Sources/AppPickerView.swift, app/MeetingTranscriber/Tests/MenuBar*.swift]

### Approach
- **Order** (spec Architecture, first bullet), replacing `body` (`MenuBarView.swift:100-126`), `watchControls` (`:244-278`) and `protocolActions` (`:330-354`): `consentPrompt`, `statusHeader`, `sessionControls`, `meetingInfo`, `errorInfo` as today (the #105 status block is not touched); Divider; section **Record & Import** with "Record Microphone Only" ⌘M (same `disabled` + `.help` reason, `:249-254`), "Record with Options…" ⌘R (was "Start Recording with Options…"), "Import Audio/Video Files…" ⌘P (was "Process Audio/Video Files..."); the first two keep their `onStopManualRecording == nil && state != .recording` gate, the import item is always shown; section **Audio Devices** with the shared microphone and output entries, the whole section left out when both `microphoneMenu` and `outputMenu` are nil; `jobSections` (`:283-306`) unchanged except that "Name Speakers…" ⌘N becomes the first line of the "Needs you" group, shown when `actions.nameSpeakers != nil` (that is `AppState.hasPendingSpeakerNamingJobs`), with the group's row indexes (`firstIndex`, `:294`) unchanged; section **Recordings** with "Open Last Protocol" ⌘O (same `lastFinished` gate, `:335`), "All Recordings…" ⌘T (was "All Transcriptions..."), then for now "Open Protocols Folder" and "Regenerate Protocol…"; `updateSection` (`:356-390`, its own leading divider as today); Divider; "Settings…" ⌘,; Divider; "Quit" ⌘Q.
- **Headings.** Use SwiftUI `Section("Record & Import") { ... }` for the three sections: inside a `MenuBarExtra` menu on macOS 14+ a Section header renders as a non-interactive header line, and ViewInspector finds it as the Section's header `Text`. Check once in the running app (`./scripts/run_app.sh`) that the headers show and do not react to a click; if they render as plain items instead, fall back to a `Text` heading styled like the job groups' caption `Label` (`:298-300`). The "In progress"/"Needs you" headers stay as they are (Boundaries).
- **Identifiers** (`A11yID.swift`, same style as `allTranscriptionsMenuItem` at `:78`): `recordMicrophoneMenuItem`, `recordWithOptionsMenuItem`, `importFilesMenuItem`, `nameSpeakersMenuItem`, `openLastProtocolMenuItem`, and rename `allTranscriptionsMenuItem` to `allRecordingsMenuItem`; the consent prompt already has a button titled "Record with Options…" (`:155`), so every test locates the menu item by its id, never by text.
- **Tests.** One wiring test per renamed or moved control by `A11yID` (tap, assert the `MenuActions` closure ran), kept in `MenuBarViewTests` where the old text-based tests were (`:233`, `:537`, `:670-707`, `:901`, `:946-955` name the old labels). A new `MenuBarMenuOrderTests` walks the document order of the menu for one representative state (idle, a finished job with a file, a naming-pending job, both device menus present) and asserts the sequence of headings and item labels from the mockup; then the visibility cases: both record items hidden while `state == .recording`, "Record Microphone Only" disabled with its reason when `noMic` or a manual start is registering, "Open Last Protocol" absent without a finished file, the Audio Devices heading absent when both device menus are nil, "Name Speakers…" absent when nothing waits for names and first in the group when something does.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/MenuBarView.swift:94-126,244-354` - the body, the items and their gates
- `app/MeetingTranscriber/Sources/MenuBarView.swift:283-306` - the job groups, their header style and the row index arithmetic that must not shift
- `app/MeetingTranscriber/Tests/MenuBarViewTests.swift` - the tests that find items by text today

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/MenuBarViewSessionControlsTests.swift` - the #105 assertions on the status block, which must stay green
- `app/MeetingTranscriber/Sources/AppPickerView.swift:84` - a comment naming the old "Start Recording with Options…" label

### Key context
- `JobState.speakerNamingPending.label` is "Name Speakers..." (`PipelineJob.swift:26`, pinned by `PipelineQueueTests.swift:3054`); that is the status label and is not renamed. The menu item reads "Name Speakers…" with the ellipsis character, as the spec writes it.
- A hidden item has no registered shortcut, so ⌘N exists only while the Needs-you line shows; that is R4's intended behaviour.
- `type_body_length` and the 300 ms type-check budget as in task .1: hoist the sections into computed properties, in a `MenuBarView+Sections.swift` extension if the file grows.

### Acceptance
- [ ] The menu renders, top to bottom, the items of the accepted mockup under the non-interactive headings "Record & Import", "Audio Devices" and "Recordings", with ⌘M, ⌘R, ⌘P, ⌘O, ⌘T, ⌘, and ⌘Q on the named items; `MenuBarMenuOrderTests` pins the sequence (R1).
- [ ] "Record Microphone Only" is disabled with its reason when no microphone is set or a manual start is still registering, both record items are hidden while a recording runs, "Open Last Protocol" is absent without a finished job with a file, and the Audio Devices heading is absent when neither device entry is shown; each pinned by a test (R1).
- [ ] "Import Audio/Video Files…" (⌘P) and "Record with Options…" (⌘R) replace the old labels and keep their actions; wiring tests find them by `A11yID` (R2).
- [ ] "All Recordings…" (⌘T) replaces "All Transcriptions..." and calls the same action (R3, menu side; the window title is task .4).
- [ ] "Name Speakers…" (⌘N) is the first line of the "Needs you" group exactly when a job waits for speaker names, and the group's per-job rows and their `A11yID` indexes are unchanged (R4).
- [ ] The #105 status block and `MenuBarViewSessionControlsTests` are untouched; the spec's Quick command is green; `./scripts/lint.sh` is clean.

## Acceptance
- [ ] TBD

## Done summary
The menu now shows the three headed sections of the accepted mockup ("Record & Import", "Audio Devices", "Recordings"), the renamed items "Record with Options…", "Import Audio/Video Files…" and "All Recordings…", and "Name Speakers…" (⌘N) as the first line of "Needs you". "Open Protocols Folder" and "Regenerate Protocol…" stay under Recordings until tasks .4 and .5 move them.

- R1, order and shortcuts: `MenuBarMenuOrderTests/testTheMenuReadsInTheMockupsOrderWithItsShortcuts` pins the full line sequence (headings, items, dividers) for an idle menu with a finished recording, a naming job and both device entries, and pins the exact shortcut map (⌘S, ⌘M, ⌘R, ⌘P, ⌘N, ⌘O, ⌘T, ⌘, and ⌘Q, no other item carrying one).
- R1, error cases: both record items hidden while recording (`MenuBarViewTests/testRecordMicrophoneButtonHiddenWhileRecording`, `testRecordAppButtonHiddenDuringRecording`, `testRecordAppAndStopBothHiddenDuringAutoRecording`). "Record Microphone Only" disabled with its reason, which is now asserted through `.help` (`testRecordMicrophoneButtonDisabledWhenNoMicIsSet`, `testRecordMicrophoneButtonDisabledWhileAManualStartIsStillInFlight`, control `testRecordMicrophoneButtonEnabledWhenTheMicrophoneIsAllowed`). "Open Last Protocol" absent without a finished file (`testOpenLastProtocolHiddenWithoutAFinishedJob`). Audio Devices heading absent with neither entry (`MenuBarMenuOrderTests/testTheAudioDevicesHeadingIsLeftOutWithoutADeviceEntry`).
- R2 and R3, wiring by `A11yID`: `testImportFilesItemCallsCallback`, `testRecordAppButtonCallsCallback`, `testAllRecordingsItemIsAlwaysShownAndCallsItsCallback`, `testOpenLastProtocolOpensTheLastFinishedJobsProtocol`, `testRecordMicrophoneButtonCallsCallback`.
- R4: `MenuBarMenuOrderTests/testNameSpeakersIsTheFirstLineOfNeedsYouAndShiftsNoRowIndex` (first line, row indexes unchanged, `jobRemoveButton(2)` still reaches its job), `testWithoutAJobWaitingForNamesNeedsYouOpensWithItsFirstJob`. `MenuBarViewTests/testNameSpeakersButtonCallsCallback` and `testNameSpeakersButtonHiddenWhenIdle` find the item by `A11yID.nameSpeakersMenuItem`.
- `MenuBarViewSessionControlsTests` and the #105 status block are untouched. No assertion was removed. Every test that found a menu item by its text now finds it by id.

baseline: green via handoff (green, verified at c58d11e9 by the conductor: both of the spec's Quick commands plus the notification suites, 183 tests, rc=0; c58d11e9..8a88c7a1 touched only .flow/). Lint baseline green (0 violations, 907 files).

Gates at HEAD (40622719): `flowctl gate classify` said FULL. Spec Quick command (log path /private/tmp/mt-gh170/task2/quick.log) rc=0, 115 tests. `--filter 'MenuBarMenuOrderTests'` rc=0, 4 tests (log /private/tmp/mt-gh170/task2/order.log); that class is outside the Quick command's filter. `./scripts/lint.sh` rc=0, 0 violations in 908 files. Not run, per the dispatch: the clean `xcodebuild` build for `swiftlint analyze`. Every new `A11yID` constant is read in `MenuBarView` and the tests, `allTranscriptionsMenuItem` has no reader left, and every `MenuActions` member is still read.

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

Feature routes: the menu items "Start Recording with Options…", "Process Audio/Video Files..." and "All Transcriptions..." are now "Record with Options…", "Import Audio/Video Files…" and "All Recordings…", and "Name Speakers…" moved into "Needs you". The routes to these features are unchanged.

### Decisions

- DECIDED: live header check skipped (installed app running, same bundle id); owner look-and-feel check needed after the PR builds
- ASSUMED: the three headings are SwiftUI `Section` headers, which a macOS 14 menu shows as header lines that cannot be clicked · alternatives: B - a `Text` heading styled like the job groups' caption `Label`; C - no heading, dividers only · flip at: `MenuBarView.recordAndImportSection`, `audioDevicesSection`, `recordingsSection` · test: `MenuBarMenuOrderTests/testTheMenuReadsInTheMockupsOrderWithItsShortcuts`. The owner's look check should also cover separators: where an explicit `Divider` meets a section boundary (before "Record & Import", the job group divider after "Audio Devices", the Settings divider after "Recordings"), the menu might show two separators.
- DECIDED: "Needs you" also shows when only `actions.nameSpeakers` is set and no naming row is listed - the task keys the item on that action alone, and in the app the two cannot disagree (both come from the queue's naming-pending jobs).
- DECIDED: the sections stay in `MenuBarView.swift` (496 of 600 lines, type body about 366 of 400), so no `MenuBarView+Sections.swift` - the task made that file conditional on the body outgrowing the type.
- DECIDED: "Settings..." keeps its three-dot label - R2 names only two renames, and the spec's prose ellipsis is not a third.
- DECIDED: the old visibility tests were switched to ids in place in `MenuBarViewTests` instead of moved into `MenuBarMenuOrderTests` - a move would duplicate or delete them; the new class holds only what nothing covered before (order, shortcuts, Audio Devices heading, Needs-you position).
- DECIDED: the shortcut walker is a copy of the private one in `MenuBarViewSessionControlsTests` - that file must stay untouched.
- DECIDED: `MenuActions.swift:8` ("Name Speakers...") and `:15` ("Start Recording with Options…") still name old labels in comments - the file is outside this task's Touches; written to the run notes (`task2-integration.md`) for the conductor.

stage: impl-review - ran [8a88c7a1..a4461bd5] (codex:gpt-6-astra:xhigh, three draws correctness/contracts/integration, all SHIP, 0 findings kept; one P3 FYI left out: MenuBarMenuOrderTests copies the private shortcut walker of MenuBarViewSessionControlsTests, which the task AC keeps untouched; receipt /tmp/impl-review-receipt-d1cb77e1af10-gh-170-menu-sections-and-an-all-recordings.2.json)
stage: wave-join - ran (lane cb015d88,40622719 cherry-picked onto 8a88c7a1 as 5b0354ed,a4461bd5; focused verify both Quick commands plus MenuBarMenuOrderTests rc 0, 128 tests, log /private/tmp/mt-gh170/verify2/quick.log)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 5b0354ed43bf3f7fa6ddf484a18d614e691e1436, a4461bd59bd8e2799cf9dc3e782daab6de254ddb
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh170/home swift test --parallel --filter '<spec Quick command 1 filter>|RecordingRowActionsTests|MenuBarMenuOrderTests' (rc 0, 128 tests); ./scripts/lint.sh (rc 0, 0 violations in 908 files)
- PRs: