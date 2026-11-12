---
satisfies: [R1, R2, R3, R4, R5, R6]
---
# gh-208-show-the-last-recording-in-its-own-menu.1 Implement Show the last recording in its own menu section

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
The menu now shows the newest finished recording in its own "Last Recording" section above "Recordings": the recording's name, a details line with its app and time ("Teams · Today at 10:30", "Zoom · 10 Nov 2026 at 9:00"), and the open item with Cmd-O, now labelled "Open Notes" or "Open in Notion". "Recordings" keeps only "All Recordings…"; the section and its heading are left out while no finished recording has a file or a Notion page.

- Name, details and open item come from one entry, the one `TranscriptionList.lastFinished` already picked; which recording counts as newest and where the item goes are unchanged. The item keeps its shortcut, action (`openLastNotes`) and `A11yID.openLastNotesMenuItem`.
- The details line is `MenuBarView.lastRecordingDetails(for:now:calendar:locale:)` in the new `MenuBarView+LastRecording.swift`, pure and tested with a fixed clock, time zone and locale. The name and details lines are plain `Text`, set like the meeting lines at the top of the menu.
- Decision recorded in the spec as A4 [agent-assumed]: the day and time are joined with "at", as macOS and the All Recordings window write them in English; the date and time follow the user's locale, the words stay English.
- Also updated: doc comments naming the old label, and the menu rows in `docs/architecture-macos.md` (new row for the extension file). The moved-file notification title "Open Last Notes" is unchanged on purpose.
- Tests first (commit e52ab73e, red by assertion on the old code): the whole-menu order and shortcut map, the section left out (no recording, only a failed job, a finished job with nothing to open), name and open item from the same recording when finish order and add order differ, the name and details lines not being actions, and both labels. The menu-order reader now also returns plain `Text` lines outside buttons, submenus, labels and section headers. The details-line tests (today, just after midnight, yesterday, just before midnight, an older day, start versus add time, missing app, missing time, both missing, a second locale) came with the change, since they call the new builder.
- Baseline: green (181 tests, 0 failures, same filter without the new class).
- Review: SHIP in one round, no findings; nothing declined.
- Possible follow-up, not verified: the menu reads the clock when it is drawn, as the All Recordings window does; if the menu is not redrawn across midnight, "Today" could read one day stale until the next state change.

Tests: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch dir> swift test --filter 'MenuBarMenuOrderTests|MenuBarViewTests|JobOpenTargetTests|TranscriptionListTests|MenuBarJobMenuTests|MenuBarNotionRetryTests|MenuBarViewSessionControlsTests|MenuBarViewConsentPromptTests|MenuBarMicrophoneTests|MenuBarOutputTests|TranscriptionsViewTests|MeetingTranscriberAppTests|MenuBarLastRecordingDetailsTests'` -> Executed 186 tests, with 0 failures. Lint: `./scripts/lint.sh` with the pinned SwiftFormat and SwiftLint -> 0/1170 files require formatting, 0 violations.

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

stage: impl-review - ran [2026-11-12T11:49Z..2026-11-12T11:55Z] (codex:gpt-6-astra:xhigh, one reviewer, SHIP)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: e52ab73e620ceb224edaeac1e6f870d401f92b34, 44fb3335d5f7a515be7f4d3b8bd56e3da5c6ca8d
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch dir> swift test --filter 'MenuBarMenuOrderTests|MenuBarViewTests|JobOpenTargetTests|TranscriptionListTests|MenuBarJobMenuTests|MenuBarNotionRetryTests|MenuBarViewSessionControlsTests|MenuBarViewConsentPromptTests|MenuBarMicrophoneTests|MenuBarOutputTests|TranscriptionsViewTests|MeetingTranscriberAppTests|MenuBarLastRecordingDetailsTests' (186 tests, 0 failures), ./scripts/lint.sh with pinned SwiftFormat and SwiftLint (0 files to format, 0 violations)
- PRs: