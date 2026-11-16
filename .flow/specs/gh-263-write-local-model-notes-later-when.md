# Write local-model notes later when memory is short

## Conversation Evidence

> owner 2026-11-16 (paraphrased): always gets "there was not enough memory" as an error with the local model; maybe smaller models are needed; asked which big models are best now and whether smaller quantized versions of them exist.
> app log 2026-11-16 (content-free lines): two refusals of the same meeting at normal memory pressure, once from the pipeline and once from "Regenerate Notes…"; free plus inactive memory was 21.5 and 22.0 GB, and the start check needed 22.5 GB (the 4-bit 27B model's 16.1 GB of weights plus 6 GiB).
> owner 2026-11-16, decision (paraphrased option text): "A — Smaller model + retry (Recommended)": use a smaller model during the day, and let a refused job wait and try again by itself instead of failing; lowering the safety margin and retry alone were not chosen.
> cross-check 2026-11-16 (Codex), paraphrased: free plus inactive memory falls about one for one while a model loads, so a start margin as small as the stop floor would end runs midway; keep the margin; let a refused job wait in a visible state, try again every 5 minutes and on wake, idle or screen lock, never bypassing the start check; stop automatic tries after 24 hours; after a stop mid-run wait 30 minutes, and stop after two such stops.

## Goal & Context

<!-- Source: 0% user / 55% [paraphrase] / 45% [inferred] -->

When the local model has too little free memory at the start, the app refuses the job, says "Meeting notes not written: low memory" and leaves it there. Under ordinary desktop load this happens to every meeting with the tested 27B model: the Mac had 0.5 to 1.0 GB less free memory than the start check needs. The user then has to free memory and regenerate the notes by hand. [paraphrase]

This spec makes a refused job wait and try again by itself, so the notes get written once memory is free (fewer apps open, the Mac idle or locked), without ever taking memory from the user's work. The start and stop rules stay as they are. Choosing a smaller model is the user's other lever; the model list in #259 shows which models fit. [paraphrase]

## Architecture & Data Models

<!-- Source: 0% user / 40% [paraphrase] / 60% [inferred] -->

- **Waiting job.** A protocol job refused by the local model for memory (low memory, or pressure not normal) is kept in a waiting-for-memory state with its saved transcript, the time it first waited, the number of mid-run stops, and the memory it lacked at the last try. The state is persisted with the job like other job state, so it survives a restart. [inferred]
- **Retry trigger.** One scheduler in the app tries the oldest waiting job: every 5 minutes, when the Mac wakes, when the screen locks, and after the user has been idle for 10 minutes. A try goes through the existing local-model gate unchanged (one helper at a time, waits while a recording runs, the same memory check), so it can never start a helper the gate would refuse. [paraphrase]
- **Order.** Waiting jobs are tried one at a time in the order they first waited. Other pipeline work (recording, transcription, diarization of later meetings) is not held up by a waiting job. [inferred]
- **Limits.** Automatic tries stop 24 hours after the first refusal, and after the second time the watchdog ends that job's helper for memory; after one such stop the next try waits at least 30 minutes. [paraphrase]

## API Contracts

<!-- Source: 0% user / 0% [paraphrase] / 100% [inferred] -->

- **Automation API (`/v1`).** A waiting job reads as not finished, with its reason ("waiting for free memory") and the missing amount in decimal GB; the existing state names and warning texts keep their meaning, and the change is documented in the API reference. [inferred]
- **Fork updater.** The persisted state of a waiting-for-memory job differs from the states the fork's updater waits for before it restarts the app (waiting, transcribing, diarizing, generating a protocol), because the job survives a restart and may wait for a day. [inferred]

## Edge Cases & Constraints

- **Mac asleep:** no tries while asleep; waking triggers one try. [paraphrase]
- **A recording starts during a try:** the existing deferral applies (the helper ends and the job comes back after the recording); this does not count as a memory stop. [inferred]
- **Memory frees up only briefly:** each try reads memory afresh; a try that is refused again keeps waiting without a new notification. [inferred]
- **Provider or model changed while a job waits:** the next try uses the settings at the time of the try; switched away from the local model, the job is written with the chosen provider at the next try. [inferred]
- **Model folder gone while waiting:** the job ends with today's "no local model" warning, as a job without a model does today. [inferred]
- **Several meetings refused in a row:** one notification per job at most, grouped when several jobs start waiting together, like the existing local-model notices. [inferred]
- **Units:** the missing amount is shown in decimal GB, as Finder counts, rounded to one decimal. [inferred]
- **App Store build:** unchanged; the local model provider does not exist there. [paraphrase]

## Acceptance Criteria

- **R1:** A protocol job that the local model refuses at the start for memory waits instead of ending: its row in the menu and in All Recordings reads "Waiting for free memory: needs <N> GB more", its transcript stays saved, and one notification says the notes will be written once enough memory is free. Errors: a later refusal of the same job sends no new notification; a refusal for any other reason (no model, unusable model, prompt too long) ends the job as today. [paraphrase]
- **R2:** A waiting job is tried again every 5 minutes, when the Mac wakes, when the screen locks, and after 10 minutes without user input; every try passes the full start check of the local-model gate. Errors: a try refused again keeps the job waiting and updates the missing amount; no try starts while a recording runs or another local-model job runs. [paraphrase]
- **R3:** When a later try writes the notes, the job ends as a normal finished protocol with the usual notice, and the waiting status is gone. No error surface beyond today's protocol outcomes. [inferred]
- **R4:** 24 hours after its first refusal, a job that is still waiting stops trying: it ends with today's warning "Protocol not written: low memory — transcript saved", "Regenerate Notes…" stays available, and one notification says that automatic tries stopped. No error surface beyond the notification. [paraphrase]
- **R5:** When the watchdog ends a job's running helper for memory, the job waits again, with its next automatic try no sooner than 30 minutes later; after the second such stop of the same job, automatic tries stop as in R4. Errors: a helper ended for a recording does not count as a memory stop. [paraphrase]
- **R6:** A waiting job's row offers "Try Now" (one try through the full start check) and Cancel (ends the job with its transcript saved, no more tries). Errors: "Try Now" refused again shows the missing amount in the row; Cancel while a try's helper runs ends that helper like today's job cancel. [inferred]
- **R7:** Waiting jobs survive an app quit, crash or restart: after launch they are waiting again, with the 24-hour limit and the stop count kept. Errors: a job whose transcript is gone is dropped like a failed job today. [paraphrase]
- **R8:** Several waiting jobs are tried one at a time, oldest first, and later meetings are recorded, transcribed and diarized meanwhile as usual. No error surface beyond R2. [inferred]
- **R9:** "Regenerate Notes…" refused for memory says in the sheet how much memory is missing and suggests closing apps or choosing a smaller model in Settings → Output; it does not wait by itself. No error surface beyond the message. [inferred]
- **R10:** The fork's updater can restart the app while jobs wait for memory, and the automation API reports a waiting job as not finished with its reason and missing amount (see API Contracts). Errors: none beyond R7. [inferred]

## Boundaries

- The start rule (model weights plus 6 GiB free at normal pressure) and the stop rule (4 GiB) stay unchanged. [paraphrase]
- No automatic switch to a smaller model. [inferred]
- No waking the Mac from sleep to write notes, and no rules for battery or Low Power Mode. [inferred]
- Manual "Regenerate Notes…" does not join the automatic tries. [inferred]

## Decision Context

- **D1 · A refused local-model job waits and tries again by itself, and a smaller model covers daytime use.** why: every meeting was refused under ordinary desktop load, the owner wants notes, and the Mac must keep enough resources for normal work · status: active [owner-stated 2026-11-16, paraphrased]
- **A1 · The start and stop rules stay as they are.** alternatives: B — lower the start margin to 4 GiB (would end runs at the stop floor midway); C — Codex's stricter start rule (the model's measured peak plus 5 GiB after 30 s of normal pressure) · flip at: the memory guard's constants · test: the guard's tests with injected readings stay unchanged · status: active [agent-inferred 2026-11-16; Codex cross-check proposed C]
- **A2 · Tries every 5 minutes and on wake, screen lock and 10 minutes idle.** alternatives: B — only when idle or locked; C — a fixed time at night · flip at: the retry scheduler's triggers · test: a scheduler test with an injected clock and wake, lock and idle events · status: active [agent-inferred 2026-11-16; Codex cross-check proposed it]
- **A3 · Automatic tries stop after 24 hours, or after the second mid-run stop for memory; one mid-run stop delays the next try by 30 minutes.** alternatives: B — try until the user cancels · flip at: the retry limits · test: a scheduler test that ends a job at 24 hours and after two stops · status: active [agent-inferred 2026-11-16; Codex cross-check proposed it]
- **A4 · The waiting state is persisted under its own name, not one the fork's updater waits for.** alternatives: B — reuse the existing waiting state and change the updater · flip at: the job state for waiting for memory · test: a persistence test that restores a waiting job after relaunch · status: active [agent-inferred 2026-11-16]
- **A5 · The missing amount is shown to the user.** alternatives: B — only "low memory" · flip at: the waiting row and the regenerate message · test: a text test for the row and the sheet message · status: active [agent-inferred 2026-11-16]

Related: #138 (the pilot that added the memory check), #259 (the model list that shows which models fit), #160 (the provider seam that carries local-model outcomes).

Mockup gate: no new screen; the row status, the buttons and the notice texts are given in R1, R4, R6 and R9.

## Requirement coverage

| R-ID | Task |
|------|------|
| R1 | TBD - populate via /flow-next:plan |
| R2 | TBD - populate via /flow-next:plan |
| R3 | TBD - populate via /flow-next:plan |
| R4 | TBD - populate via /flow-next:plan |
| R5 | TBD - populate via /flow-next:plan |
| R6 | TBD - populate via /flow-next:plan |
| R7 | TBD - populate via /flow-next:plan |
| R8 | TBD - populate via /flow-next:plan |
| R9 | TBD - populate via /flow-next:plan |
| R10 | TBD - populate via /flow-next:plan |
