---
satisfies: [R2, R3, R7, R12]
---
# gh-138-local-model-for-protocols-in-the.1 Helper package: run the model per the helper contract

## Description
The early proof point: a standalone SwiftPM package with one executable that runs the local model exactly as the spec's API Contracts describe (input, progressive output, exit statuses, progress events, termination, thinking off, limits) plus a Check Model mode that loads no weights. Split off first because everything else talks to it only through the process boundary, and because it proves the MLX build route (plain `swift build` with the Metal Toolchain) before the app is touched.

**Size:** M
**Files:** `tools/local-llm-helper/Package.swift`, `tools/local-llm-helper/Sources/LocalLLMHelper/*.swift` (new), `tools/local-llm-helper/Tests/LocalLLMHelperTests/*.swift` (new), `tools/local-llm-helper/README.md` (new)
**Touches:** [tools/local-llm-helper/**]

### Approach
- Package layout and tools-version like `tools/mt-cli/Package.swift`; macOS 14, Swift 6 language mode. Dependencies pinned `exact:`: `mlx-swift-lm` 3.32.3 (products `MLXLLM`, `MLXLMCommon`) and the `mlx-swift` / `swift-transformers` versions it resolves to; commit `Package.resolved`.
- Three modes: `run` (request on stdin: model folder, system prompt, user prompt, context limit, output limit, output file path in a private run directory), `check <folder>` (no weights), `selftest` (a few-MB GPU op that proves the Metal shaders load from the bundle).
- `run`: tokenize with the model's chat template and `additionalContext: ["enable_thinking": false]`; refuse before loading weights when prompt tokens plus the output limit exceed the context limit; then load, set `GenerateParameters.maxKVSize` to the context limit and `maxTokens` to the output limit, set `Memory.cacheLimit` small, stream tokens to the output file with a sync per progress step.
- Exit statuses: one distinct code per spec outcome (written, incomplete at output limit, model folder not usable, prompt too long, terminated on request, failure). Put the numbers in one place in the helper and document them in the package README; the app mirrors them in task 3.
- Progress events and lifecycle lines on stderr, content-free: `progress phase=loading`, `progress phase=prefill chunk=<n> total=<N>`, `progress phase=writing tokens=<n>`; never prompt or protocol text.
- SIGTERM: a signal source sets a cancellation flag checked between prefill chunks and tokens; exit with the terminated code after flushing what was written. Parent death: exit when the parent process is gone (watch the parent pid with a kqueue `NOTE_EXIT` source, and treat stdin EOF before the request is read as parent death).
- `check`: verify config, tokenizer, chat template and weight files exist and parse, and that the model type is supported by the pinned `mlx-swift-lm`; print name, quantisation and on-disk size as one JSON line; never open the weight files beyond their presence.

### Investigation targets
**Required:**
- `tools/mt-cli/Package.swift` — a sibling tool package to mirror
- `scripts/lib/localvqe-resources.sh` — how an external runtime artifact is pinned and documented in this repo

**Optional:**
- `app/MeetingTranscriber/Sources/CLIProcessRunner.swift:149-160` — the caller side's termination expectations (SIGTERM then SIGKILL after a grace)

### Key context
- `mlx-swift-lm` 3.32.3 API used by the spike that proved this path: `applyChatTemplate(messages:tools:additionalContext:)`, `GenerateParameters.maxKVSize`, `Memory.cacheLimit`, `Memory.clearCache()`, `generateTokensTask`; Qwen3.8 non-thinking sampling defaults come from the model's `generation_config.json` (temperature 0.7, top_p 0.8, top_k 20).
- With Xcode's Metal Toolchain installed, plain `swift build -c release` compiles MLX's shaders into `mlx-swift_Cmlx.bundle` next to the binary, and the binary finds it there. Without the component the build fails with "missing Metal Toolchain"; detect it with `xcodebuild -showComponent MetalToolchain` (Status: installed), not `xcrun --find metal`, which exists either way.
- Tokenizer-only loading (for `check` and the too-long refusal) stayed under 250 MB in the spike; loading weights takes ~16 GB for the tested model, so no test in this package may load weights unless a model folder is given through an environment variable.
- `maxKVSize` alone rotates old context instead of refusing long input, which is why the refusal is explicit.
## Acceptance
- [ ] `cd tools/local-llm-helper && swift build -c release` builds with the Metal Toolchain installed, and the built `selftest` passes from the build directory.
- [ ] `swift test` in the package passes without a model folder: `check` reports each missing or broken file on fixture folders; exit codes and stderr progress format are covered; SIGTERM and parent death end the process with the terminated code (process-level tests).
- [ ] With a model folder in the test environment variable, tests show: the rendered prompt ends with the empty thinking block, a too-long prompt is refused before weights load (peak resident memory stays under 1 GB), and `check` returns name, quantisation and size.
- [ ] No stderr or log line contains prompt or protocol text (test asserts on a marker string in the prompt).
- [ ] The app's package and its build are unchanged by this task.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
