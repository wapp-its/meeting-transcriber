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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
