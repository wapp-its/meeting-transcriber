---
satisfies: [R1, R2, R3, R4, R5, R6, R7]
---
# gh-258-name-teams-recordings-after-the-meeting.1 Implement Name Teams recordings after the meeting window

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
### What changed

A detected Teams recording is now named after the window that best describes the meeting, and keeps the best name it sees while the call runs.

- **Ranking (R1, R2):** `TeamsWindowTitle` ranks Teams window titles: the meeting window ("<meeting> | <organisation> | <account> | Microsoft Teams", three or more parts after the suffix), then the compact call window ("Meeting compact view | <title>", prefix dropped), then any other Teams-suffixed window, then any other window; ties go to list order. `MeetingTitleMatcher.selectRankedTitle` applies it with the existing idle, empty and app-name filter (now shared as `usableTitle`). `PowerAssertionDetector` uses it for Teams detection; every other app keeps `selectWindowTitle` (R5). `WatchLoop.cleanTitle(of:)` also drops the compact prefix, for Teams meetings only; every detected-meeting title goes through it.
- **Refresh (R3, R4):** new `MeetingDetecting.rankedWindowTitle(for:)` (default nil, forwarded by `CompositeMeetingDetector`, which asks each strategy once, answered by `PowerAssertionDetector` for Teams only). `WatchLoop+MeetingTitle.swift` holds the recording's title (`titledMeeting`); the meeting-end wait asks on each poll whose decision is `.continuePolling(.listening(signalLostAt: nil))`, takes a strictly better rank (the placeholder gives way to any usable window), updates `currentMeeting` and the "Recording: " / "Paused: " detail, and `finishMeetingRecording` hands the held title to the job and the record-only sidecar.
- **Diagnostics (R6):** `meeting_title_rank at=detection rank=<n|none> parts=<n>` when a Teams recording starts and `meeting_title_rank at=change rank=<n> parts=<n> was=<n|none>` at each change; never the title.
- **Docs (R7):** `docs/architecture/detection.md` "Meeting titles" bullet; `docs/architecture-macos.md` lists the two new files.

### Decisions

- Decided: the compact prefix is checked before the part count, so a compact window with several parts still ranks 2 (A1's order).
- Decided: the detection line is written when the recording's wait starts, not at the detector poll, so it fires once per recording and also for Record Again and approved prompts.
- Decided: the loop guards Teams as well as the detector, so a test double or a future detector cannot retitle another app.
- Assumed (A8 in the spec): Record Again after a stop by hand or a silence stop starts from the held title.

### Tests

- Failing first: `TeamsWindowTitleRankTests` committed alone (a804da06), 9 of 13 failed on the old pick.
- New: `WatchLoopMeetingTitleTests` (7 loop tests: better replaces, weaker never; placeholder; record-only sidecar; new call does not rename; signal lost; Zoom no refresh; refresh during a pause), detector and composite tests in `TeamsWindowTitleRankTests`.
- Mutations of the wiring lines each fail tests: no refresh (6 tests), no signal guard (1), job takes the detection title (4), refresh before the end decision (2).
- Changed by requirement R6: five exact-lines assertions in the stop-by-hand, Record Again, record-after-Ignore and silence-stop tests now also expect the new `meeting_title_rank at=detection` line; they still pin the exact lines, and no title appears in them.

### Review

- Round 1 (three lenses, codex gpt-6.1-sol xhigh): NEEDS_WORK. Fixed both: the composite's `lazy.compactMap(...).first` asked the answering detector twice and trapped when the second window read found nothing (regression test trapped before the fix); the compact-prefix cleanup ran for every app (now Teams only). Lesson captured in `.flow/memory/bug/runtime-errors/`.
- Round 2 (one reviewer, resumed): SHIP.

stage: impl-review - ran [codex:gpt-6.1-sol:xhigh, NEEDS_WORK -> SHIP in 2 rounds]

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: a804da06607e388a2e81abd1b5f1dc8d11b38a4c, 208fc42b0660d0c575eccbd0ba573f07e8c3c487, 678b6bcb26337aef17ae5c4c6f498d954dc498b7
- Tests: cd app/MeetingTranscriber && swift build -j 6 --build-tests && ../../scripts/ci/test-shards.sh run --shards 2 --skip ModelPreloadTests (6761 tests; 1 environmental failure: TranscriptionsViewTests row-menu snapshot highlights the row under the real pointer, passes alone) ; ./scripts/lint.sh (0 violations)
- PRs: