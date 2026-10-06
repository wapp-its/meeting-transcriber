---
satisfies: [R8]
---
# gh-2-protocol-templates-and-background-info.4 Regenerate a meeting's protocol afterwards

## Description
Adds "Regenerate Protocol…" (spec "Regenerating afterwards"): the finished-job record learns the meeting's start, a pure target resolution finds the transcript and the record for a chosen file, a one-at-a-time regenerator makes the new protocol and swaps it in safely, and a window drives it. Separate from task 3 because it shares only the options form; it depends on task 3 for that form and because both edit the menu and the scene.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/JobStatusDTO.swift`, new `Sources/ProtocolRegeneration.swift` (`ProtocolRegenerationTarget`, `ProtocolRegenerator`), new `Sources/RegenerateProtocolView.swift`, `Sources/MenuBarView.swift`, `Sources/MeetingTranscriberApp.swift`, `Sources/AppState.swift`, `Sources/A11yID.swift`, `docs/automation-api.md`, tests
**Touches:** [app/MeetingTranscriber/Sources/JobStatusDTO.swift, app/MeetingTranscriber/Sources/ProtocolRegeneration.swift, app/MeetingTranscriber/Sources/RegenerateProtocolView.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/A11yID.swift, docs/automation-api.md, app/MeetingTranscriber/Tests/ProtocolRegenerationTargetTests.swift, app/MeetingTranscriber/Tests/ProtocolRegeneratorTests.swift, app/MeetingTranscriber/Tests/RegenerateProtocolViewTests.swift, app/MeetingTranscriber/Tests/JobStatusResponseTests.swift, app/MeetingTranscriber/Tests/TerminalJobStoreTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift]

### Approach
- `JobStatusDTO` (`JobStatusDTO.swift:7-41,125-140`): add `meetingStartedAt: String?` as an init parameter defaulting to nil (same reason `echo` defaults, see its comment), filled in `init(job:)` from `job.meetingStartTime` with `ISO8601DateFormatter()` default options. Synthesized decoding of a record without the key gives nil; test it, and that `GET /v1/jobs/<id>` JSON gains the key only when set. Document it in `docs/automation-api.md` next to the job status fields (around `:380-410`).
- `ProtocolRegenerationTarget` (tests first): `resolve(file:records:read:)` and `latest(records:fileExists:read:)` with injected file access, per the spec bullet; compare paths after `resolvingSymlinksInPath().standardizedFileURL` (temp dirs live under `/var` → `/private/var`). Title fallback uses `ProtocolGenerator.stripExistingTimestampPrefix` on the basename; the start date is parsed from `meetingStartedAt`.
- `ProtocolRegenerator` (`@MainActor @Observable`, owned by `AppState`): injected `generatorFactory` (production `pipeline.makeProtocolGenerator`, `PipelineController.swift:348-372`), template store, `language` / `includeFullTranscript` / `recordOnly` / provider closures reading settings, a busy check over `pipeline.queue.jobs` (non-terminal job whose `namingSlug` equals the basename or whose transcript/protocol path equals the target's), `notifier`, a file-operations seam (write a new owner-only file, rename, remove, trash; default `FileManager`) so tests can make any single step fail, a clock for the `.previous-<yyyyMMdd_HHmmss>` name, and the output folder for the security scope. `phase`: idle / running / succeeded(URL, warning?) / failed(message). Instructions come from task 1's `ProtocolTemplateStore.instructions(for:background:)`; the document from `ProtocolGenerator.composeDocument`. Keep the transcript source's bytes and the destination's bytes (or its absence) read before generating. The commit follows the spec's five steps exactly (busy re-check plus a byte comparison of both files after the provider returns, owner-only staging file `<basename>.md.regenerating`, old file renamed to `.previous-…`, staging renamed into place with roll-back, Trash last); do not reuse `ProtocolGenerator.saveProtocol` for it, because its atomic overwrite would replace the original before the old file is safe. Refuse up front (no generation) for provider None, record-only mode and a busy meeting. Notifications: "Protocol Regenerated" / "Protocol Not Regenerated" with the meeting title and the reason; error texts contain no transcript or background content.
- `RegenerateProtocolView` (window id `regenerate-protocol`, title "Regenerate Protocol"): target line, "Choose File…" (`A11yID.regenerateChooseFileButton`; `NSOpenPanel` limited to `.md`/`.txt`, starting in `settings.effectiveOutputDir/protocols`), the `ProtocolOptionsForm` from task 3 with its own `ProtocolOptionsDraft`, the Trash line and the unknown-date line, Generate (`regenerateGenerateButton`) and Close. `.onAppear` loads `latest` and resets the draft. Keep the panel call in a closure the view receives so tests never open a panel.
- Menu: "Regenerate Protocol…" under "Open Protocols Folder" (`MenuBarView.swift:190-205`), opening the window through `bringWindowToFront(id:)` like the other windows (`MeetingTranscriberApp.swift:383-392`).
- Never add `regenerate-protocol` to the `/screenshot`, `/ui/tree` or `/ui/press` allowlists.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/JobStatusDTO.swift:1-41,121-140` — DTO shape and the job mapping
- `app/MeetingTranscriber/Sources/TerminalJobStore.swift:1-62` — records available for lookup
- `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift:921-979` — the pipeline's generate-and-save steps the regenerator mirrors
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:280-297,377-407` — window scenes, open-protocol and output-folder access patterns

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/TerminalJobStoreTests.swift`, `Tests/JobStatusResponseTests.swift` — DTO and store test patterns
- `app/MeetingTranscriber/Tests/PipelineQueueProtocolSaveTests.swift` — protocol save test pattern
- `app/MeetingTranscriber/Sources/OutputDirectoryResolver.swift` — why views must not call `resolve()`; use `settings.effectiveOutputDir`

### Key context
- Finished jobs leave `PipelineQueue.jobs` after 60 s; the terminal store (last 200) is the only durable record, and `JobStatusDTO` is both its stored and its wire shape.
- When "Save raw transcript separately" was off, the `.txt` is gone and the transcript lives only after the last Full Transcript separator in the `.md`; then the new document always keeps that section.
- Nothing is moved, renamed or written before generation succeeds; a quit during generation leaves the old protocol untouched.
- Do not edit `CLAUDE.md` or `AGENTS.md`.
## Acceptance
- [ ] `JobStatusDTO` encodes `meetingStartedAt` for a recording, omits it for an import, and decodes a record written without it (R8).
- [ ] Target resolution: `.txt` sibling preferred; `.md` without a sibling uses its Full Transcript section and marks it; neither → "no transcript" error; record lookup by either path gives title, start and job id; no record → stripped basename and nil start; `latest` skips records whose files are gone (R8).
- [ ] Regenerator with injected generator, file operations and temp files: success puts the new protocol (owner-only) at the old path and trashes the old one; a throwing Trash leaves `<basename>.previous-<stamp>.md` beside it; a failing staging write, a failing permission change and a failing final rename each leave the original at its path and no staging file; a throwing generator changes no file; a protocol-sourced transcript keeps the Full Transcript section with "Include full transcript" off; provider None, record-only mode and a busy job are refused before generating; with the generator suspended, a Retry of the same meeting that is still running, and one that has already finished and rewritten the transcript and protocol, each make the commit abort, leaving the retry's files exactly as it wrote them; the chosen template and background reach the generator and a missing template falls back with its warning (R8, R3).
- [ ] ViewInspector: "Regenerate Protocol…" calls its closure; Generate is disabled without a target, while running, with provider None and in record-only mode; Generate with a target calls the regenerator with the draft's options; the unknown-date and Trash lines render from the target (R8, R6).
- [ ] `docs/automation-api.md` documents `meetingStartedAt`.
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<scratch> swift test --parallel --filter "ProtocolRegenerat|RegenerateProtocol|JobStatus|TerminalJobStore|MenuBar|DebugRPCServerIntegration" > /private/tmp/<scratch>/t4.log 2>&1` passes (read the log file).
- [ ] `./scripts/lint.sh` passes with the pinned tools, and `swift build -c release -Xswiftc -DAPPSTORE` compiles.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
