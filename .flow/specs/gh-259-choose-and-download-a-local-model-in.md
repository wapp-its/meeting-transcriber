# Choose and download a local model in the app

## Conversation Evidence

> owner 2026-11-16, after seeing the local model settings (paraphrased): asked what the caption "Tested: mlx-community/Qwen3.8-27B-4bit" means, whether Hugging Face has a page such as a leaderboard that users could check for useful models and that the app could link, and said that automatic downloads like those for the transcription models would help.
> owner 2026-11-16 (paraphrased): asked whether there are websites that test which model works well on which hardware and that the app could use.
> owner 2026-11-16 (paraphrased): write the spec now. In the end the user needs to know which models run on his computer. The user tests the quality himself; a popup can recommend testing different models and testing again from time to time for new releases, because good new models come out all the time. The order of the models could follow the leaderboard of the base model a model is derived from; that does not reflect this use case, but it is a good indicator.
> owner 2026-11-16 (paraphrased): so the user sees what runs on his hardware, and then which models rank best on the leaderboard; real tests have to be done on his own templates and meetings.
> research 2026-11-16 (paraphrased): hardware sites (LocalScore, canitrun.dev, ModelFit, llmfit, fitllm.run) estimate fit and speed only, not quality; the app can compute fit itself from memory size and model size. Hugging Face's own eval results cover 12 of the 25 base models behind the 60 trending mlx-community text models, and its most common benchmark covers 7. The LMArena text leaderboard is published as a Hugging Face dataset (CC BY 4.0, updated daily, readable without a key) with language categories, German among them (320 models; Qwen3.8-27B at rank 82); it names models by display name, not by Hugging Face id. Artificial Analysis needs a per-user key and limits redistribution; the Open LLM Leaderboard has been frozen since 2025-03.
> cross-check 2026-11-16 (Codex), paraphrased: LMArena by language is the right source, with a bundled snapshot and a last-good cache; never mix two categories' ranks; a fine-tune must not inherit its base model's rank; never promise "runs well" from memory size alone, and prove a model with a guarded test generation; downloads need a pinned revision, hash checks, separate partial files, resume or clean-up, and only data files; keep notes of different models side by side; the biggest risk is recommending a large download that cannot finish a real meeting.

## Goal & Context

<!-- Source: 0% user / 60% [paraphrase] / 40% [inferred] -->

The local model provider writes meeting notes on the Mac, but the user has to find an MLX model on Hugging Face, download it outside the app and pick its folder by hand. The settings name one tested model and say nothing about what else would work. A user cannot tell which models run on his Mac, and a wrong pick costs a download of 5 to 40 GB.

This spec adds a model list to the local model settings. It shows the models that run on this Mac first, orders them by how their base model ranks on a public leaderboard, downloads the chosen one with consent, size and progress, and proves it with a short test run. The ranking is a general indicator only: the user judges quality on his own meetings and templates, so the app recommends trying a few models and looking again from time to time, and keeps the notes of different models side by side. [paraphrase]

It takes over the download part of #145; the XPC service and the App Store variant stay there.

## Architecture & Data Models

<!-- Source: 0% user / 30% [paraphrase] / 70% [inferred] -->

- **Model list.** Opened from the local model rows in Settings → Output. It reads the mlx-community text-generation models from the Hugging Face Hub and keeps, per repository: its id and revision, its base model and whether it is a plain conversion (quantization) of it or a fine-tune, its model type, its quantization bits, its weight size, its license and whether it is gated. Rows are grouped by base model; a row's conversions are its choices. [inferred]
- **Supported types.** The bundled helper reports the model types its pinned MLX library can load; the list offers only those. [inferred]
- **Fit estimate.** From the weight size plus the memory guard's admission headroom, against the Mac's physical memory; three labels (A3). It is an estimate shown before any download; the test run after the download is the proof. [paraphrase]
- **Ranking.** The LMArena text leaderboard, in the category of the protocol language when LMArena has one, otherwise overall. Base models are matched to leaderboard entries by a normalised name plus a small bundled alias table; anything ambiguous stays unranked. The app keeps the last ranking it fetched and ships a snapshot as a fallback. [paraphrase]
- **Downloads.** One at a time, into the app's data folder, from one fixed revision, data files only, each verified against the hash Hugging Face lists, into a partial area that becomes a usable model only when complete. Excluded from Time Machine like the transcription models. [inferred]
- **Test run.** A short generation from a fixed synthetic prompt through the helper, under the same gate and memory guard as a protocol job. [paraphrase]
- **Chosen model.** The existing chosen-folder setting; a downloaded model is chosen by pointing it at the model's folder, so the protocol path does not change. "Choose…" for a folder picked by hand stays. [inferred]
- **Comparison.** An additional report written with the local model carries the model's short name and quantization in its report name. [paraphrase]

## API Contracts

<!-- Source: 0% user / 0% [paraphrase] / 100% [inferred] -->

- **Helper, supported types.** A new helper subcommand prints one JSON line `{"modelTypes": ["llama", "qwen3", "qwen3_5", ...]}` (the registry of the pinned MLX library, sorted) and exits 0; it loads no weights and needs no GPU. The app treats a failed or malformed answer as "list unavailable" (R1), never as an empty supported set. [inferred]
- **Leaderboard data used.** Per entry: model name, license, rank, rating, vote count, category and publish date, from the latest split. Entries whose license is "Proprietary" are ignored. The shown rank is the leaderboard's own rank number in that category. [inferred]
- **Report name.** `<template report name> · <model short name> <bits>-bit`, where the short name is the repository name without the organisation and without a trailing quantization suffix, cleaned of characters that are invalid in file names. [inferred]

## Edge Cases & Constraints

- **No model fits** (for example a Mac with 16 GB): the list says so and still shows the tight ones. [inferred]
- **Hugging Face unreachable or rate-limited:** downloaded models stay listed and usable; the last fetched list may be shown with its date. [inferred]
- **Leaderboard renames or ambiguous names:** a model is shown unranked rather than with a wrong rank. [paraphrase]
- **A recording starts during a download:** the download pauses and continues when the recording has ended. During a test run: the test stops like a protocol job and the row offers Test Again. [inferred]
- **App quits, the Mac sleeps or the network drops mid-download:** the partial files stay and the download can be resumed, also after a restart. [paraphrase]
- **The repository changes during a download:** the pinned revision still completes. [paraphrase]
- **Disk fills during a download:** it stops, keeps the partial files resumable and says why. [inferred]
- **Delete while the model writes notes:** refused until the job ends. [paraphrase]
- **Gated models:** need the user's Hugging Face token (the one the transcription models use) and accepted terms on Hugging Face. [paraphrase]
- **Network:** the app contacts Hugging Face only when the list is opened or refreshed and for downloads; meeting content never leaves the Mac, and protocol generation stays offline. [inferred]
- **Units:** sizes in decimal GB as Finder counts them; thresholds computed in bytes. [inferred]
- **App Store build:** unchanged; the local model provider does not exist there. [paraphrase]

## Acceptance Criteria

- **R1:** With the Local model provider chosen, Settings → Output offers "Find Models…", which opens a model list for this Mac. The list header shows the Mac's memory and free disk space, and the list links to the MLX models on Hugging Face. Errors: Hugging Face unreachable, rate-limited or answering malformed data, or the helper's type list unavailable → the list says what failed and offers Try Again, while already downloaded models stay listed and usable; nothing crashes. [paraphrase]
- **R2:** The list offers MLX text-generation models from the mlx-community organisation whose model type the bundled helper supports, one row per base model, with each conversion of it as a choice that shows its download size. Errors: a repository without a readable configuration, without a model type, or with an unsupported type is left out; one without a recorded base model is its own row, unranked. [inferred]
- **R3:** Before any download, each conversion shows a fit estimate for this Mac: "Fits this Mac", "Tight: close other apps first" or "Too big for this Mac", computed from its weight size plus the memory guard's admission headroom against the Mac's physical memory (A3). Too-big conversions are hidden unless "Show models too big for this Mac" is on. Errors: a conversion whose size is unknown shows "Size unknown" and counts as too big. [paraphrase]
- **R4:** Rows are ordered by the base model's rank on the LMArena text leaderboard in the protocol language's category when LMArena has one, otherwise in its overall ranking; each ranked row shows its rank, the category and the leaderboard's date, and the list names LMArena as the source with a link and its CC BY 4.0 license. Only a plain conversion of a base model takes that base model's rank; fine-tunes and unmatched models are unranked and follow the ranked rows, by Hugging Face downloads; one list never mixes two categories' ranks. Errors: leaderboard unreachable or malformed → the last fetched ranking with its date, else the snapshot shipped with the app with its date, else no ranks and a note saying why. [paraphrase]
- **R5:** "Download" first shows a confirmation that names the model, its download size, the licenses of the conversion and of its base model, the memory it needs while writing, and that the files come from Hugging Face while meetings stay on this Mac; nothing is downloaded before the user confirms. Errors: free disk space below the download size plus the reserve (A7) → refused before starting, naming the space needed; a gated model without access → explains it and offers to open its page on Hugging Face; a set Hugging Face token is used, and a rejected token is reported as such. [paraphrase]
- **R6:** A running download shows its progress and time left in the row, and Cancel stops it and removes its partial files. An interrupted download (network loss, sleep, app quit) can be resumed from the bytes already on disk, also after a restart. A download pauses while a recording runs and continues after the recording ends. Files come from one fixed revision; only data files (weights, configuration, tokenizer, chat template) are fetched, each verified against the hash Hugging Face lists, and the model becomes usable only when every file is complete and verified. Errors: a hash mismatch → that file is fetched again once, then the download fails with a message and leaves no usable model; disk full mid-download → stops, keeps the partial files resumable, says why. [paraphrase]
- **R7:** After a download completes, the app checks the model and runs a short test generation through the helper, under the same recording gate and memory guard as a protocol job; the row then shows "Tested on this Mac" or why the test failed (not enough free memory now, no text produced, helper failed). When no model is chosen yet, the first model that passes is chosen. Errors: a test refused for memory leaves the model downloaded with "Not tested: needs more free memory" and Test Again; a test never starts while a recording runs or a protocol is being written. [paraphrase]
- **R8:** A downloaded model's row offers Use (choose it for meeting notes) and Delete; "Choose…" for a folder picked by hand keeps working. Delete asks first and frees the disk space; deleting the chosen model leaves no model chosen, which the existing "no local model" notice covers. Errors: Delete is refused while a protocol job or test uses that model; a failed delete reports why and keeps the model. [inferred]
- **R9:** After the first model passes its test, a popup shows once: the ranking is a general indicator; try two or three models on a past meeting with your own template ("Regenerate Notes…", each model's notes are saved side by side) and keep the one whose notes you like; new models come out often, so look at the list again from time to time. The list keeps a "How to choose a model" entry that shows the same advice again. No error surface beyond showing the popup once per user. [paraphrase]
- **R10:** Notes regenerated as an additional report while the provider is Local model carry the model's short name and quantization in the report name (for example "Standard · Qwen3.8-27B 4-bit"), so notes of different models on the same meeting and template sit side by side. Errors: the same model and template again → the existing taken-name rule applies; characters invalid in a file name are removed from the model name. [paraphrase]
- **R11:** The caption under the model folder no longer reads "Tested: …"; it names the model the project tested, with its download size and the memory it needs, and points to "Find Models…". No error surface beyond the text. [paraphrase]
- **R12:** The helper writes with the sampling settings a model ships in its generation configuration when it has one, and with today's defaults otherwise; thinking stays off where the model's chat template has a switch. Errors: an unreadable or invalid generation configuration → today's defaults, and the helper logs that it fell back. [inferred]

## Boundaries

- No XPC service and no App Store variant; both stay in #145. [paraphrase]
- No model picker inside the "Regenerate Notes…" sheet; the user switches the model in Settings. [inferred]
- No notice when a new or better-ranked model fits this Mac. [inferred]
- No models from organisations other than mlx-community, no GGUF models, no conversion inside the app. [inferred]
- The app makes no quality judgement of its own; the rank is LMArena's general one. [paraphrase]
- No change to the default protocol provider for new users (#103). [inferred]

## Decision Context

- **D1 · The model list first shows which models run on this Mac.** why: the user needs to know which models run on his computer before anything else · status: active [owner-stated 2026-11-16, paraphrased]
- **D2 · The list is ordered by the base model's leaderboard rank, as an indicator only; quality is judged by the user on his own meetings and templates.** why: the leaderboard does not reflect meeting notes, but it is a good indicator · status: active [owner-stated 2026-11-16, paraphrased]
- **D3 · A popup recommends testing several models and testing again from time to time.** why: good new models come out all the time · status: active [owner-stated 2026-11-16, paraphrased]
- **D4 · Models are downloaded inside the app, like the transcription models.** why: the owner asked for automatic downloads like those of the transcription models · status: active [owner-stated 2026-11-16, paraphrased]
- **A1 · The ranking source is the LMArena text leaderboard dataset on Hugging Face, in the protocol language's category, fetched when the list opens, with a last-good cache and a snapshot shipped with the app.** alternatives: B — Hugging Face eval results (exact ids, but 12 of 25 base models covered); C — Artificial Analysis (per-user key, redistribution limits); D — Open LLM Leaderboard (frozen 2025-03) · flip at: the ranking source behind the model list · test: a ranking test on a recorded LMArena excerpt that orders three base models and falls back to the snapshot · status: active [agent-inferred 2026-11-16; Codex cross-check agreed]
- **A2 · Only a plain conversion (quantization) of a base model takes that base model's rank; fine-tunes and ambiguous names stay unranked.** alternatives: B — every derived model inherits its ancestor's rank · flip at: the rank matching of the model list · test: a matching test where a 4-bit conversion is ranked and an abliterated fine-tune of the same base is not · status: active [agent-inferred 2026-11-16; Codex cross-check proposed it]
- **A3 · Fit labels use the weight size plus the memory guard's 6 GiB admission headroom: "Fits" up to 40 % of physical memory, "Tight" up to 75 %, "Too big" above.** alternatives: B — percentages of memory for the weights alone; C — only "can start now" from the current free memory · flip at: the fit estimate's two thresholds · test: a fit test at 16, 32 and 64 GB with the 16.1 GB and 19.4 GB Qwen conversions (on a 64 GB Mac the 4-bit model fits and the 5-bit one, which raised a memory warning in daytime use, is tight) · status: active [agent-inferred 2026-11-16]
- **A4 · The list reads only the mlx-community organisation.** alternatives: B — any repository tagged MLX · flip at: the catalog query · test: a catalog test that drops a non-mlx-community repository · status: active [agent-inferred 2026-11-16]
- **A5 · A short test generation after the download marks a model "Tested on this Mac".** alternatives: B — metadata check only · flip at: the post-download step · test: a test with a stand-in helper that passes, fails and is refused for memory · status: active [agent-inferred 2026-11-16; Codex cross-check proposed it]
- **A6 · Notes of different models sit side by side through the report name; a model picker in the regenerate sheet is left for later.** alternatives: B — model picker in the sheet now · flip at: the report-name rule for local-model reports · test: two regenerations of one meeting and template with two models give two reports · status: active [agent-inferred 2026-11-16]
- **A7 · A download needs its own size plus a 10 GB reserve free, so recordings keep room.** alternatives: B — no reserve; C — a percentage of the disk · flip at: the download's disk check · test: a disk-check test just below and above the limit · status: active [agent-inferred 2026-11-16]
- **A8 · One download at a time, paused while a recording runs.** alternatives: B — parallel downloads; C — keep downloading during recordings · flip at: the download queue · test: a download test where a recording starts and ends mid-download · status: active [agent-inferred 2026-11-16]
- **A9 · Downloads fetch only data files of one pinned revision and verify each against Hugging Face's hash.** alternatives: B — whole repository snapshot without verification · flip at: the downloader's file filter · test: a downloader test that skips a code file and rejects a file with a wrong hash · status: active [agent-inferred 2026-11-16; Codex cross-check proposed it]
- **A10 · The helper uses a model's own generation configuration for sampling when it ships one.** alternatives: B — keep the Qwen-tuned defaults for every model · flip at: the helper's generation settings · test: a helper test that reads a model folder's generation configuration and one without it · status: active [agent-inferred 2026-11-16]
- Rejected bigger design: rank by a mix of benchmarks from Hugging Face eval results; the benchmarks are not comparable and cover too few models.
- Related: #145 (XPC service and App Store variant), #159 (the model check accepts folders that cannot load; the test run in R7 catches those in practice), #160 and #162 (provider seam and helper contract), #9 (the transcription models' Hugging Face browser, whose catalog and token handling this reuses), #103 (default provider for other users).
- Mockup gate: the new screens (model list, download confirmation and progress, testing advice popup) are drawn on the project's private design canvas; acceptance pending.

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
| R11 | TBD - populate via /flow-next:plan |
| R12 | TBD - populate via /flow-next:plan |
