---
satisfies: [R1, R9]
---
# gh-278-notes-made-again-are-kept-and-show-up.1 Number additional reports and never replace a file

## Description
Ends the data loss first: a second report from one template gets the next number instead of replacing the first and moving it to the Trash (R1, A1, A4). One pure name rule serves both the sheet and the run, so the sheet names the file the run writes.

**Size:** M
**Files:** `Sources/AdditionalReport.swift`, `Sources/ProtocolRegeneration.swift`, `Sources/ProtocolRegenerationTarget.swift`, `Sources/RegenerateProtocolView.swift`, `docs/architecture-macos.md`; tests `Tests/AdditionalReportTests.swift`, `Tests/ProtocolRegeneratorReportTests.swift`, `Tests/RegenerateProtocolViewTests.swift`, `Tests/RegenerateSaveAsTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/AdditionalReport.swift, app/MeetingTranscriber/Sources/ProtocolRegeneration.swift, app/MeetingTranscriber/Sources/ProtocolRegenerationTarget.swift, app/MeetingTranscriber/Sources/RegenerateProtocolView.swift, app/MeetingTranscriber/Tests/AdditionalReportTests.swift, app/MeetingTranscriber/Tests/ProtocolRegeneratorReportTests.swift, app/MeetingTranscriber/Tests/RegenerateProtocolViewTests.swift, app/MeetingTranscriber/Tests/RegenerateSaveAsTests.swift, docs/architecture-macos.md]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first: the pure name tests and the regenerator test for a second report fail on today's code.
1. **Name rule** (`Sources/AdditionalReport.swift`, beside `MeetingReportFolder`): a pure function from the report name `T` and the folder's file names to the first free candidate `T`, `T 2`, `T 3`, … (spec Architecture, R1). A candidate is taken when a file of that name exists in any case, or when `owner(ofFileName:)` gives it to another meeting (A4). Leave `slot(forReportNamed:)` and its `.free` / `.existing` / `.otherMeeting` answers as they are: the AI-title rename (`Sources/ArtifactRenamePlan.swift:63,97`) needs `.free` and keeps its meaning. Add the new function beside it.
2. **Sheet** (`ProtocolRegenerationTarget.reportSlot(for:)` at `Sources/ProtocolRegenerationTarget.swift:72-75`; `Sources/RegenerateProtocolView.swift:51-58,127-130,299-310`): the line under "An additional report" names the chosen file ("Saved as “<file>”. The current notes stay as they are."). The orange "Replaces the existing …" line goes, and so does the `reportNameTaken` disable of Generate, since a free number always exists.
3. **Run** (`Sources/ProtocolRegeneration.swift:286-320`): keep the up-front read of the main files and their `filesChanged` guard. Drop the `reportBefore` guard, the report part of `checkReportIsTheMeetings`' refusal and the `replacing:` aside-and-Trash branch for reports (`replaceReport`, `:411-417`). Right before the write, list the folder again, pick the name with the same function, write to a temporary file and move it onto that name with `ops.move` (`moveItem`, which fails rather than overwrite). When the move fails because the name appeared meanwhile, list again and take the next number (a few attempts, then today's "could not be saved"). A folder that cannot be listed at that moment ends the run with today's message and writes nothing. Report runs no longer call `reportKept`. `replaceProtocol` (the main notes) stays as it is; gh-280 changes it.
4. **Docs**, in the same change: `docs/architecture-macos.md` § Additional Reports (`:781-815`): numbering, nothing in the Trash, a claimed name skipped, a name taken during the run skipped, Generate no longer disabled for a claimed name. Touch the AI-title rename paragraph (`:766-772`) only where its text relied on replacing.

Tests:
- Name rule (pure, `Tests/AdditionalReportTests.swift:102-134` style): empty folder → `T`; `T` taken → `T 2`; `T` and `T 2` → `T 3`; a case variant of `T` taken → `T 2`; `T` claimed by a longer meeting → skipped; "Short 9" taken → "Short 10"; template "Board 2" → "Board 2", then "Board 2 2".
- Regenerator (pattern `Tests/ProtocolRegeneratorReportTests.swift:241,254`, `makeRegenerator(ops:hooks:)`, `assertRunLeavesEveryFile`): the test at `:168` changes from replace-and-trash to a second report "Short 2", the first byte for byte and nothing trashed. The requirement changed (A1 supersedes gh-190's A3); say so in the commit. The tests at `:181` and `:218-239` move to the new rule: a report that appears during the run → the next number, nothing replaced. Unlistable folder → today's message, nothing written. A meeting without notes still gets its main notes.
- Sheet (ViewInspector, `Tests/RegenerateProtocolViewTests.swift`; `Tests/RegenerateSaveAsTests.swift`): with a "Short" report present the line names "<meeting> (Short 2).md", no orange line, Generate enabled.
- The `ArtifactRenamePlan` tests pass unchanged.

### Investigation targets
**Required** (read before coding):
- `Sources/ProtocolRegeneration.swift:286-332,411-482` — the run, `checkReportIsTheMeetings`, `replaceReport`, `replaceFile`
- `Sources/AdditionalReport.swift:93-180` — `Slot`, `reports`, `slot(forReportNamed:)`, `owner(ofFileName:)`
- `Sources/RegenerateProtocolView.swift:51-58,127-130,299-310` — the report line and Generate's state
- `Tests/ProtocolRegeneratorReportTests.swift:160-260` — today's pins and the patterns to copy

**Optional** (reference as needed):
- `Sources/ArtifactRenamePlan.swift:55-100` — the other caller of `slot`
- `.flow/memory/bug/data/file-name-ownership-must-fold-case-to-2026-11-08.md` — fold case to refuse a name, compare exactly to claim a file

### Key context
- Fold case where a name is refused (taken), compare exactly where a file is claimed for a destructive action (project memory entry above).
- The row menu already sorts reports in natural order ("Short 2" before "Short 10"); do not add another sort.

## Acceptance
- [ ] Two "An additional report" runs with one template keep `<meeting> (T).md` byte for byte and add `<meeting> (T 2).md`; nothing goes to the Trash and `reportKept` is never called.
- [ ] The sheet's line names the file the run writes; the orange "Replaces the existing …" line is gone.
- [ ] A claimed name is skipped, a name taken during the run is skipped at write time, and an unlistable folder writes nothing and shows today's message.
- [ ] The AI-title rename behaves as before (its tests pass unmodified).
- [ ] `docs/architecture-macos.md` § Additional Reports describes the new behaviour.
- [ ] Each new or changed test fails on the code before this task.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
