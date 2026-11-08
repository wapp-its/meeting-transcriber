---
satisfies: [R1, R2, R3, R4, R5, R6]
---
# gh-190-keep-the-current-protocol-when-making.1 Implement Keep the current protocol when making another one

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
Regenerate Notes… on a meeting that already has notes now offers "Save as:" with "An additional report" preselected: the new notes go to `<basename> (<template name>).md` beside the meeting and the current notes stay; "Replace the current notes" works as before. One ownership rule (`AdditionalReport`, `MeetingReportFolder`) decides whose report a file is for the sheet's count and orange lines, the row menu, "Regenerate from File…", Move Meeting to Trash (reports enter gh-97's record under `previous_protocol` in the same save as the pending mark) and the AI-title rename (reports move in the same all-or-nothing run).

The review round fixed five edge cases: names compare without regard to case where that refuses or keeps a file, while a meeting lists, moves and deletes only reports under its exact name (A18); Retry Deletion keeps a listed report's identity, so a different file at the name of one already moved is refused as replaced; the rename takes a report only to a free name; the sheet reads the meeting again when a run ends (A19); "Regenerate from File…" decides by the folder's listing whether the chosen file's own transcript is there.

Verification on 74a90617: Homebrew 6105 tests, 65 skipped, 1 failure in the known flaky MtUpdateProviderTests.testATimedOutCheckReturnsOnlyOnceItsProcessGroupHasEnded (its class passes alone, 9/9); App Store 5464 tests, 65 skipped, 0 failures; every scripts/tests/test_*.sh passes; lint clean; clean xcodebuild build-for-testing succeeded and swiftlint analyze --strict found 0 violations in 1049 files.

Assumptions recorded: A13-A19.

stage: impl-review - ran [codex:gpt-6-astra:xhigh, 3-draw fan-out NEEDS_WORK (5 findings, validator kept 5) -> re-review NEEDS_WORK (1 introduced by the case fix) -> re-review SHIP]
stage: completion-review - skipped(policy: single-task, per-task SHIP covers spec surface)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: f24beed227475af5adef879a7247d31f44428965, 312fabc840c968b5df6f95a7bdbcccd341069fb2, 1108d9ffb3f73be273b5723f780107168ae96a9c, f66f12451d62017a4a0d8193349dabfc7f1b389e, 44ec90e004bab3fc712350391ade5df05226fb50, 74a9061722f25db791360edc5b63e2897e42566a
- Tests: cd app/MeetingTranscriber && swift build --build-tests && ../../scripts/ci/test-shards.sh run --shards 3 --skip ModelPreloadTests (Homebrew and -Xswiftc -DAPPSTORE), ./scripts/lint.sh, xcodebuild clean build-for-testing + swiftlint analyze --strict, scripts/tests/test_*.sh
- PRs: