# Menu sections and an All Recordings window

## Conversation Evidence

> owner (paraphrased, 2026-10-20): rearrange and split the menu with headings and sections. Microphone and output get their own section with a heading.
> owner (paraphrased, 2026-10-20): the items from "Record Microphone Only" down to the file import form one group. Which heading fits them?
> owner (paraphrased, 2026-10-20): the protocol management could move into one menu entry, maybe "All Recordings", that opens an overview of all recordings. Regenerating the protocol, transcribing again, diarizing again, opening the folder and similar actions live in that window.
> owner (selected, 2026-10-20): "A: Mockup + renames (Recommended)", the menu mockup with the headings "Record & Import", "Audio Devices", "Recordings" and two renamed items.
> owner (selected, 2026-10-20): "Last Protocol + All Recordings (Recommended)", the newest protocol stays one click away and the folder, regenerate and re-run actions move into the window.
> owner (selected, 2026-10-20): "Two specs, after #105 (Recommended)", this spec moves today's actions into the menu sections and the window (with #156 and #140); transcribing again and identifying speakers again follow in #171 together with #97.
> owner (selected, 2026-10-20): "Mockup OK (Recommended)", the four-board mockup of the All Recordings window, its row menu, the regenerate sheet and the menu.
> issue #170: the accepted layout in words; #156 (one actions value instead of loose closures, one device picker) and #140 (menu code left unused) are done in the same change.

## Goal & Context

<!-- Source: 60% [paraphrase] / 25% owner-selected / 15% [inferred] -->

The menu bar menu lists about a dozen items with dividers but no headings. Recording, devices and results are mixed: "Open Protocols Folder" and "Regenerate Protocol…" sit next to "Open Last Protocol" and "All Transcriptions…", and every new result action would add another line. The owner wants headed sections, and one window that holds everything you can do with a finished recording. [paraphrase]

This spec does the first half: the menu gets its three headed sections, and today's Transcriptions window becomes "All Recordings" and takes over the result actions that leave the menu. Transcribing a recording again and identifying its speakers again are new capabilities. They follow in #171, together with showing and deleting the audio per meeting (#97), because both need the audio file per recording, which the list does not store yet.

The same change also does #156: the menu view stops taking about twenty loose callbacks and takes one actions value, and the microphone and output pickers share one implementation. It also settles #140's two leftovers from the last menu rework. Doing it here touches the menu once instead of twice. [paraphrase]

Who it is for: everyone who uses the menu bar menu. Why now: the owner asked for it after looking for a result action in the menu. It comes after #105, as the direction check #154 asks.

Upstream check (2026-10-20): the original project has no open issue or pull request about the menu layout, a recordings window or regenerating a protocol.

## Architecture & Data Models

<!-- Source: 50% owner-selected mockup / 50% [inferred] -->

- **Menu, top to bottom** (accepted mockup): the open recording prompt when there is one (unchanged); the status block (status line and detail, the controls under it: Stop Recording (⌘.) while a recording runs, otherwise the watch toggle (⌘S), and Pause/Resume; the meeting line, an error line), as #105 leaves it; then the section **Record & Import** with "Record Microphone Only" (⌘M), "Record with Options…" (⌘R) and "Import Audio/Video Files…" (⌘P); the section **Audio Devices** with the Microphone and Output entries; the job groups "In progress" and "Needs you" as today; the section **Recordings** with "Open Last Protocol" (⌘O) and "All Recordings…" (⌘T); then the update item when one is offered; "Settings…" (⌘,); "Quit" (⌘Q).
- A section heading is a non-interactive heading line inside the menu, not a clickable item. [inferred]
- "Name Speakers…" (⌘N) appears as the first line of the "Needs you" group, which exists whenever a job waits for names. [inferred]
- **The window** keeps its list source (the same entries the menu's job groups come from) and its search. It is titled "All Recordings". Its toolbar holds the search field, "Open Protocols Folder" and "Regenerate from File…".
- **Each row** keeps its text lines (title; app, date and time, duration; status; error or warnings) and gets one main button that depends on its state, plus a "…" button whose menu also opens on a right-click on the row. The row's actions come from one pure decision (state and available files in, main action and menu items out), so they are tested without the view. [inferred]
- **Regenerate Protocol** becomes a sheet of the All Recordings window. From a row it opens with that row's meeting filled in. From "Regenerate from File…" it opens without a meeting and offers "Choose File…" as today. The form inside (template, background info, the Trash note, Cancel and Generate) is today's form. The separate Regenerate Protocol window goes away. [paraphrase]
- **One menu actions value** replaces the loose callbacks the menu view takes today, and one device picker serves both the microphone and the output entries (#156). [paraphrase]

## API Contracts

<!-- Source: 100% [inferred] -->

- The automation API is unchanged. `/ui/tree` and `/ui/press` keep their window allowlist: the All Recordings window shows meeting titles and participants, so it stays off the allowlist like the Transcriptions window today. [inferred]

## Edge Cases & Constraints

<!-- Source: 100% [inferred] -->

- "Record Microphone Only" and "Record with Options…" keep today's visibility: both are hidden while a recording runs. "Record Microphone Only" keeps its disabled state and its reason (no microphone set, or a manual start still registering). [inferred]
- "Open Last Protocol" is shown only while a finished job with a file exists, as today. The Recordings heading and "All Recordings…" are always shown. [inferred]
- The Audio Devices heading is left out when neither the Microphone nor the Output entry is shown. [inferred]
- A row whose protocol or transcript file was moved or deleted shows today's "The file was moved or deleted." message when an action on it fails. [inferred]
- "Regenerate Protocol…" on a row is disabled only when the row has no usable transcript source: neither a transcript file nor a protocol that contains the full transcript. With "Save raw transcript separately" off, the transcript file is deleted after the job, and today's regenerator then reads the full transcript from the protocol, so such a row stays enabled. The sheet's Generate stays disabled when protocol generation is off or the app is in record-only mode, as today. [inferred]

## Acceptance Criteria

- **R1:** The menu shows its items in the order of the accepted mockup, under the non-interactive headings "Record & Import", "Audio Devices" and "Recordings", with the shortcuts ⌘M, ⌘R, ⌘P, ⌘O, ⌘T, ⌘, and ⌘Q on the items named in Architecture. Errors: "Record Microphone Only" disabled with its reason when no microphone is set or a manual start is still registering, and hidden together with "Record with Options…" while a recording runs; "Open Last Protocol" absent while no finished job has a file; the Audio Devices heading absent when neither device entry is shown. [paraphrase]
- **R2:** "Process Audio/Video Files…" reads "Import Audio/Video Files…" and "Start Recording with Options…" reads "Record with Options…". Each keeps its action and its shortcut. No error surface beyond R1. [paraphrase]
- **R3:** The menu no longer contains "Open Protocols Folder" or "Regenerate Protocol…". "All Transcriptions…" reads "All Recordings…" and opens the window titled "All Recordings". No error surface beyond R1. [paraphrase]
- **R4:** "Name Speakers…" (⌘N) is the first line of the "Needs you" group and is shown exactly when a job waits for speaker names. No error surface beyond R1. [inferred]
- **R5:** The All Recordings window's toolbar has the search field (same matching as today), "Open Protocols Folder" (opens the output folder as the old menu item did) and "Regenerate from File…" (opens the regenerate sheet without a meeting, with "Choose File…"). Errors: unchanged from the old menu item, which creates a missing output folder first and shows no message when the folder cannot be opened; this spec adds no new error surface there. [paraphrase]
- **R6:** Each row has one main button by state: Cancel while the job waits or runs; Name Speakers while it waits for names; Open Protocol when finished with a protocol, Open Transcript when finished with only a transcript; Retry when it failed and can be retried, Remove when it failed and cannot. Errors: a finished job with neither file has no main button. [paraphrase]
- **R7:** Each row has a "…" button, and a right-click on the row opens the same menu. It lists, where they apply: Open Protocol, Open Transcript, Show in Finder, Regenerate Protocol…, Retry, Remove (failed jobs only), Dismiss (jobs waiting for names only). Errors: an item whose file is missing is left out, and Regenerate Protocol… is disabled only when the row has no usable transcript source (no transcript file and no protocol that contains the full transcript). [paraphrase]
- **R8:** "Regenerate Protocol…" on a row opens the regenerate sheet over the window with that row's meeting (title, date and protocol file name) filled in and no "Choose File…" step. Generate writes the new protocol as today, including moving the old one to the Trash. Errors: generation off or record-only mode keeps Generate disabled as today; a generation failure shows today's error in the sheet. [paraphrase]
- **R9:** The menu view takes one actions value instead of separate callbacks, and the Microphone and Output entries are built by one shared picker; #140's two leftovers (`TranscriberStatus.protocolPath` and the negative-rank branch of the finish order) are removed, or kept with a comment that names their remaining reader. No error surface beyond R1. [paraphrase]
- **R10:** The row decision of R6 and R7 is a pure function covered by unit tests for every job state and for the three transcript sources (a separate transcript file, only the transcript inside the protocol, neither), and each new or moved control has one ViewInspector wiring test located by an `A11yID` constant, per the repo's GUI testing rules. The All Recordings window stays off the `/ui/tree` window allowlist. [inferred]

## Early proof point

Task gh-170-menu-sections-and-an-all-recordings.3 validates the core approach (one pure row decision, `RecordingRowActions`, covers every job state and the three transcript sources, so the window's rows and the right-click menu are rendered from a tested list instead of per-view conditions). If it fails, re-evaluate whether a row needs state `TranscriptionEntry` does not carry before continuing with gh-170-menu-sections-and-an-all-recordings.4+.

## Boundaries

- No "Transcribe Again…" or "Identify Speakers Again…" actions (#171). [paraphrase]
- No audio size, playback or deletion per meeting (#97). [paraphrase]
- No change to the search itself (#67, #126). [inferred]
- No change to the status block beyond what #105 does. [inferred]
- The "In progress" and "Needs you" groups keep their rows and actions; only "Name Speakers…" moves into "Needs you". [inferred]
- No live audio levels in the Audio Devices section (#150). [inferred]

## Quick commands

The test classes the tasks change (112 tests at the spec base, 109 s with a warm build cache; the scratch home keeps model downloads out of `~/Documents`). Run from the repository root; the log is read from the file, never piped.

```bash
mkdir -p /private/tmp/mt-gh170/home && cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh170/home swift test --parallel --filter 'MenuBarViewTests|MenuBarViewSessionControlsTests|MenuBarViewConsentPromptTests|MenuBarJobMenuTests|MenuBarMicrophoneTests|MenuBarOutputTests|TranscriptionsViewTests|TranscriptionListTests|RegenerateProtocolViewTests|TranscriptionsWindowPrivacyTests|PipelineControllerTranscriptionsTests' > /private/tmp/mt-gh170/quick.log 2>&1; rc=$?; tail -n 3 /private/tmp/mt-gh170/quick.log; test "$rc" = 0
```

From task 3 on (the class does not exist before it):

```bash
cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh170/home swift test --parallel --filter 'RecordingRowActionsTests' > /private/tmp/mt-gh170/quick-rows.log 2>&1; rc=$?; tail -n 3 /private/tmp/mt-gh170/quick-rows.log; test "$rc" = 0
```

## Decision Context

### Motivation

- **D1 · The menu has three headed sections, "Record & Import", "Audio Devices" and "Recordings", and two items are renamed ("Import Audio/Video Files…", "Record with Options…").** why: the owner picked mockup A over keeping the old names, because "Process…" under a record heading reads oddly · status: active [owner-ratified 2026-10-20]
- **D2 · "Open Last Protocol" and "All Recordings…" stay in the menu; the folder and regenerate actions move into the window.** why: the newest protocol stays one click away, everything else lives in one place · status: active [owner-ratified 2026-10-20]
- **D3 · Two specs: this one moves today's actions; transcribing again and identifying speakers again follow in #171 with #97.** why: both new actions need the audio path per recording, which #97 has to settle first · status: active [owner-ratified 2026-10-20]
- **D4 · The accepted mockup is the layout: rows with one main button and a "…" menu that also opens on right-click; toolbar with search, "Open Protocols Folder" and "Regenerate from File…"; regenerate as a sheet with the row's meeting filled in.** why: the owner accepted the four boards on 2026-10-20 ("Mockup OK") · alternatives: every row action as a visible button, as today (with up to seven actions the rows get too wide and wrap on a small window) · status: active [owner-ratified 2026-10-20]
- **D5 · Built after #105.** why: the direction check #154 puts #105 and #63 before more enhancements, and #105 changes the status block this menu builds on · status: active [owner-ratified 2026-10-20]
- **A1 · "Name Speakers…" moves into the "Needs you" group.** flip at: the menu layout · test: R4's wiring test · status: active [agent-inferred 2026-10-20]
- **A2 · The update item stays a group of its own, directly above "Settings…".** flip at: the menu layout · test: R1's order test · status: active [agent-inferred 2026-10-20]
- **A3 · "Regenerate from File…" opens the sheet without a meeting; only a row opens it with one.** flip at: the regenerate sheet's opening state · test: R5 · alternatives: dropping "Regenerate from File…" (transcripts from before the list existed are not in it and could not get a new protocol anymore) · status: active [agent-inferred 2026-10-20]
- **A4 · The separate Regenerate Protocol window is removed; the sheet replaces it.** flip at: the app's window scenes · test: R3 · status: active [agent-inferred 2026-10-20]
- **A5 · A row's "Name Speakers" selects that job in the naming window (`AppState.selectedNamingJobID`) before opening it.** alternatives: B - open the naming window as the menu item does, without selecting the row's job · flip at: `AllRecordingsActions.nameSpeakers`, built in `MeetingTranscriberApp` · test: the Name Speakers wiring test in `TranscriptionsViewTests` (task .4), which asserts the row's job id reaches the closure · status: active [agent-assumed 2026-10-20]
- **A6 · The "…" menu leaves out a file item whose file was missing at the last availability refresh (on entries change, window appear or activation, and after a row action; cached per row in `RowAvailability`, since SwiftUI builds menu content on every render), while the main button follows the entry's recorded files as today's Open does, so a file removed after the refresh still fails with "The file was moved or deleted."; Regenerate is enabled by the regenerator's own usability rule, not by file existence.** alternatives: B - check existence for the main button too, so it disappears with the file; C - no existence check, every file item stays and fails with the message · flip at: `RecordingRowActions.menuItems` and its `FilesOnDisk` input, resolved by `AllRecordingsActions.filesOnDisk` through `RowAvailability` · test: `RecordingRowActionsTests`, the missing-file cases (task .3); `RowAvailabilityTests`, removal and restoration (task .4) · status: active [agent-assumed 2026-10-20]

FIT: GO · 2026-10-20 · base 5978abbf · engine flow-next 9.1.1 · gh-105 only hid the watch toggle during a recording, which the spec already assumes; every other anchor is intact; three spots now say what stays hidden during a recording

DIRECTION: GO · 2026-10-20 · plan drafted · five tasks in three waves, the pure row decision first; no existing tool or one-day version replaces an app menu; the next features (#171's two re-run actions, #97's audio per meeting) are one `MenuItem` case and one actions member each, so the seams carry them; a fresh agent can build from the tasks' anchors

FIT: GO · 2026-10-20 · base 1500e93d · engine flow-next 9.1.1 · since the 20:42 receipt only this spec's own plan and its SHIP review moved; gh-169 changed two permission-check lines in MeetingTranscriberApp.swift outside every task anchor (anchors past line 245 sit two lines higher)

## Requirement coverage

| Req | Description | Task(s) | Gap justification |
| --- | --- | --- | --- |
| R1 | The menu shows its items in the order of the accepted mockup, under the non-interactive headings "Record & Import", "Audio Devices" and "Recordings", with the shortcuts ⌘M, ⌘R, ⌘P, ⌘O, ⌘T, ⌘, and ⌘Q on the items named in Architecture. Errors: "Record Microphone Only" disabled with its reason when no microphone is set or a manual start is still registering, and hidden together with "Record with Options…" while a recording runs; "Open Last Protocol" absent while no finished job has a file; the Audio Devices heading absent when neither device entry is shown. | gh-170-menu-sections-and-an-all-recordings.2 | — |
| R2 | "Process Audio/Video Files…" reads "Import Audio/Video Files…" and "Start Recording with Options…" reads "Record with Options…". Each keeps its action and its shortcut. No error surface beyond R1. | gh-170-menu-sections-and-an-all-recordings.2 | — |
| R3 | The menu no longer contains "Open Protocols Folder" or "Regenerate Protocol…". "All Transcriptions…" reads "All Recordings…" and opens the window titled "All Recordings". No error surface beyond R1. | gh-170-menu-sections-and-an-all-recordings.2, gh-170-menu-sections-and-an-all-recordings.4, gh-170-menu-sections-and-an-all-recordings.5 | — |
| R4 | "Name Speakers…" (⌘N) is the first line of the "Needs you" group and is shown exactly when a job waits for speaker names. No error surface beyond R1. | gh-170-menu-sections-and-an-all-recordings.2 | — |
| R5 | The All Recordings window's toolbar has the search field (same matching as today), "Open Protocols Folder" (opens the output folder as the old menu item did) and "Regenerate from File…" (opens the regenerate sheet without a meeting, with "Choose File…"). Errors: unchanged from the old menu item, which creates a missing output folder first and shows no message when the folder cannot be opened; this spec adds no new error surface there. | gh-170-menu-sections-and-an-all-recordings.4, gh-170-menu-sections-and-an-all-recordings.5 | — |
| R6 | Each row has one main button by state: Cancel while the job waits or runs; Name Speakers while it waits for names; Open Protocol when finished with a protocol, Open Transcript when finished with only a transcript; Retry when it failed and can be retried, Remove when it failed and cannot. Errors: a finished job with neither file has no main button. | gh-170-menu-sections-and-an-all-recordings.3, gh-170-menu-sections-and-an-all-recordings.4 | — |
| R7 | Each row has a "…" button, and a right-click on the row opens the same menu. It lists, where they apply: Open Protocol, Open Transcript, Show in Finder, Regenerate Protocol…, Retry, Remove (failed jobs only), Dismiss (jobs waiting for names only). Errors: an item whose file is missing is left out, and Regenerate Protocol… is disabled only when the row has no usable transcript source (no transcript file and no protocol that contains the full transcript). | gh-170-menu-sections-and-an-all-recordings.3, gh-170-menu-sections-and-an-all-recordings.4 | — |
| R8 | "Regenerate Protocol…" on a row opens the regenerate sheet over the window with that row's meeting (title, date and protocol file name) filled in and no "Choose File…" step. Generate writes the new protocol as today, including moving the old one to the Trash. Errors: generation off or record-only mode keeps Generate disabled as today; a generation failure shows today's error in the sheet. | gh-170-menu-sections-and-an-all-recordings.5 | — |
| R9 | The menu view takes one actions value instead of separate callbacks, and the Microphone and Output entries are built by one shared picker; #140's two leftovers (`TranscriberStatus.protocolPath` and the negative-rank branch of the finish order) are removed, or kept with a comment that names their remaining reader. No error surface beyond R1. | gh-170-menu-sections-and-an-all-recordings.1 | — |
| R10 | The row decision of R6 and R7 is a pure function covered by unit tests for every job state and for the three transcript sources (a separate transcript file, only the transcript inside the protocol, neither), and each new or moved control has one ViewInspector wiring test located by an `A11yID` constant, per the repo's GUI testing rules. The All Recordings window stays off the `/ui/tree` window allowlist. | gh-170-menu-sections-and-an-all-recordings.3, gh-170-menu-sections-and-an-all-recordings.4, gh-170-menu-sections-and-an-all-recordings.5 | — |

