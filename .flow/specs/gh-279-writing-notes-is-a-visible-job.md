# Writing notes is a visible job

## Conversation Evidence

The fork is public, so the owner's turns are paraphrased, not quoted.

> owner (paraphrased, 2026-11-19): after Generate in the regenerate sheet only a small spinner line appears, Cancel only closes the sheet while the run goes on, and once the sheet is closed nothing shows the run.
> owner (paraphrased, 2026-11-19): took the review's recommendation for its decision 1: the sheet closes at once after Generate, and the meeting's row shows the progress with Stop.
> owner (paraphrased, 2026-11-19): took the review's recommendation for its decision 4: a low-memory failure offers Try Again plus Settings…, with the needed and free memory in the message; a per-run choice of notes provider is filed for later, not built.
> review (2026-11-19, code reading and renders with made-up meetings; nothing was driven live): the regenerator runs as a task beside the pipeline queue, so the row, the menu bar and the icon never show it, and its sheet holds the whole window for up to 20 minutes with a local model.

## Goal & Context

<!-- Source: 0% user / 60% [paraphrase] / 40% [inferred] -->

From Generate to the result, the user always sees where a run is and what to do next. After this spec the sheet closes the moment a run is accepted, the meeting's row shows "Writing notes (<template>) · since HH:MM" with Stop, the menu bar lists the run under "In progress", and a success or a failure lands on the row with its next step. [paraphrase]

Why: a local model can take up to 20 minutes, and a sheet holds its window for as long as it is open. The row already has the place for progress and a Stop button, the menu bar already lists running jobs, and Transcribe Again already closes its sheet when its run is queued. [paraphrase]

This spec builds on "Notes made again are kept and show up" (gh-278), which makes notes written later reach the row, records a local-model stop as failed notes and fixes the sheet's smaller bugs. It waits for a mockup of the sheet and the row states. [inferred]

Stands on the original: no. It builds on gh-170 (All Recordings) and gh-190 (additional reports), which exist only in the fork. Related in the original: its open issue 873, a prototype of a separate "Meetings" window, with no pull request yet; #282 watches it. Related fork work: #261 (a local-model picker in the sheet), #263 (waiting for free memory), #262 (small gaps around re-runs and notes). [inferred]

## Architecture & Data Models

<!-- Source: 0% user / 30% [paraphrase] / 70% [inferred] -->

- **A run is a job of its meeting.** Writing notes runs in the pipeline queue as a stage of the meeting's job, the way Retry Meeting Notes runs today, so the row, the menu bar's "In progress", Stop, the waiting line and the relaunch come from the queue instead of a second mechanism (A1). The template, the background, the output (main notes or an additional report) and the report's name go with the job. [inferred]
- **Admission in the sheet.** Generate checks at once what the queue would refuse: a notes provider is chosen, record-only mode is off, the meeting is idle, and the report name is free. A refusal keeps the sheet open with a red line, as Transcribe Again's sheet does. [paraphrase]
- **The row's states** (to be drawn on the mockup): writing notes with its template, start time and Stop; waiting to write notes; done with the new report marked "New"; notes not written with the reason, Try Again and, for low memory or no local model, Settings…. [paraphrase]

## API Contracts

- `/v1` reports a meeting whose notes are being written or wait as a job that is not finished, with the existing state names. Any change of a state name or a warning text is documented in `docs/automation-api.md`. [inferred]

## Edge Cases & Constraints

- **Stop** ends the run, also a local model's helper, and leaves the meeting's files as they were. [paraphrase]
- **A run cut off by a quit** comes back after the relaunch as "Notes not written" with Try Again, never as a run that goes on by itself with lost background text. [paraphrase]
- **Other rows** keep their items enabled while one meeting's notes are written; only that meeting's row limits what it offers. [inferred]
- **A local-model run** keeps its own rules: one helper at a time, and it waits while a recording runs. [inferred]
- **Privacy:** the background text and the notes stay out of log lines, notifications and `/v1`. [inferred]

## Acceptance Criteria

- **R1:** Generate checks at once whether a provider is set, record-only mode is off, the meeting is idle and the report name is free. A refusal keeps the dialog open with a red line, as Transcribe Again does. Errors: each refusal names its reason; nothing is queued on a refusal. [paraphrase]
- **R2:** An accepted run closes the dialog. Within 1 s the row shows "Writing notes (<template>) · since HH:MM" with Stop, and the menu bar lists it under "In progress". No error surface beyond R1. [paraphrase]
- **R3:** Stop ends the run. The local model's helper is gone within 5 s, and the meeting's files are as before. Errors: a Stop after the notes were saved changes nothing. [paraphrase]
- **R4:** A second request for another meeting while one runs is accepted, and its row shows "Waiting to write notes". Errors: a second request for the same meeting is refused in the sheet (R1). [paraphrase]
- **R5:** Success: the row returns to its usual state, the new report is marked "New" on the reports line, and a notification "Report “<name>” saved" offers Open. Errors: until "A meeting's reports in one place" adds the reports line, the mark shows where the mockup places it. [paraphrase]
- **R6:** Failure: the row shows "Notes not written: <reason>" with Try Again, which reuses that run's template and background. For low memory or no model it also offers Settings…, which opens Settings → Output, and the low-memory reason names the needed and free memory (D2). Errors: Try Again for a meeting whose files are gone says so on the row. [paraphrase]
- **R7:** The dialog preselects the template the meeting's notes were made with (else the default) and "Add a report". Errors: a template that no longer exists falls back to the default with a short line saying so. [paraphrase]
- **R8:** A run cut off by a quit shows on its row after the relaunch as "Notes not written" with Try Again. No error surface beyond R6. [paraphrase]

## Boundaries

- The reports line, the Reports submenu and earlier versions belong to "A meeting's reports in one place". [paraphrase]
- A per-run choice of notes provider ("Write with") is filed for later (#281) and not built here (D2). [paraphrase]
- No change to the notes prompt, the templates or the notes files' format. `CLAUDE.md` and `AGENTS.md` stay unchanged. [inferred]

## Decision Context

- **D1 · After Generate the dialog closes at once, and the meeting's row shows the progress with Stop.** why: the owner took the review's recommendation A for its decision 1 (paraphrased): one place for progress, Stop and the result, as Transcribe Again works, without blocking the window for up to 20 minutes · alternatives: B — keep the dialog open with progress, then "Done" and "Open"; C — today's dialog · status: active [owner-stated 2026-11-19]
- **D2 · A low-memory failure offers Try Again plus Settings…, with the needed and free memory in the message; a per-run provider choice ("Write with") is filed for later, not built.** why: the owner took the review's recommendation A for its decision 4 (paraphrased): small, and the message says what to do · alternatives: B — also a "Write with" choice in the dialog for one run · status: active [owner-stated 2026-11-19]
- **A1 · A run of "Write Notes…" or "Regenerate Notes…" is a stage of its meeting's job in the pipeline queue, like Retry Meeting Notes, not a second runner beside it.** flip at: this spec's plan · test: the plan's queue tests for a run, a waiting run, Stop and a relaunch · alternatives: B — keep the regenerator and give it a per-meeting queue of its own · status: active [agent-assumed 2026-11-19]

Mockup gate: needed (dialog and row states); no code before the owner accepts the boards.
