---
satisfies: [R2, R9]
---
# gh-138-local-model-for-protocols-in-the.7 Real-model check, end-to-end run and docs

## Description
Finalization: the model-dependent checks from the spec's verification sequence (steps 3 and 4) and the fork-owned docs.

**Size:** S
**Files:** `app/MeetingTranscriber/Tests/LocalModelRealModelTests.swift` (new), `README.md`, `docs/architecture-macos.md`
**Touches:** [app/MeetingTranscriber/Tests/LocalModelRealModelTests.swift, README.md, docs/architecture-macos.md]

### Approach
- A test skipped unless an environment variable names a model folder (like the LocalVQE model-dependent tests): run the app-side generator with the bundled or built helper on a short synthetic transcript, through the app's own memory guard, with the helper's network access blocked (for example `sandbox-exec` with network denied around the helper); assert no thinking block and a non-empty protocol; start a recording via the automation API mid-run in the live variant and assert the helper ends within 5 s.
- End to end: build with `./scripts/run_app.sh --build-only`, run `scripts/local-llm-bundle-check.sh`, then one protocol through the running dev app (RPC `/v1/transcribe` with a fixture) with the local provider selected; record the commands and results in the task's done summary.
- Docs: README provider table, prerequisites (Metal Toolchain for the Homebrew build), and a short "Local model" section; `docs/architecture-macos.md` rows for the new files, the helper package and the build embedding. Never edit `CLAUDE.md` or `AGENTS.md` (they belong to the original project).

### Investigation targets
**Required:**
- `README.md:25-140,250-300` — provider mentions and troubleshooting
- `docs/architecture-macos.md:70-200` — pipeline and file tables
## Acceptance
- [ ] The real-model test passes on a developer Mac with the model folder set, and skips cleanly without it.
- [ ] The dev-run bundle writes one protocol end to end with the local provider; the command and its output are in the done summary.
- [ ] README and `docs/architecture-macos.md` describe the provider, its prerequisites and the helper packaging; `CLAUDE.md` and `AGENTS.md` are untouched.
## Done summary
Developers can now prove the local model provider against real weights. `LocalModelRealModelTests` runs the app's generator, gate and production memory guard on a real MLX model when `LOCAL_LLM_HELPER_TEST_MODEL` names a model folder, and skips both tests without it. README.md and docs/architecture-macos.md now describe the provider, its prerequisites (Metal Toolchain for building the Homebrew app) and the helper packaging. The end-to-end run through a launched dev-bundle app stayed blocked from verification (see Acceptance b); a run of the bundle's own helper through the app's generator stands in for it.

stage: impl-review - ran [2026-10-16T01:48:46Z..2026-10-16T01:59:59Z]
Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)
baseline: green (focused Quick commands, 578 tests, rc=0)

### Commits (4acbe585..HEAD)

| Commit | What |
|---|---|
| 699d3ec9 | test(app): the two real-model tests |
| 8a70b7f7 | docs(docs): README and architecture doc |
| 358f53f8 | test(app): review fix, teardown cancels and awaits the generation |
| 9f99ab51 | docs(docs): review fix, transcript promise limited to protocols not written |

CLAUDE.md and AGENTS.md are untouched (`git diff --stat 4acbe585..HEAD` lists only the test file, README.md and docs/architecture-macos.md).

### What the tests check

- `testRealModelWritesAProtocolWithoutThinkingOrNetwork` proves first that the `sandbox-exec` profile `(deny network*)` blocks `nc` from a loopback listener that `nc` reaches without it. It then runs one protocol through `LocalModelGate` with the real `SystemMemoryProbe` and production limits, the helper wrapped in that profile, and asserts non-empty text with no `<think>` or `</think>`.
- `testRecordingStartedThroughTheAutomationAPIEndsTheHelperWithinFiveSeconds` generates on `controller.pipeline.localModelGate` of a real `WatchingController`, waits until the helper has written protocol text, sends `POST /v1/record {"action":"start"}` to an in-process `DebugRPCServer` wired like the app, and asserts status 200, a running recording, the helper's pid gone in under 5 s and the outcome `.deferredForRecording`. The recorder is the test factory's mock, so no audio is captured.
- A memory-guard refusal throws `XCTSkip` with the readings and is never bypassed. A missing helper build fails with the build command.

### Commands and results

All test runs used `CFFIXED_USER_HOME=/tmp/gh138-tick/home`, and each started only after a busy check found the installed app neither recording nor processing a job. The model folder is an APFS clone of the tested model `mlx-community/Qwen3.8-27B-4bit` at `/tmp/gh138-tick/model/Qwen3.8-27B-4bit` with the original chat template restored.

| Command | Result |
|---|---|
| Baseline: `swift test --parallel --filter 'ProtocolGenerator\|PipelineQueue\|NotificationManager\|OutputSettings\|LocalModel\|ProtocolRegeneration'` | rc=0, 578 tests |
| `cd tools/local-llm-helper && swift build -c release` | rc=0 |
| `swift test --filter LocalModelRealModelTests` without the variable (after the review fix) | rc=0, 2 tests, 2 skipped, 0 failures |
| same with `LOCAL_LLM_HELPER_TEST_MODEL=/tmp/gh138-tick/model/Qwen3.8-27B-4bit` (after the review fix) | rc=0, both passed. Test 1 33.3 s, 2,363 characters; lines `local_model_started ... weights_mb=15310 pressure=normal available_mb=32058`, `local_model_prompt tokens=687 context=32768 output=16000`, `local_model_exit outcome=written status=0 elapsed_s=33 prompt_tokens=687 tokens=486`. Test 2 4.3 s; the helper ended 0.173 s after the POST |
| same, before the review fix | rc=0, both passed; 31.7 s and 2,320 characters; helper ended 0.206 s after the POST |
| `./scripts/run_app.sh --build-only` | rc=0, 108 s, helper installed and signed in `Contents/Helpers` |
| `./scripts/local-llm-bundle-check.sh` (dev bundle) | rc=0, `SELFTEST OK`, helper `flags=0x10000(runtime)`, swift-transformers found its resource bundle inside the app, `local-llm-bundle-check: OK` |
| Temporary probe test (deleted, never committed): the app's generator, gate and real guard on the dev bundle's `Contents/Helpers/local-llm-helper` under the no-network profile, German transcript | rc=0, 25.5 s, 1,475 characters, `local_model_started ... available_mb=28383`, `local_model_exit outcome=written status=0 elapsed_s=25 prompt_tokens=512 tokens=311` |
| Review-fix probe (temporary edit, restored): the recording test forced to fail right after the helper started writing, a teardown registered before the generation reporting whether the helper pid is gone | without the fix `probe: helper gone after teardown: false`; with it `true` |
| `flowctl gate classify --base 4acbe585` | FULL (Swift test file), focused gates run |
| Verify: the baseline's focused filter on 8a70b7f7 | rc=0, 580 tests (578 plus the 2 new, skipped) |
| `swift build --build-tests -Xswiftc -DAPPSTORE` | rc=0 on 8a70b7f7 and again on 9f99ab51 |
| `./scripts/lint.sh` (SwiftFormat 0.63.0, SwiftLint 0.65.1) | rc=0, 0 violations in 893 files, on 8a70b7f7 and again after the fixes |
| `xcodebuild -scheme MeetingTranscriber -destination 'platform=macOS' SWIFT_SUPPRESS_WARNINGS=NO -derivedDataPath <fresh> build-for-testing` then `swiftlint analyze --strict --compiler-log-path <log>` | rc=0 and rc=0, 0 violations in 814 files, on 8a70b7f7. Not rerun after the fix, which adds one method and one property, both used |

### Acceptance

- (a) Met. With the model folder set, both tests pass; without it, both skip cleanly (rc=0).
- (b) Blocked from verification. A copy of the dev bundle with its own bundle identifier, its own preferences domain (local model provider, the model folder above, Parakeet, no watching) and an isolated home exited within about 0.35 s on every launch path tried from this non-interactive session (direct exec, `open -n -g -W --env ...`, the fixed home alone). AppKit's reason is redacted in the log. The live microphone recording was not attempted either, since that identity has no microphone grant and would raise a permission prompt. Substitute evidence is the bundled-helper probe and the bundle check above, plus test 2 for preemption through the real HTTP route. The copy, its preferences domain and its LaunchServices registration were removed afterwards. To close it from an interactive login session, build with `./scripts/run_app.sh --build-only`, pick Local model and the model folder in Settings → Output of the dev bundle (never the installed app while it records or processes), start it with `MEETINGTRANSCRIBER_DEBUG_RPC=1`, then send `curl -sS -X POST http://127.0.0.1:9876/v1/transcribe -H "Authorization: Bearer $(cat ~/Library/Application\ Support/MeetingTranscriber/.rpc-token)" -H "Content-Type: application/json" -d '{"path":"<repo>/app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav","maxWaitSeconds":900}'` and check for a `.md` protocol in the output folder and `local_model_exit outcome=written` in `/usr/bin/log show --last 15m --predicate 'subsystem == "com.meetingtranscriber"'`.
- (c) Met. README: comparison table, pipeline diagram, feature list, prerequisites, a "Using the local model" section, the Metal Toolchain note under Build from source, the Output settings row and three troubleshooting rows. Architecture doc: pipeline box, rows for every new source file, the helper package and the test hook, a Local Model section on the process boundary, gate, memory guard, recording preemption, limits, quit, logs, packaging, signing and the bundle check, and the Settings UI rules.

### Review

Codex `gpt-6-astra` at effort `xhigh` (receipt `effort=xhigh`). Round 1 ran three lenses: correctness and contracts NEEDS_WORK, integration SHIP. The merged findings were (1, P1) the recording test left its generation, and with it the helper, running when it failed before the helper ended, and (2, P2) the README's "The transcript is saved in every case" was wrong with both transcript options off. Both were fixed (358f53f8, 9f99ab51), the fix to 1 proven by the red/green probe above. The single-reviewer re-review returned SHIP with both prior findings fixed and nothing new. Memory entry `bug/test-failures/test-started-task-left-a-model-helper-2026-10-16` records the lesson.

### Decisions

1. Rule 1: commit messages keep the `Task:` trailer, as every earlier commit of this spec does.
2. Rule 1 (spec A9, R4; conductor): a memory-guard refusal skips the test with its readings and never fails it or bypasses the guard.
3. Rule 6: a missing helper release build fails the test with the build command, because a skip there would hide a broken setup on a machine that set the model variable.
4. Rule 6: test 1 proves the network-deny profile works before trusting it, with a loopback listener and `nc`.
5. Rule 6: test 2 detects "mid-run" by the helper's first protocol bytes in `protocol.md`, since the gate the pipeline holds writes its lifecycle lines to the unified log, which the test does not read.
6. Rule 1 (fork rule that nothing writes into the owner's app folders or settings): the end-to-end instance got its own bundle identifier instead of a preferences file in an isolated home, because a process started with `CFFIXED_USER_HOME` still read the real preferences domain through cfprefsd (measured).
7. Rule 6: no microphone recording in the end-to-end attempt, to avoid a permission prompt for an identity with no grant.
8. Rule 6: the bundled-helper probe and the bundle check stand in for (b) while it is blocked; the probe test was deleted after its run.
9. Rule 6: the first review round ran all three lenses, since the test drives concurrency (a background generation, a real HTTP server, a child process).
10. Rule 6: both review findings were fixed, each in its own commit, since both showed the change itself doing the wrong thing in a covered scenario.

### Follow-ups

- Run the end-to-end check of Acceptance (b) from an interactive session with the commands above.
- `scripts/local-llm-bundle-check.sh` runs only by hand; no gate runs it.

Scratch left in `/tmp/gh138-tick`: the model clone, the isolated test home, logs and scripts. The e2e bundle copy and the derived-data directory were removed.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 699d3ec9d16c2e825a9c77aa6e1919cd51ee6343, 8a70b7f7dfee55ae9d9760f26e255f7d85096760, 358f53f8af59359695185c679fa42b82171703c7, 9f99ab517139123363ca03d46ea8a5e79aa1c6b0
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/gh138-tick/home swift test --parallel --filter 'ProtocolGenerator|PipelineQueue|NotificationManager|OutputSettings|LocalModel|ProtocolRegeneration' (rc=0, 580 tests), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/gh138-tick/home swift test --filter LocalModelRealModelTests (rc=0, 2 skipped without LOCAL_LLM_HELPER_TEST_MODEL), cd app/MeetingTranscriber && LOCAL_LLM_HELPER_TEST_MODEL=/tmp/gh138-tick/model/Qwen3.8-27B-4bit CFFIXED_USER_HOME=/tmp/gh138-tick/home swift test --filter LocalModelRealModelTests (rc=0, 2 passed), cd app/MeetingTranscriber && swift build --build-tests -Xswiftc -DAPPSTORE (rc=0), ./scripts/lint.sh with SwiftFormat 0.63.0 and SwiftLint 0.65.1 (rc=0, 0 violations), xcodebuild build-for-testing (fresh derived data) + swiftlint analyze --strict (rc=0, 0 violations, on 8a70b7f7), ./scripts/run_app.sh --build-only && ./scripts/local-llm-bundle-check.sh (rc=0, local-llm-bundle-check: OK)
- PRs: