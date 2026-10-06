---
satisfies: [R4, R5, R6]
---
# gh-7-protocol-via-codex-cli-and-a-custom.1 Shared CLI runner with the Claude CLI provider moved onto it

## Description
Build the shared process core (`CLIProcessRunner`) and move the Claude CLI provider onto it without changing what Claude does. This is the early proof point: the runner must carry the existing Claude behaviour, every `ClaudeCLIProtocolGenerator*Tests` file stays green without edits beyond renamed symbols, and the runner adds what the Claude code lacks today (a wall-clock timeout that also stops a silent CLI, an output cap, SIGPIPE safety). Codex and the custom command (task .2) build on this runner.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/CLIProcessRunner.swift` (new), `app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator.swift`, `app/MeetingTranscriber/Sources/ProtocolGenerator.swift`, `app/MeetingTranscriber/Tests/CLIProcessRunnerTests.swift` (new), `app/MeetingTranscriber/Tests/ClaudeCLIProtocolGeneratorRunnerTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/CLIProcessRunner.swift, app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator.swift, app/MeetingTranscriber/Sources/ProtocolGenerator.swift, app/MeetingTranscriber/Tests/CLIProcessRunnerTests.swift, app/MeetingTranscriber/Tests/ClaudeCLIProtocolGeneratorRunnerTests.swift]

### Approach

- New `enum CLIProcessRunner`, whole file `#if !APPSTORE` (like `ClaudeCLIProtocolGenerator.swift:1`). Interface (signatures only; names may change, behaviour may not):
  - `static let searchPaths: [String]` — moved from `ClaudeCLIProtocolGenerator.searchPaths` (`ClaudeCLIProtocolGenerator.swift:30-35`); Claude keeps a `searchPaths` that returns the runner's, so its tests compile unchanged.
  - `static func environment(base: [String: String]) -> [String: String]` — `CLAUDECODE` removed, search paths prepended to `PATH`, the logic of `ClaudeCLIProtocolGenerator.buildEnvironment` (`:437-451`). Claude's `buildEnvironment(baseEnvironment:searchPaths:anthropicAPIKey:)` keeps its signature and adds the key on top.
  - `static func makeRunDirectory(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL` — the body of `makeWorkingDirectory` (`:453-480`): unique name with prefix `MeetingTranscriber-cli-`, `withIntermediateDirectories: false`, `0o700`. `ClaudeCLIProtocolGenerator.makeWorkingDirectory(in:)` delegates (the help probe and existing tests call it).
  - `struct Request { executable: URL; arguments: [String]; environment: [String: String]; workingDirectory: URL; standardInput: Data?; timeout: TimeInterval; maxStdoutBytes: Int; maxStderrBytes: Int }` with caps defaulting to 32 MiB and 1 MiB.
  - `struct Output { status: Int32; stdout: Data; stderr: Data }` (status is `Process.terminationStatus`).
  - `enum Failure: Error { case couldNotStart(String), timedOut, stdoutTooLarge }` — the `couldNotStart` text is `process.run()`'s error description, nothing from the program.
  - `static func run(_ request: Request) async throws -> Output`.
  - `static let defaultTimeout: TimeInterval = 600` — `ClaudeCLIProtocolGenerator.timeoutSeconds` (`:27`) becomes an alias of it, and task .2's generator uses the runner's constant, not Claude's.
- `run` behaviour: `process.arguments` set directly (never `/bin/sh -c`); `standardInput == nil` means `FileHandle.nullDevice`; otherwise a `Pipe` whose write end gets `fcntl(fd, F_SETNOSIGPIPE, 1)` before `run()` (pattern `tools/audiotap/Tests/HelpersTests.swift:117-121`). Install `terminationHandler` into an `AsyncStream` before `run()` (pattern `ClaudeCLIProtocolGenerator.swift:65-74`). **No pipe I/O may block a thread of Swift's cooperative pool, and none may outlive `run`:** `Task.detached` runs on that pool, so today's `Task.detached { handle.availableData }` (`:224-227`) and the detached stdin writer (`:95-112`) each park a pool thread while they wait, and a background child that keeps a pipe open would park it for good. Use event-driven I/O off the pool instead: `DispatchIO` (stream type) or `FileHandle.readabilityHandler` for stdout and stderr, and `DispatchIO` writes (or a non-blocking write end with `writeabilityHandler`) for stdin, finishing the stdin write by closing the write end. When `run` ends for any reason (exit plus drain cut-off, timeout, cap), cancel or remove every handler and close every parent-side pipe end before returning. Keep at most the cap while reading: stdout over its cap stops the program and fails `.stdoutTooLarge`; stderr keeps its first `maxStderrBytes` and discards the rest. One deadline (`timeout`) covers the exit and the reads; on expiry send SIGTERM, then SIGKILL one second later if still running (pattern `ClaudeCLIProtocolGenerator+SessionPersistence.swift:139-146`), throw `.timedOut`, and do not wait again. After the program exits, wait at most 2 s more for both pipes to reach EOF, then return what was read (a background child left holding the pipe must not hold up or fail the run). Never await the stdin writer after a timeout.
- Claude move: in `generate` (`ClaudeCLIProtocolGenerator.swift:39-138`) replace the `Process`/pipes/`readStreamJSON` code with one `CLIProcessRunner.run` call; keep `launchConfiguration`, the project-folder computation and `defer removeRunFolders` exactly as they are. Map `.couldNotStart` → the existing `claude_cli_not_found` log line + `.cliNotFound(claudeBin)`; `.timedOut` → a `claude_cli_timeout` log line + `.timeout`; `.stdoutTooLarge` → new `ProtocolError.commandOutputTooLarge(tool: "Claude CLI")`. Decode stdout with the existing `drainStreamJSONLines` over the whole buffer with a newline appended (so a final line without a newline still counts), then the existing non-zero-exit path (`handleFailure`, unchanged) and `validateGeneratedText`. Delete `readStreamJSON`; keep every parse/failure helper and its tests.
- Timeout injection: `init(claudeBin:language:anthropicAPIKey:timeout:)` with `timeout: TimeInterval = CLIProcessRunner.defaultTimeout` last (lint rule `function_default_parameter_at_end`).
- `ProtocolError` (`ProtocolGenerator.swift:264-296`): add `commandOutputTooLarge(tool: String)` inside the existing `#if !APPSTORE` block, message naming the tool and nothing else.

### Investigation targets

**Required** (read before coding):
- `app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator.swift:39-235` — the process code that moves, and its comments on the races it already handles
- `app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator+SessionPersistence.swift:36-148` — `launchConfiguration`, the bounded help probe and its SIGTERM/SIGKILL pattern
- `app/MeetingTranscriber/Tests/ClaudeCLIProtocolGeneratorTests.swift:395-600` — fake-CLI `generate()` tests that must stay green
- `tools/audiotap/Tests/HelpersTests.swift:110-125` — per-descriptor SIGPIPE suppression

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/ClaudeCLIProtocolGeneratorResultEventTests.swift:185-283` — failure-message tests through `generate()`
- `app/MeetingTranscriber/Tests/ClaudeCLIProtocolGeneratorSessionPersistenceTests.swift` — project-folder cleanup tests

### Key context

- Tests first, in `CLIProcessRunnerTests` with `#!/bin/sh` fake programs written like `makeFakeClaudeScript` (`ClaudeCLIProtocolGeneratorTests.swift:464-472`): (1) arguments arrive verbatim and an argument `a b;touch x` is one argument with no `x` created; (2) 1 MiB of stdin arrives in full (`wc -c`); (3) `standardInput: nil` gives EOF at once (`cat` returns); (4) exit status, stdout and stderr come back separately; (5) `exit 3` without reading 4 MiB of stdin returns status 3 and the test process survives; (6) `sleep 30` with `timeout: 1` throws `.timedOut` within about 3 s, and so does `trap '' TERM; sleep 30`; (7) `sleep 30 & echo done; exit 0` returns status 0 with stdout `done` within about 4 s; (8) a 1 KiB stdout cap with `head -c 100000 /dev/zero` throws `.stdoutTooLarge`, while a stderr over its cap keeps its first bytes and the run succeeds; (9) the program runs in the given working directory (`pwd -P`); (10) a missing executable throws `.couldNotStart`; (11) no leaked waiters: run `2 × ProcessInfo.processInfo.activeProcessorCount` programs concurrently that each leave `sleep 30` running with stdin, stdout and stderr inherited and exit 0, then check that every run returned within about 4 s and that a fresh `Task { }` and one more trivial run still complete within 2 s (with pool threads parked on pipes, this starves).
- In `ClaudeCLIProtocolGeneratorRunnerTests`: a fake claude that reads stdin, prints nothing and sleeps 30 s, with `timeout: 1`, throws `.timeout`. On today's code this hangs: guard the call with an `XCTestExpectation` and a short wait so the red run fails instead of hanging. A fake claude that exits 1 without reading a 1 MiB transcript throws `.cliFailed` and the test process survives.
- Equivalence harness for the move: the existing `ClaudeCLIProtocolGeneratorTests`, `…ResultEventTests` and `…SessionPersistenceTests` pin Claude's argv, environment, API key, working directory, stream-json decoding, failure messages and project-folder cleanup; they must pass with no edits beyond renamed symbols. Say in the done summary if any needed an edit and why.
- Lint runs `--strict`: function bodies over 60 lines and files over 600 lines fail. `ClaudeCLIProtocolGeneratorTests.swift` is at 600 lines, so new tests go in the new files.
- Swift 6 language mode: closures handed to `Process` and detached tasks must be `@Sendable`; `./scripts/pre-push.sh` (release build) catches Sendable diagnostics that a debug build tolerates.
- Verification: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh7-home swift test --parallel --filter 'CLIProcessRunnerTests|ClaudeCLIProtocolGenerator' > /private/tmp/mt-gh7-t1.log 2>&1` (read the log; never pipe a test run into tail/head/grep); `cd app/MeetingTranscriber && swift build -Xswiftc -DAPPSTORE --scratch-path /private/tmp/mt-gh7-appstore-build > /private/tmp/mt-gh7-t1-appstore.log 2>&1`; `./scripts/pre-push.sh`; `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 from `scripts/tool-versions.sh` (download the release assets named there, check the SHA-256, put them first on `PATH`; no `brew install`).
## Acceptance
- [ ] `CLIProcessRunnerTests` covers the eleven behaviours listed under Key context and passes, including the no-leaked-waiters check.
- [ ] Every existing `ClaudeCLIProtocolGenerator*Tests` passes with no edits beyond renamed symbols.
- [ ] A silent, hung fake Claude CLI is stopped at the injected timeout and `generate()` throws `.timeout`; a fake Claude CLI that exits without reading a 1 MiB prompt throws `.cliFailed` and the test process survives.
- [ ] No pipe read or write in the runner blocks a cooperative-pool thread, and every handler and parent-side pipe end is released when `run` returns.
- [ ] Claude's argument vector, environment, private working directory and project-folder cleanup are unchanged (pinned by the existing tests).
- [ ] The App Store variant builds with `-Xswiftc -DAPPSTORE`, and `./scripts/lint.sh` passes with the pinned tools.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
