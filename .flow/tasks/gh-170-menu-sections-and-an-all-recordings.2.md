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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
