# local-llm-helper

The program the app starts to write one protocol with a local MLX model. It runs
in its own process and exits after every job, so the model's memory (about 17 GB
for a 27B 4-bit model) and any crash stay out of the app and away from a running
recording. The app talks to it only through the process boundary described
below; the two share no code.

It is its own SwiftPM package, not a target of the app's package, so the app's
package never depends on MLX: the App Store build, the app's tests and the app's
CI never compile MLX or need the Metal Toolchain.

## Build

Needs Xcode's Metal Toolchain, which compiles MLX's shaders:

```bash
xcodebuild -showComponent MetalToolchain     # must say "Status: installed"
xcodebuild -downloadComponent MetalToolchain # installs it
```

`xcrun --find metal` is no test for it: that finds a stub either way. Without
the component the build fails with "missing Metal Toolchain".

```bash
cd tools/local-llm-helper
swift build -c release
.build/release/local-llm-helper selftest
```

The build writes two things that must stay side by side: the executable
`local-llm-helper` and MLX's shader library `mlx-swift_Cmlx.bundle`. The
executable finds the bundle next to itself. `.build/release` is a link to
`.build/out/Products/Release`.

**Always use the release build to run a model.** A debug build fails the
selftest: its 4-bit quantised matrix multiply, the operation every layer of a
quantised model runs, ends in a GPU timeout and returns wrong numbers.

### Pinned dependencies

| Package | Version | Why |
|---|---|---|
| `mlx-swift-lm` | 3.32.3 | the model code (`MLXLLM`, `MLXLMCommon`); the version the path was proven with |
| `mlx-swift` | 0.32.3 | what mlx-swift-lm 3.32.3 resolves to |
| `swift-transformers` | 1.3.5 | the tokenizer and chat templates; resolved alongside them when the path was proven |

All three are pinned `exact:` in `Package.swift`, and `Package.resolved` is
committed. swift-transformers is a direct dependency because mlx-swift-lm's
own tokenizer adapter (`MLXHuggingFace`) also brings a Hugging Face
downloader, and this program must have no way to reach the network. Updating
any of them is one deliberate edit of `Package.swift`, followed by the
selftest and the tests below.

## Modes

```text
local-llm-helper run              one protocol, request on standard input
local-llm-helper check <folder>   validates a model folder without loading weights
local-llm-helper selftest         proves the Metal shaders load and compute
```

### `run`

The request is one JSON object on standard input, which the app then closes.
Prompts never appear on the command line, where other processes could read them.

```json
{
  "modelFolder": "/absolute/path/to/Qwen3.8-27B-4bit",
  "systemPrompt": "...",
  "userPrompt": "...",
  "contextLimit": 32768,
  "outputLimit": 16000,
  "outputPath": "/absolute/path/in/the/private/run/directory/protocol.md"
}
```

In order, and everything up to the last step without loading weights:

1. Reads the request. Standard input ending before a single byte means the
   parent went away: status 13.
2. Checks the model folder exactly like `check`.
3. Renders `[system, user]` through the model's chat template with
   `enable_thinking: false`, so a Qwen3 template ends the prompt with an empty
   thinking block and the model writes the protocol directly.
4. Refuses when prompt tokens plus `outputLimit` exceed `contextLimit`. The KV
   cache is bounded to `contextLimit` and would otherwise drop the oldest
   tokens, the start of the transcript, instead of failing.
5. Creates `outputPath` owner-only (a symlink there is refused).
6. Loads the weights and generates. Each decoded piece is written to the
   output file at once, so a helper that is killed leaves what it had; the
   file is synced every 32 tokens and at the end.

### `check <folder>`

Prints one JSON line on standard output and exits 0 when the folder is usable,
11 when it is not. It reads config.json, the tokenizer files and the chat
template, and renders a two-word test prompt; the weight files are checked with
`stat` and `access` only, never opened.

```json
{"modelType":"qwen3_5","name":"Qwen3.8-27B-4bit","problems":[],"quantization":{"bits":4,"groupSize":64},"sizeBytes":16106127360,"usable":true}
```

| Key | Meaning |
|---|---|
| `usable` | true when `problems` is empty |
| `name` | the folder's name, which for a Hugging Face download is the model's |
| `modelType` | config.json's `model_type`, when readable |
| `quantization` | `bits` and `groupSize`, absent for an unquantised model |
| `sizeBytes` | bytes of the weight files on disk, absent when one is missing |
| `problems` | every problem found, each `{"file": ..., "problem": ...}` |

