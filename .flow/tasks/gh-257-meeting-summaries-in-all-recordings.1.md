---
satisfies: [R1, R2, R3, R4, R5, R6, R7, R8]
---
# gh-257-meeting-summaries-in-all-recordings.1 Implement Meeting summaries in All Recordings

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
All Recordings now shows a summary of at most 600 characters under each finished meeting's title (tooltip = full text), searchable, editable through "Edit Summary…" and its sheet. The summary comes from the notes' summary section or one background call to the notes provider; summaries live in their own lock-guarded `meeting-summaries.json`, together with each meeting's latest notes save, so a stale answer from any running build is dropped.

stage: impl-review - ran [2026-11-17T08:50Z..2026-11-17T09:18Z] (codex gpt-6.1-sol xhigh; round 1 three draws NEEDS_WORK, 5 findings, validator kept 5, all fixed in fff94cfd; re-review SHIP)
stage: implement - ran (model: claude-opus-5-5; delegated: 0)

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

Verification:
- baseline: green (swift build -j 6 --build-tests)
- Full Homebrew suite once before review (test-shards, 2 shards, skip ModelPreloadTests): 6893 of 6893 planned tests ran; 4 failures, all menu pins that R4 changes (RecordingRowReportsTests x3, RowAvailabilityTests x1); pins updated, those classes then 37/37 green.
- After the review fixes: build green; focused summary, sheet, view, controller, queue, re-run and regenerator classes 239 tests, 1 failure = row-menu snapshot with the mouse pointer over the menu (known environmental; passed in the full suite). App Store build green; its summary classes 31/31 green. Lint 0 violations.
- Wiring red checks: each production wiring line replaced by a constant made its test fail (15 tests across queue hooks, re-run hand-off, controller callbacks, launch prune, move-to-Trash forget, row summary, search, sheet, regenerator hook, local-model yield); each review fix disabled made its new test fail (5 tests).

Choices (rubric rule):
- Summary file `meeting-summaries.json` in the log folder, format version 1, one entry per job id, lock file beside it (conductor-decided, rules 1/6); it also records each meeting's latest notes save (review fix, rule 6).
- Summary heading words for all 23 notes languages, with a few synonyms per language (rule 6).
- `MeetingSummary.instruction` ends with a line break so the notes start on their own line (rule 6).
- A file that cannot be read is moved aside like one that cannot be decoded, per R1's text (rule 1).
- The launch prune runs only when the record file reloads (rule 6).
- Summary line in `.callout` secondary, two lines, tail truncation (rule 4; switch point TranscriptionsView+RowParts summaryLine; test TranscriptionsViewTests+Summary).
- The sheet's note line and "Use Summary from Notes" follow the meeting's summaries as the store holds them now; the 600 limit counts the field's raw characters (rule 4; test EditSummarySheetTests).
- Regenerate Notes reports its saved notes through a new `notesReplaced` regenerator hook instead of changing `regenerated`'s arity (rule 6).
- An answer that arrives after the 180 s limit counts as none (rule 6).
- Notes saves and Save from the sheet act only for meetings the window lists (rule 6).
- A re-run's Notion-only notes may be gone before the off-main read; then nothing changes (spec allows, rule 1).
- Log lines name the provider by its type name (rule 6); local summary calls hold no job place in the local-model gate (rule 6).
- A custom command that reads only `{transcript_file}` gets no summary call (A20, rule 1).

Feature-map routes changed: All Recordings row "…" and right-click menu gain "Edit Summary…" after "Show in Finder"; the search field hint reads "Search titles and summaries".

Follow-ups: none filed.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 6a8ed589224e2ab08e5647596a8a6f24e0a49ee0, fff94cfd3768e09a47152594ed4647a0e10c1c68
- Tests: cd app/MeetingTranscriber && swift build -j 6 --build-tests && ../../scripts/ci/test-shards.sh run --shards 2 --skip ModelPreloadTests (6893/6893 ran; 4 menu-pin failures from R4, fixed, classes then green), swift test --skip-build --filter summary/sheet/view/controller/queue/regenerator classes (239 tests; 1 known environmental snapshot failure: pointer over the menu), swift build -j 6 --build-tests -Xswiftc -DAPPSTORE --scratch-path .build-appstore + summary classes (31/31), ./scripts/lint.sh (0 violations)
- PRs: