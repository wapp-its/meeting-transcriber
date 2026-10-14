# Local model for protocols in the Homebrew build (pilot)

## Conversation Evidence

> issue #138 (Background, translated): "The test in #112 shows: Qwen3.8-27B in 4-bit writes usable protocols without thinking in about 3 min. Via LM Studio that is cumbersome and error-prone. LM Studio ignores the switch for thinking and the configured context length. [...] You also have to install, start and set up a second app. The app could load the model itself from Hugging Face like the transcription models and run it with `mlx-swift-lm`."
> issue #138 (Notes, translated): "The model runs in its own helper process of the app (XPC service), not in the app process. So a crash or memory problem of the model does not end a running recording." · "Only run when nothing is being recorded, and unload the model right after. Limit context and output." · "27B in 4-bit needs about 20 GB and so fits on 64-GB Macs. 32-GB Macs need a smaller model, tested separately." · "The transcription engines (`TranscribingEngine`) have no way to unload their models today. That is needed." · "The OpenAI-compatible provider stays for servers, for example a university server."
> issue #138 (spike result, translated): "Qwen3.8-27B (4-bit) runs via `mlx-swift-lm` in its own process, without LM Studio. Thinking-off, context limit and cancellation work. The quality is in the range of the LM Studio runs from #112." · "Open for the app: MLX needs compiled Metal shaders. For that, Xcode's Metal Toolchain must be installed."
> owner 2026-10-14, decision on #138 scope: "A — Small pilot first (Recommended)" (paraphrased option text: Homebrew build only; the model runs in a helper program the app starts per protocol and that quits afterwards; a "Local model" choice in Settings → Output; the model folder is picked by hand; helper service, in-app download and the App Store version follow later)
> owner 2026-10-14, mockup review: "Mockup OK" (three screens: Settings → Output with a model ready, Settings → Output with no model yet, and three notifications)
> owner 2026-10-14, build route: "A — Install it (Recommended)" (Xcode's Metal Toolchain on every build machine, instead of shipping a prebuilt shader file)
> cross-check 2026-10-14 (Codex), paraphrased: the first slice needs a free-memory check before start and an independent watchdog that terminates the helper, since MLX's own memory limit stops nothing; stop the helper when a recording starts and run the protocol again afterwards; an explicit bound on prompt plus output, because the cache size limit drops old context instead of rejecting long input; cancellation with termination escalation, cleanup when the app dies, and progress and total deadlines; label truncated output as incomplete; sign the helper with Hardened Runtime before the outer bundle and test a notarized build; download, XPC, App Store support and keeping the model loaded between jobs can wait.

## Goal & Context

<!-- Source: 60% user / 25% [paraphrase] / 15% [inferred] -->

Protocols are written today by a cloud CLI (Claude, Codex) or by an OpenAI-compatible server. A local server such as LM Studio keeps meeting content on the Mac, but it is a second app to install, start and set up, and it ignores the switch for thinking and the configured context length. A model that thinks first runs for 15+ minutes and runs into the app's output limit.

This spec lets the app write the protocol itself with a local MLX model, so meeting content never leaves the Mac and no second app is needed. It is the pilot the owner chose: the Homebrew build only, a model folder the user picks by hand, and one helper process per protocol job. The helper service, the download inside the app and the App Store variant follow in #145.

A one-day spike measured the path end to end on a synthetic 76-minute German meeting with `mlx-community/Qwen3.8-27B-4bit` (16 GB on disk): about 4 s to load, 52 s to read the transcript, 152 s to write (12.8 tokens/s), about 17 GiB peak, no thinking text in the output. Cancelling stopped the model within about 2 s. After unloading inside the process, 1–2 GB stayed in use until the process ended, which is why the helper ends after each job. The quality was in the range of the same model through LM Studio. Real meetings are not tested yet; the owner checks them after the build.

The user keeps working on the Mac while a protocol is written, and recordings must never be put at risk by the model.

## Architecture & Data Models

<!-- Source: 30% user / 40% [paraphrase] / 30% [inferred] -->

- **Provider.** A new `ProtocolProvider` case for the local model, labelled "Local model (on this Mac)", present only in the non-App-Store build like the CLI providers. Every switch over `ProtocolProvider` handles it (the generator factory and the settings view).
- **Settings state.** The chosen model folder, stored as a security-scoped bookmark plus a display path, the same pattern as the custom WhisperKit model folder. No other new setting: thinking is always off, and the memory limits are fixed constants in the pilot. [inferred]
- **Helper executable.** A second executable target in the app's package that depends on `mlx-swift-lm` (`MLXLLM`, `MLXLMCommon`, pinned to an exact release). Only the helper links MLX; the app target does not. [paraphrase]
- **Generator.** A `ProtocolGenerating` implementation in the app builds the prompt the same way as the other providers (same prompt, protocol language and meeting metadata), starts one helper per job, collects its output and maps its exit status to a typed outcome. [paraphrase]
- **Pipeline outcomes.** Today a generator returns text or throws, and every throw becomes the generic failure warning; the existing retry only accepts failed jobs and reruns everything. The protocol stage therefore changes so it can tell the local generator's outcomes apart and act on each as R11 lists: written, written but incomplete, deferred for a recording, low memory, no model, prompt too long, failure. Other providers keep today's behaviour. A new protocol-only retry reruns just the protocol stage of a finished job from its saved transcript. [inferred]
- **One gate for every local generation.** Protocols are not only written by the pipeline's queue: confirming or skipping speaker naming, and its cleanup of stale namings, start generation in their own tasks. Every path that runs the local model goes through one app-wide gate that admits one helper at a time, from the memory check until the helper's exit is confirmed, and records which job owns the running helper. Cancelling a job terminates the helper only when that job owns it. [inferred]
- **Guard (app side, independent of the helper).** A free-memory check before the helper starts, and a watchdog while it runs that reads the system's memory pressure and available memory and terminates the helper. It also terminates the helper when a recording starts and keeps a local protocol job from starting while a recording runs. Recording start is observed through the existing watch-loop state change. [paraphrase]
- **Shaders.** SwiftPM compiles MLX's Metal shaders when Xcode's Metal Toolchain is installed; the build produces MLX's shader resource bundle beside the helper binary, and the helper finds it there (verified in the spike with a plain `swift build -c release`). Both build scripts copy the helper and that bundle into the app and sign them. [paraphrase]

## API Contracts

<!-- Source: 20% [paraphrase] / 80% [inferred] -->

**App ↔ helper** (process boundary; nothing else is shared):

- **Input:** the model folder, the system prompt and the user prompt (passed through standard input or files in a private run directory, never as command-line text), the context limit and the output limit. [inferred]
- **Output:** the protocol text, written progressively so a terminated helper leaves what it had written. [inferred]
- **Exit status distinguishes:** success · model folder not usable · prompt exceeds the context limit · output stopped at the output limit (text kept) · terminated on request · failure. The app turns each into one outcome in R2–R8. [inferred]
- **Termination:** SIGTERM makes the helper stop at the next step (between prompt chunks or tokens) and exit; the app escalates to SIGKILL after a grace period. The helper also exits on its own when the app is gone, so a helper never outlives the app. [paraphrase]
- **Thinking:** the chat template is rendered with thinking switched off; the helper never emits a thinking block into the protocol. [paraphrase]
- **Progress events:** on a channel separate from the protocol text, the helper reports content-free progress: loading, reading the prompt (chunk n of N), writing (tokens so far). Each event resets the no-progress deadline; loading and prompt reading count as progress. [paraphrase]
- **Diagnostics:** the app logs content-free lifecycle lines for every helper: started (job, model name, prompt token count), phase changes, and the exit reason (written, incomplete, deferred for a recording, low memory with the readings that triggered it, cancelled, deadline, crashed with its signal). Never transcript or protocol text. [paraphrase]

**Check Model** (Settings): validates a folder without loading model weights: model configuration, tokenizer and chat template present and readable, weight files present, model type supported by the pinned `mlx-swift-lm`. Returns the model's name, quantisation and size for the status line, or what is missing. The spike's tokenizer-only mode did this in under 250 MB. [inferred]

## Edge Cases & Constraints

- **Recording starts mid-run:** the helper is terminated and the job waits; the protocol runs again from the saved transcript after the recording ends. [paraphrase]
- **Not enough memory at start, or memory runs low during the run:** the helper does not start or is terminated; the transcript is kept. [paraphrase]
- **Prompt too long for the context limit:** refused before any weights load. Output that hits the output limit is kept and marked incomplete. [paraphrase]
- **Model folder missing, moved, on an unmounted volume, or its bookmark no longer resolves:** treated as no model. [inferred]
- **App quits or crashes during a run:** the helper exits too; on the next launch the existing restore policy resumes the protocol stage from the saved transcript. [inferred]
- **Two protocols due at once** (for example two speaker namings confirmed back to back, or a naming confirmed while the queue writes another protocol): the second waits at the gate until the first helper has exited; never two helpers. [paraphrase]
- **Stuck helper:** a total deadline and a no-progress deadline end it and report a failure. [paraphrase]
- **The existing subprocess runner does not react to task cancellation, and the queue's cancel only reaches the task it is running:** cancelling any job whose generation owns the helper, including one started from speaker naming, must terminate that helper and leave every other job untouched. [paraphrase]
- **Memory budget:** about 17 GiB peak for the tested 27B 4-bit model at a 32k context; the pilot targets Macs with 64 GB. [paraphrase]
- **App Store build:** compiles and behaves exactly as today; the provider does not exist there. [paraphrase]

**Verification sequence** [paraphrase]:

1. App-side tests with a stand-in helper executable that plays each exit status and progress pattern: outcome handling per R11, the gate across queue and speaker-naming paths, job-specific cancellation, recording preemption, deadlines, guard decisions with injected memory readings, notification mapping.
2. Tests of the real helper that load no weights and run in CI: Check Model on good and broken folders, refusal of a too-long prompt before weights load, the rendered prompt ends with thinking switched off, exit on SIGTERM, exit when its parent process dies.
3. A real-model run on a developer Mac (not CI, with the memory guard): one protocol from the synthetic test transcript with the helper's network access blocked, no thinking block in the output; a recording started through the automation API during generation ends the helper within 5 seconds.
4. A notarized release build writes one protocol end to end (R9).

## Acceptance Criteria

- **R1:** In the Homebrew build, Settings → Output offers "Local model (on this Mac)" as LLM provider, with a model-folder row (path and Choose…), a status line and a Check Model button, as on the accepted mockup screens 1 and 2; the App Store build offers no such provider. Errors: no folder chosen → the warning "No model chosen. Protocols are not written until one is set." and Check Model disabled; a folder that is not a usable MLX model → the status line names what is missing or unsupported; Check Model never loads model weights. [paraphrase]
- **R2:** With a usable model folder, the protocol of a finished recording or import is written by the local model with the same prompt, protocol language and output handling as the other providers (full transcript appended and raw transcript kept per the existing settings), contains no thinking text, and makes no network request. Errors: the outcomes in R4–R8; any other helper failure keeps the transcript and records the existing "Protocol generation failed — transcript saved" warning. [paraphrase]
- **R3:** The model runs only in a helper process the app starts for one protocol job; the helper exits when the job ends (written, failed, terminated), so the app process holds no model memory before, during or after; a helper crash ends only that job, while the app and any recording keep running and the transcript is kept. [paraphrase]
- **R4:** Before starting the helper, the app checks memory and starts only when memory pressure is normal and available memory covers the model's weight size plus a fixed headroom; while the helper runs, a watchdog terminates it when memory pressure reaches warning level or available memory falls below a fixed floor. Either way the transcript is kept and the notification "Protocol not written: low memory" offers Try Again (runs only the protocol stage again) and Show Transcript. [paraphrase]
- **R5:** A local protocol job does not start while a recording runs; when a recording starts while the helper runs, the helper is terminated within 5 seconds, the notification "Protocol paused for your recording" appears, and the protocol runs again by itself after the recording ends. A recording never waits for the model. [paraphrase]
- **R6:** Cancelling the job or quitting the app terminates the helper (terminate, then kill after a grace period); no helper process outlives the app. [paraphrase]
- **R7:** Prompt plus output stay within the context limit: a transcript too long for it is refused before any weights load (transcript kept, failure warning); output that reaches the output limit is saved and marked incomplete in the job's warnings; a total deadline and a no-progress deadline end a stuck helper as a failure. [paraphrase]
- **R8:** When a protocol is due and no model folder is chosen or it cannot be reached, the notification "Protocol not written: no local model" offers Open Settings, and the transcript is kept. [paraphrase]
- **R9:** Both build scripts (release and the dev run script) build the helper with plain `swift build`, place it and MLX's shader resources in the app so the helper finds them at runtime, and sign it; the release path signs the helper with Hardened Runtime and a timestamp before the outer bundle, and a notarized build writes one protocol end to end. Errors: a build machine without the Metal Toolchain fails with a message naming the install command. [paraphrase]
- **R10:** Every path that writes a protocol with the local model (the pipeline queue, confirming or skipping speaker naming, and the cleanup of stale namings) goes through one gate: at most one helper runs at any moment, a second request waits until the first helper's exit is confirmed, and cancelling a job terminates the helper only when that job owns it, leaving every other job and its helper untouched. Errors: no error surface beyond R4–R7. [paraphrase]
- **R11:** The protocol stage handles each local outcome as follows, for jobs from the queue and from speaker naming alike: written → job finishes as today; written but stopped at the output limit → protocol saved, job finishes with the warning that it is incomplete; deferred for a recording → job does not finish, waits, and reruns only the protocol stage from its saved transcript once no recording runs, also after an app restart; low memory → job finishes with the transcript and a warning, and Try Again reruns only its protocol stage from the saved transcript; no model → job finishes with the transcript and a warning; prompt too long, deadline or any other failure → job finishes with the transcript and the existing failure warning. Other providers behave exactly as today. [inferred]
- **R12:** The helper reports content-free progress (loading, prompt chunk n of N, tokens written) that resets the no-progress deadline, and the app logs content-free lifecycle lines per helper (started, phase, exit reason with the memory readings for a low-memory exit); no log line contains transcript or protocol text. [paraphrase]

## Boundaries

- No download inside the app: the user picks an existing model folder; the screens name the tested model. Follows in #145. [paraphrase]
- No XPC service and no App Store variant of this provider. Follows in #145. [paraphrase]
- No smaller model for Macs with less memory; tested separately (#145). [paraphrase]
- No unloading of the transcription engines' models (#138 notes it as needed); separate follow-up. [inferred]
- No setting for thinking, memory limits, context or output length; no model kept loaded between jobs; no live preview of the protocol while it is written. [paraphrase]
- The OpenAI-compatible provider and the CLI providers stay unchanged. [paraphrase]

## Decision Context

### Motivation

Meeting content should not leave the Mac, and the user should not need a second app. The owner picked the smallest slice that reaches real meetings soonest; the helper service, in-app download and App Store variant are built only after real use shows they are needed. Success measure: on the owner's real meetings, protocols comparable to the same model through LM Studio (#112), written while the Mac stays usable and without a recording ever being disturbed. The owner checks that after the build; it is a human check, not an acceptance criterion here. [paraphrase]

- **D1 · Pilot first: Homebrew build only, one helper process per protocol job, model folder picked by hand; helper service, in-app download and App Store variant later (#145).** why: fastest path to real meetings, and nothing in the pilot is thrown away when those come · alternatives: full design at once (helper service, download, both variants); drop the feature · status: active [owner-ratified 2026-10-14]
- **D2 · MLX's shaders are compiled by SwiftPM with Xcode's Metal Toolchain installed on every build machine, not shipped as a prebuilt shader file.** why: a prebuilt file does not stop SwiftPM compiling the shaders and needs a new matching file for every MLX update · status: active [owner-ratified 2026-10-14]
- **D3 · The screens are the accepted mockup: provider entry, model-folder row with Choose…, status line with Check Model, and the three notifications (paused for a recording, low memory, no local model); no thinking toggle, no memory setting, no download button.** why: the owner accepted these three screens · status: active [owner-ratified 2026-10-14]
- **D4 · The model runs in a separate process that exits after every job, never in the app process.** why: a crash or memory spike of the model must not end a recording, and unloading inside a process left 1–2 GB in use · status: active [owner-stated 2026-10-14]
- **A1 · Memory guard constants: start only at normal pressure with available memory at least the weight size plus 6 GB; terminate at warning pressure or when available memory falls below 10 % of physical memory.** flip at: the guard's constants · test: guard unit tests with injected memory readings · status: active [agent-assumed 2026-10-14]
- **A2 · Context limit 32,768 tokens, output limit 16,000 tokens, total deadline 20 minutes, no-progress deadline 3 minutes.** flip at: the generator's constants · test: helper-contract tests with a fake helper · status: active [agent-assumed 2026-10-14]
- **A3 · The free-memory refusal at start and the watchdog termination share the one "low memory" notification.** flip at: the notification mapping · test: notification mapping unit test · status: active [agent-assumed 2026-10-14]
- **A4 · The helper is a second executable target in the app's package, and only it links MLX.** flip at: the package manifest · test: the app binary links no MLX library · status: active [agent-inferred 2026-10-14]
- **D5 · The local route is the app itself, not LM Studio.** why: LM Studio ignores the thinking switch and the context length, and it is a second app to install and run · alternatives: test a real meeting through LM Studio first · status: active [owner-ratified 2026-10-14]

## Requirement coverage

- R1 → fn-N.M (TBD - populate via /flow-next:plan)
- R2 → fn-N.M (TBD - populate via /flow-next:plan)
- R3 → fn-N.M (TBD - populate via /flow-next:plan)
- R4 → fn-N.M (TBD - populate via /flow-next:plan)
- R5 → fn-N.M (TBD - populate via /flow-next:plan)
- R6 → fn-N.M (TBD - populate via /flow-next:plan)
- R7 → fn-N.M (TBD - populate via /flow-next:plan)
- R8 → fn-N.M (TBD - populate via /flow-next:plan)
- R9 → fn-N.M (TBD - populate via /flow-next:plan)
- R10 → fn-N.M (TBD - populate via /flow-next:plan)
- R11 → fn-N.M (TBD - populate via /flow-next:plan)
- R12 → fn-N.M (TBD - populate via /flow-next:plan)