`file` is a name inside the folder, or `.` for the folder itself. `problem` is
one of `missing` (absent or not a regular file), `unreadable`, `invalid` (does
not parse, or lacks what it must declare) and `unsupported` (on config.json:
a model type the pinned mlx-swift-lm cannot run). A missing chat template is
reported as `chat_template.jinja`; weights with no index and no
`*.safetensors` file as `model.safetensors`.

### `selftest`

Runs a few MB of GPU operations against the same operations on the CPU: matrix
multiply, a bf16 4-bit quantised multiply, RMS norm, RoPE and attention, the
last three from the compiled shader library. Prints one line per check and
`SELFTEST OK`, exit 0; otherwise `SELFTEST FAILED`, exit 1.

## Exit statuses

The app mirrors these numbers; they are defined once, in
`Sources/LocalLLMHelper/ExitStatus.swift`, and a test keeps this table in step
with it.

| Status | Reason | Meaning |
|---|---|---|
| 0 | `written` | the model ended the protocol; the output file holds all of it |
| 10 | `incomplete` | generation stopped at `outputLimit`; the text so far is kept |
| 11 | `model-unusable` | the model folder is missing, incomplete, unreadable or unsupported |
| 12 | `prompt-too-long` | prompt plus `outputLimit` exceed `contextLimit`; no weights loaded |
| 13 | `terminated` | SIGTERM, or the parent is gone; what was written is flushed first |
| 1 | `failure` | anything else: an unreadable request, an output file that cannot be created, a load or generation error |

A helper ended by a signal (SIGKILL, a crash, or a SIGTERM that arrived before
the handler was installed at the very start) has no exit status; the app reads
that as a failure, or as terminated when it sent the signal itself.

## Lines on standard error

Content-free by construction: every value is a number or a fixed word, and no
line can carry prompt or protocol text (a test puts a marker into the prompt and
asserts it never appears). Progress lines reset the app's no-progress deadline.

```text
lifecycle event=started                                  handlers in place, reading the request
lifecycle event=prompt tokens=<n> context=<C> output=<O> rendered prompt size, before the context check
progress phase=loading                                   the weights start loading
progress phase=prefill chunk=<n> total=<N>               prompt chunk n of N read
progress phase=writing tokens=<n>                        n tokens written and synced (every 32, and at the end)
lifecycle event=exit status=<s> reason=<word>[ detail]   the last line
```

The exit line's detail is `cause=sigterm|parent-gone|stdin-closed` for status
13, `error=usage|bad-request|template|output-file|load|generation` for status
1, and `problems=<count>` for status 11. Prefill counts 512-token chunks plus
the final forward that produces the first token.

## Termination

- **SIGTERM** before generation (reading the request, checking, loading) ends
  the process at once. During generation it cancels it; mlx-swift-lm checks
  between prompt chunks and between tokens, then the helper syncs the output
  and exits 13. A SIGTERM that arrives after the model has finished does not
  change the status. The app escalates to SIGKILL after its grace period.
- **Parent death**: the helper watches its parent's pid with a kqueue
  `NOTE_EXIT` source and ends exactly as on SIGTERM, with `cause=parent-gone`.
  Standard input ending before the request is the same signal.

## Fixed settings

No setting reaches the user in the pilot; these are constants in
`Sources/LocalLLMHelper/Generation.swift`:

- sampling: temperature 0.7, top-p 0.8, top-k 20, Qwen3's values without
  thinking, the ones the tested protocols were judged with. Not read from the
  model's `generation_config.json`, which for the tested model carries the
  thinking-mode values (temperature 1.0, top-p 0.95).
- prefill: 512 tokens per forward (mlx-swift-lm's default).
- `Memory.cacheLimit`: 512 MB. The process ends after one protocol, so a
  larger buffer pool is only overhead.

## Tests

```bash
cd tools/local-llm-helper
swift build -c release && CFFIXED_USER_HOME="$(mktemp -d)" swift test
```

No test loads weights or needs the network. Model folders are built per test
in a temporary directory (`ModelFolderFixture`): real config, tokenizer and
template files with placeholder weight shards, then broken on purpose. The
release selftest test needs the release build first and skips without it.

Three tests need a real model folder and skip without one:

```bash
LOCAL_LLM_HELPER_TEST_MODEL=/path/to/Qwen3.8-27B-4bit swift test --filter RealModelTests
```

They check that the rendered prompt ends with the empty thinking block, that a
too-long prompt is refused with peak resident memory under 1 GB (the helper is
killed if it starts loading weights), and that `check` reports name,
quantisation and size. Measured with the tested model's tokenizer: the refusal
peaks at about 245 MB.

`scripts/lint.sh` does not cover this package yet.
