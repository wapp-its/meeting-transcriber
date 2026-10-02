---
satisfies: [R1, R2, R3, R4]
---
# gh-17-settings-view-type-check-under-the-ci.1 Implement Settings view type-check under the CI limit

## Description
Whole-spec owner task (direct route). Implementation: the Transcription section of `TranscriptionSettingsView` moved out of `body` into `transcriptionSection`, one named property per row, in the original row order; the vocabulary row's file-picker action and bookmark-safe binding moved out of the view builder. Commit `b74801f`.

### Acceptance evidence

- **R1 (runner timing).** Before: `body` measured 142.82 ms in the analyze lane of fork CI run 37005022055 (a fast run), and failed the gate at 302 ms and 318 ms in run 37008386858 (attempts 1 and 2). After: fork CI run 37068250552, `ci.yml` dispatched on this branch with `b74801f` included, all jobs green; its analyze lane's "Report slowest type-checks" table no longer lists any `TranscriptionSettingsView` body, and its 10th entry is 84.67 ms, so every body of this view stayed below 84.67 ms. That run was a slow one: `PipelineController.makeQueue()` read 165.81 ms there against 91.88 ms in run 37005022055. Locally (Xcode 27.0, the analyze lane's flags), `body` went from 37-39 ms to 1.4 ms.
- **R2 (no visible change).** 167 tests in `TranscriptionSettingsVocabularyTests`, `SettingsViewTests`, `SettingsInteractionTests`, `ViewInspectorIdentifierTests` and the live-caption suites pass with no test edited, including the positional locator `form().section(0).hStack(3)`; `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 reports 0 violations; all CI jobs of run 37068250552 are green.
- **R3 (three green runs without a retry).** This criterion is about the fork PR's CI and cannot be shown before the PR exists. It is checked at the landing stage, before merge: the PR's `ci (upstream ci.yml)` check must pass on three consecutive runs with no "failed on the first attempt, retrying once" warning.
- **R4 (custom-model branch on top).** Trial merge of `origin/feat/custom-whisperkit-model` (`f2b84ee`) onto `b74801f` in a scratch worktree, not pushed: one conflict, only in `TranscriptionSettingsView.swift`. Resolved by giving `whisperKitModelPicker` the branch's picker selection binding, its "Custom model…" entry and identifier, and the conditional custom-model fields, and by keeping the branch's helper properties; nothing went back into `body`. The merged result builds (`xcodebuild build-for-testing`), its `body` measures 0.9 ms locally, the custom-model fields 10.6 ms, and 106 tests in `TranscriptionSettingsCustomModelTests`, `TranscriptionSettingsVocabularyTests`, `SettingsViewTests` and `SettingsInteractionTests` pass.
## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
Split the Transcription section of TranscriptionSettingsView out of `body`, one named property per row in the original order, and moved the vocabulary row's file-picker action and binding out of the view builder. `body` type-checks in 1.4 ms locally (was 37-39 ms); on a slow GitHub runner (fork CI run 37068250552) no body of the view reaches the slowest-ten cut-off of 84.67 ms (was 142.82 ms on a fast run, 302-331 ms on slow ones). No visible change: 167 settings and live-caption tests pass unedited, lint clean. A trial merge with the custom-model branch keeps its additions outside `body` (0.9 ms, 106 tests green). Three green PR runs without a retry (R3) are checked at landing.

stage: impl-review - ran [2026-10-03] NEEDS_WORK (evidence gap only, 0 code findings) -> evidence recorded -> SHIP (model: gpt-5.6-sol xhigh, one draw)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: b74801f637a1dc4538ac4efa71f7c22d27e2393f, 79f9547d942eb9cf75565104ec94d37b7a3764ba, bb09f3d6b2c95629ecf88cad909e99b1e03bc6f8
- Tests: swift test --filter 'TranscriptionSettingsVocabularyTests|SettingsViewTests|SettingsInteractionTests|ViewInspectorIdentifierTests|LiveCaption' (167 passed); ./scripts/lint.sh (0 violations); fork CI run 37068250552 (all jobs green)
- PRs: