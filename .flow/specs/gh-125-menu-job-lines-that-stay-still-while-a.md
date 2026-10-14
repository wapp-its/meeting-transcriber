# Menu job lines that stay still while a job runs

## Conversation Evidence

> user (turn 1): "And there is a bug with the "All transcriptions" menu - it disappears sometimes random while I hover over it - at the moment a transcription process is running (and it says longer than usual btw - what is happening?)"
> user (turn 3): "Maybe we should remove the finished sessions from the context menu now that we have the transcription overview"
> user (turn 4): "The "Processing" header in the menu is also misleading somehow"
> user (turn 5): "All Transcriptions overview and Protocol folder could be together next to each other..."
> user (selected): "A — mic + menu now (Recommended)" (fix the menu now)
> user (selected): "Start + expected finish (Recommended)" — option text: "e.g. "Transcribing · since 09:17 · ready about 09:21". Never changes while the menu is open; expected time comes from this recording's length and past speed, so 'longer than usual' is simply when the clock passes it."
> user (selected): "Only active + needs you (Recommended)" — option text: "Running, waiting, speaker names needed, failed. Finished jobs only in the window; the newest protocol is still one click via "Open Last Protocol"."
> user (selected): ""In progress" + "Needs you" (Recommended)" — option text: "Two small headers: running/waiting jobs under "In progress", speaker-names-needed and failed under "Needs you". Each header only when it has jobs."
> diagnosis 2026-10-14 (code and stage timing log): the job line shows the running stage's elapsed seconds, refreshed once per second, and the menu is a menu-style menu bar extra, so each tick rebuilds the whole menu under the pointer. The "longer than usual" hint compares the elapsed time with the average wall-clock time of all past runs of that stage for the engine (2:02 for WhisperKit, short test imports included), ignoring the recording's length; the 16-minute meeting that morning took 4:41, about 3:18 would have been normal at the 30-day speed (0.21 s per audio second), and the hint would have shown after about 3 minutes even at normal speed. The "Processing" header stands above every job line: waiting, running, speaker names needed, failed and the last three finished.

## Goal & Context

The menu bar menu is where the user starts recordings and opens results, and while a job runs it currently moves under the mouse: the item under the pointer loses its highlight or vanishes, and an open job submenu closes. [paraphrase] Its job section also says things that are not true: "Processing" above jobs that are finished or waiting on the user, and "longer than usual" for nearly every meeting longer than about a quarter of an hour. [paraphrase] Since the Transcriptions window ("All Transcriptions...") lists every job, the menu only needs the jobs that are under way or need the user. [paraphrase]

## Architecture & Data Models

- **The menu is redrawn only on job events.** No value the menu reads may change on a timer while a job runs; the menu content changes when a job is added or removed, or changes state (a stage starts or ends). [inferred] The per-second elapsed value has no other reader than the menu today. [paraphrase]
- **A stage's expected finish is a fixed value per running stage.** It is the stage's start time plus the recording's audio length times the stage's historical speed (wall-clock seconds per audio second) for the same configuration (engine and diarizer mode), taken from the stage-timing history the app already records. It is computed once when the stage starts and is not recomputed while that stage runs, so a reload of the history during the stage does not change the line. [inferred]
- **Which jobs the menu shows** is decided by the shared transcriptions list that also feeds the window; the menu takes waiting and running jobs, and jobs that need the user (speaker names needed, failed). The window keeps listing everything. [paraphrase]

## API Contracts

The job line of a running stage, after the meeting title and the existing " — " separator, reads exactly:

- with an expected finish: `<stage label> · since <start> · ready about <finish>`, e.g. `Transcribing · since 09:17 · ready about 09:21`
- without one (no history for this configuration, or no audio length): `<stage label> · since <start>`, e.g. `Transcribing · since 09:17`

`<stage label>` is the job state's existing label (Transcribing, Diarizing, Generating Protocol or their current wording); `<start>` and `<finish>` use the system's short time format (09:17 on the owner's Mac). [inferred] The same text appears inside the job's submenu where the progress line is shown today. [inferred]

## Edge Cases & Constraints

- When the clock passes the expected finish, the line does not change; the user reads "longer than usual" from the clock. [paraphrase]
- A stage history with no usable speed (no events for this configuration, a zero or missing audio length, a non-positive speed) gives no expected finish, never a time in the past or a zero-length estimate. [inferred]
- A finish time on the next day shows as its clock time only. [inferred]
- A finished job with warnings counts as finished: it leaves the menu like any other finished job and keeps its warnings in the window. [inferred]
- "Open Last Protocol" keeps working as today, so the newest protocol stays one click away with finished jobs gone from the menu. [paraphrase]
- Tests that pin today's "Processing" header, the finished jobs in the menu or the elapsed text change with this requirement. [inferred]

## Acceptance Criteria

- **R1:** While a job runs, nothing in the menu changes on a timer: between two job events the title of every menu item and every item of the job submenus stay identical, however much time passes. Errors: no error surface beyond R2's fallback. [paraphrase]
- **R2:** A running stage's job line reads as the API Contracts section shows, with the expected finish computed as the Architecture section says; without a usable speed or audio length it reads `<stage label> · since <start>`. Errors: missing history, zero or missing audio length and a non-positive speed each give the line without the finish part. [paraphrase]
- **R3:** The "longer than usual" hint and the live elapsed time no longer appear anywhere in the menu (no error surface beyond R1). [paraphrase]
- **R4:** The menu lists waiting and running jobs under a header "In progress" and jobs with speaker names needed or failed under a header "Needs you"; each header shows only when it has at least one job; finished jobs, with or without warnings, are not in the menu and are still listed in the Transcriptions window. Errors: no jobs at all shows neither header (no error surface beyond that). [paraphrase]
- **R5:** "All Transcriptions..." sits next to "Open Protocols Folder" in the same menu group and keeps its keyboard shortcut (no error surface beyond that). [paraphrase]

## Boundaries

- No change to the Transcriptions window. [inferred]
- No change to how stage timings are measured or logged, or to the stage statistics shown in Settings. [inferred]
- No change to the menu bar icon's animation. [inferred]
- No live time elsewhere in the menu in place of the removed one. [inferred]

## Decision Context

- **D1 · Fix the menu now, in its own spec.** why: owner picked "A — mic + menu now (Recommended)" after the diagnosis · status: active [owner-ratified 2026-10-14]
- **D2 · A running job's line shows its start and an expected finish instead of ticking seconds.** why: owner picked "Start + expected finish (Recommended)" over "Stage only" and "Timer, frozen while open" · status: active [owner-ratified 2026-10-14]
- **D3 · The menu keeps only active jobs and jobs that need the user; finished jobs live in the Transcriptions window.** why: owner, "Maybe we should remove the finished sessions from the context menu now that we have the transcription overview", then picked "Only active + needs you (Recommended)" · status: active [owner-ratified 2026-10-14]
- **D4 · Two headers, "In progress" and "Needs you", each only when it has jobs.** why: owner, "The "Processing" header in the menu is also misleading somehow", then picked ""In progress" + "Needs you" (Recommended)" · status: active [owner-ratified 2026-10-14]
- **D5 · "All Transcriptions..." moves next to "Open Protocols Folder".** why: owner, "All Transcriptions overview and Protocol folder could be together next to each other..." · status: active [owner-stated 2026-10-14]
- **A1 · The expected finish is computed once at stage start and never updated during the stage.** flip at: where the running stage's expected finish is stored · test: the R1 test (same text after time passes and after a history reload) · alternatives: recompute on every history reload, which changes the line mid-stage and rebuilds the menu · status: active [agent-assumed 2026-10-14]
- **A2 · The estimate uses speed per audio second for the same engine and diarizer mode, with no fallback to an average duration.** flip at: the expected-finish computation · test: the R2 tests (with and without history) · alternatives: fall back to the average wall-clock time, the measure that made "longer than usual" wrong · status: active [agent-assumed 2026-10-14]
- **A3 · A finished job with warnings leaves the menu like any finished job.** flip at: the menu's job filter · test: the R4 test · alternatives: list it under "Needs you" · status: active [agent-assumed 2026-10-14]
- **A4 · Times use the system's short time format.** flip at: the job line formatter · test: the R2 test with a fixed locale · status: active [agent-assumed 2026-10-14]

## Quick commands

```bash
cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh125-home swift test --parallel --filter 'MenuBarJobMenuTests|MenuBarViewTests|TranscriptionListTests|StageTimingStatsTests|PipelineQueueStageTimingTests' > /private/tmp/mt-gh125-focused.log 2>&1; rc=$?; tail -5 /private/tmp/mt-gh125-focused.log; test "$rc" = 0
```

<!-- Source: 25% user / 45% [paraphrase] / 30% [inferred] -->
