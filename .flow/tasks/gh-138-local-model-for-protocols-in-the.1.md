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
The new Swift package `tools/local-llm-helper` builds the `local-llm-helper` executable. Its `run` mode takes one JSON request on stdin, refuses a prompt that leaves no room for the requested output before any weight loads, and streams the protocol into an owner-only file. It reports progress and its end on stderr in typed lines that carry no prompt text. `check <folder>` validates a model folder without loading weights, and `selftest` proves the Metal shaders compute on the GPU. The app's package and build are unchanged (`git diff` of `app/` against the base is empty).

baseline: none (tools/local-llm-helper did not exist before this task, so no Quick command could run pre-edit)

stage: impl-review - skipped(policy: parallel-wave - conductor owns the gate)

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

### Acceptance

| AC | Evidence |
|---|---|
| 1 release build and built `selftest` | `swift build -c release` rc=0, `.build/release/local-llm-helper selftest` rc=0 (6 checks, `SELFTEST OK`); `ProcessContractTests.testReleaseBuildSelfTestPasses` runs it from the build dir |
| 2 `swift test` without a model folder | rc=0, 21 tests, 3 skipped (the model-folder tests), 0 failures. `ModelFolderCheckTests` names each missing or broken file on the fixture. `StderrLineTests` pins the line formats and the README exit table. `ProcessContractTests` spawns the real binary for every refusal, SIGTERM and parent death (exit 13) |
| 3 with `LOCAL_LLM_HELPER_TEST_MODEL` | `RealModelTests` 3/3 passed against a tokenizer-only copy of a Qwen3.8-27B-4bit folder with placeholder weights. The rendered prompt ends with the empty thinking block. A 7512-token prompt against context 2048 exits 12 before the loading line, peak RSS about 245 MB (limit 1 GB). `check` returns name, `bits 4 groupSize 64` and a size. No weights were loaded in this task; generation with real weights is unverified |
| 4 no prompt text on stderr | `ProcessContractTests` sends a marker in every prompt and asserts it is absent from stderr and stdout; `RealModelTests` does the same for the refusal. `StderrLine` has no case that takes a free-form string |
| 5 app package unchanged | only `tools/local-llm-helper/**` is in the commit |

### Decisions

- Rule 6: exit statuses 0 `written`, 10 `incomplete` (output limit reached), 11 `model-unusable`, 12 `prompt-too-long`, 13 `terminated`, 1 `failure` (usage, bad request, template, output file, load, generation). The README table is pinned by `StderrLineTests.testReadmeDocumentsEveryExitStatus`.
- Rule 6: the request is one JSON object on stdin with `modelFolder`, `systemPrompt`, `userPrompt`, `contextLimit`, `outputLimit`, `outputPath`. Limits must be above 0 and paths absolute, else exit 1 `error=bad-request`. Stdin that ends before any byte means the parent is gone, so the helper exits 13 `cause=stdin-closed`.
- Rule 6: stderr lines are `progress phase=loading`, `progress phase=prefill chunk=n total=N`, `progress phase=writing tokens=n`, `lifecycle event=started`, `lifecycle event=prompt tokens=n context=c output=o`, and `lifecycle event=exit status=s reason=r` with an optional `cause=`, `error=` or `problems=`.
- Rule 6: `check` prints one JSON line on stdout (`modelType`, `name`, `problems[{file, problem}]` with problem `missing|unreadable|invalid|unsupported`, `quantization{bits, groupSize}`, `sizeBytes`, `usable`) and exits 0 when usable, 11 when not.
- Rule 6: the env var for the model-folder tests is `LOCAL_LLM_HELPER_TEST_MODEL`, documented in the README.
- Rule 6: the test fixture is built at test time in a temp dir (a small BPE `tokenizer.json`, a Qwen-like `chat_template.jinja`, a two-shard index with placeholder shards). No binary fixtures are committed.
- Rule 5: sampling is fixed at temperature 0.7, top_p 0.8, top_k 20 in `GenerationDefaults`, and is not read from the model's `generation_config.json`. The tested model's file carries the thinking-mode values (1.0 / 0.95 / 20), so reading it would change the sampling the trial protocols were judged with. The task's key context attributes these values to that file, which is wrong for the tested model. Switch point: `GenerationDefaults` in `Sources/LocalLLMHelper/Generation.swift`. Pinning test: `GenerationDefaultsTests.testParametersCarryTheFixedSamplingAndTheRequestLimits`.
- Rule 6: MLX's buffer cache is capped at 512 MiB, because the process ends after one protocol.
- Rule 6: the output is synced and a writing line is written every 32 tokens and once at the end.
- Rule 6: prefill uses mlx-swift-lm's default step of 512 tokens, and the progress counts the final forward as the last chunk.
- Rule 6: before generation starts, SIGTERM and parent death end the process at once with `_exit(13)`. During generation they cancel the task cooperatively (between prefill chunks and in the token loop), the output is synced, and the process exits 13. A SIGTERM that arrives after generation finished keeps the real status.
- Rule 6: the parent watch is a kqueue process source on `getppid()` plus a re-check, and a parent pid of 1 at start counts as gone.
- Rule 6: the tokenizer comes from swift-transformers through an own bridge, instead of mlx-swift-lm's `MLXHuggingFace` product, which also brings a Hugging Face downloader. The helper cannot reach the network.
- Rule 6: the output file opens with `O_NOFOLLOW`, mode 0600, truncating, so a symlink in its place is refused.
- Rule 6: every exit goes through `_exit`, so no atexit handler or C++ static destructor runs while MLX may have GPU work in flight.

### Gates

- `cd tools/local-llm-helper && swift build -c release` rc=0
- `.build/release/local-llm-helper selftest` rc=0
- `CFFIXED_USER_HOME="$(mktemp -d)" swift test` rc=0, 21 tests, 3 skipped, 0 failures
- `LOCAL_LLM_HELPER_TEST_MODEL=<tokenizer-only copy> swift test --filter RealModelTests` rc=0, 3 passed
- SwiftFormat 0.63.0 `--dryrun --lint` on the package with the repo `.swiftformat` rc=0 (0 of 22 files)
- SwiftLint 0.65.1 `--strict` with the repo `.swiftlint.yml` rules, `included` narrowed to the package, rc=0 (0 violations in 21 files)
- `flowctl gate classify` reports FULL (Package.resolved unmatched), so the gates above ran instead of a docs-only skip

### Follow-ups

- `scripts/lint.sh` and `.swiftlint.yml` list their paths explicitly and do not include this package, so `./scripts/lint.sh` passes without reading it. `ci.yml` builds and tests `tools/mt-cli` and `tools/audiotap`, not this package. Both edits are outside this task's Touches. CI also needs a runner with the Metal Toolchain.
- A debug build fails `selftest`: the bf16 4-bit quantized matmul ends in a Metal GPU timeout and returns wrong numbers. The build scripts in task .2 must build the helper with `-c release` and copy `mlx-swift_Cmlx.bundle` from `.build/release/`.
- Swift 6.4 puts products under `.build/out/Products/<Config>/`, with `.build/release` and `.build/debug` as links to them.
- swift-transformers stops the process with `fatalError` on a BPE `tokenizer.json` whose `merges` key is missing, so `check` crashes on such a folder instead of reporting it.
- `NaiveStreamingDetokenizer` can drop an incomplete UTF-8 piece at the very end of the stream.

stage: impl-review - ran [19:00:23Z..19:09:13Z] (model: codex gpt-6-astra xhigh, three draws: correctness, contracts, integration) - SHIP; five P2 findings kept as follow-ups (empty chat template passes check; outputLimit near Int.max overflows the context comparison; config.json without the architecture fields passes check; a tokenizer.json without merges traps inside swift-transformers so check crashes instead of reporting; a stale shard index rejects a folder whose consolidated model.safetensors the pinned loader would use)
stage: wave-join - ran (fast-forward be1fe60d onto the spec branch; evidence SHA unchanged)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: be1fe60d99ee9c4e1081d6717c60b5a4bc05e022
- Tests: cd tools/local-llm-helper && swift build -c release (rc=0; lane worktree at be1fe60d and the conductor's integrated verify), cd tools/local-llm-helper && .build/release/local-llm-helper selftest (rc=0, SELFTEST OK), cd tools/local-llm-helper && CFFIXED_USER_HOME="$(mktemp -d)" swift test (rc=0; 21 tests, 3 skipped for want of a model folder, 0 failures; log /tmp/gh138-helper-tests.log), cd tools/local-llm-helper && LOCAL_LLM_HELPER_TEST_MODEL=<tokenizer-only copy, placeholder weights> swift test --filter RealModelTests (rc=0; 3 passed; worker run), cd app/MeetingTranscriber && swift build (rc=0, integrated verify), cd app/MeetingTranscriber && swift build -Xswiftc -DAPPSTORE (rc=0, integrated verify), cd app/MeetingTranscriber && CFFIXED_USER_HOME="$(mktemp -d)" swift test --parallel --filter 'ProtocolGenerator|PipelineQueue|NotificationManager|OutputSettings' (rc=0; 491 test cases; integrated verify), swiftformat 0.63.0 --dryrun --lint tools/local-llm-helper (rc=0; 0/22 files; worker run), swiftlint 0.65.1 lint --strict, repo rules, included narrowed to tools/local-llm-helper (rc=0; 0 violations in 21 files; worker run)
- PRs: