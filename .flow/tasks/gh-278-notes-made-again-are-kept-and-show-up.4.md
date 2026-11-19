---
satisfies: [R3, R9]
---
# gh-278-notes-made-again-are-kept-and-show-up.4 Failed notes read "Notes not written" with their reason

## Description
Gives every finished meeting whose notes failed the status "Notes not written" in orange, with the failure's reason first in its outcome line, in the window and in the menu bar (R3 status, A3). It reads the detail .2 stores.

**Size:** M
**Files:** `Sources/JobMenuSummary.swift`, `Sources/MenuBarView+Jobs.swift`, `Sources/TranscriptionsView+RowParts.swift`, `Sources/TranscriptionList.swift`, `Sources/PipelineController+Transcriptions.swift`; tests `Tests/MenuBarJobMenuTests.swift`, `Tests/TranscriptionListTests.swift`, a row test (ViewInspector)
**Touches:** [app/MeetingTranscriber/Sources/JobMenuSummary.swift, app/MeetingTranscriber/Sources/MenuBarView+Jobs.swift, app/MeetingTranscriber/Sources/TranscriptionsView+RowParts.swift, app/MeetingTranscriber/Sources/TranscriptionList.swift, app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift, app/MeetingTranscriber/Tests/MenuBarJobMenuTests.swift, app/MeetingTranscriber/Tests/TranscriptionListTests.swift, app/MeetingTranscriber/Tests/TranscriptionsViewTests*.swift]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first: the status tests fail on today's code.
1. **Status** (`Sources/JobMenuSummary.swift:17-35`): `status(state:hasWarnings:progress:)` gets an input for failed notes and reads "Notes not written" for a `.done` job with any notes failure, else as today; `symbol` (`:41-59`) follows if it shows a warning sign. The `of: job` overloads (`:86-92`) read `notesFailure != nil`. Callers: `Sources/MenuBarView+Jobs.swift:88-98` (keep its hoisted `jobMenuTitle`/`jobSymbol` helpers, they exist for the type-check budget) and `Sources/TranscriptionsView+RowParts.swift:62-66`.
2. **Entry** (`TranscriptionEntry`): carries the job's notes failure and the shortfall detail for a job in the queue. `TranscriptionEntry(record:)` sets neither (`Sources/TranscriptionList.swift:120`, as it sets `hasRetryableMeetingNotes = false`). Copy both in the field-by-field init at `Sources/PipelineController+Transcriptions.swift:281-305`, or rows lose them.
3. **Row** (`Sources/TranscriptionsView+RowParts.swift:73-96`): the status in orange; the outcome line starts with the failure's sentence (the shortfall detail's sentence from .2 when present, else `MeetingNotesFailure.summary`), then the job's other warnings, leaving out the stored ones that only say the notes were not written: the four in `clearNotesFailure(at:)` and the two shortfall warnings. The stored warnings themselves stay unchanged.

Tests:
- Status (pattern `Tests/MenuBarJobMenuTests.swift:187-257`): `.done` with notes failed → "Notes not written" for `.other`, `.timedOut`, `.noProvider` and a low-memory stop; `.done` with warnings and no failure → "Done, with warnings"; other states as today.
- Entry (pattern `Tests/TranscriptionListTests.swift:128`): a queue job carries failure and detail; a history-only entry carries none; the copy init keeps both.
- Row (ViewInspector): a low-memory failure shows "Not enough free memory for the local model: needs about 22.5 GB, 21.5 GB free" first, "Protocol not written: low memory — transcript saved" is not shown, an unrelated warning is still listed; the status is "Notes not written".

### Investigation targets
**Required** (read before coding):
- `Sources/JobMenuSummary.swift` — status, symbol, overloads
- `Sources/TranscriptionsView+RowParts.swift:55-100` — status line and outcome line
- `Sources/TranscriptionList.swift:100-130,160-230` — the entry from a record, ordering
- `Sources/PipelineController+Transcriptions.swift:270-310` — the copy init

**Optional** (reference as needed):
- `Sources/MeetingNotesFailure.swift` — `summary` and `hint` per kind
- `docs/architecture/gui-testing.md` — wiring tests and A11yID lookups

## Acceptance
- [ ] A finished job with any notes failure reads "Notes not written" in the menu bar and, in orange, on its row; one without a failure reads as today.
- [ ] The row's outcome line starts with the failure's sentence (with the memory figures for a low-memory stop) and leaves out the warnings that only say the notes were not written; stored warnings are unchanged.
- [ ] A history-only entry carries no failure; the entry copy keeps the failure and the detail.
- [ ] Each new or changed test fails on the code before this task.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
