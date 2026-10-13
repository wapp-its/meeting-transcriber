---
satisfies: [R8]
---
# gh-2-protocol-templates-and-background-info.4 Regenerate a meeting's protocol afterwards

## Description
Adds "Regenerate Protocol…" (spec "Regenerating afterwards"): the finished-job record learns the meeting's start, a pure target resolution finds the transcript and the record for a chosen file, a one-at-a-time regenerator makes the new protocol and swaps it in safely, and a window drives it. Separate from task 3 because it shares only the options form; it depends on task 3 for that form and because both edit the menu and the scene.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/JobStatusDTO.swift`, new `Sources/ProtocolRegeneration.swift` (`ProtocolRegenerationTarget`, `ProtocolRegenerator`), new `Sources/RegenerateProtocolView.swift`, `Sources/MenuBarView.swift`, `Sources/MeetingTranscriberApp.swift`, `Sources/AppState.swift`, `Sources/A11yID.swift`, `Sources/TerminalJobRecord.swift` (read; edit only if the DTO field needs it), `docs/automation-api.md`, tests
**Touches:** [app/MeetingTranscriber/Sources/JobStatusDTO.swift, app/MeetingTranscriber/Sources/ProtocolRegeneration.swift, app/MeetingTranscriber/Sources/RegenerateProtocolView.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Sources/TerminalJobRecord.swift, docs/automation-api.md, app/MeetingTranscriber/Tests/ProtocolRegenerationTargetTests.swift, app/MeetingTranscriber/Tests/ProtocolRegeneratorTests.swift, app/MeetingTranscriber/Tests/RegenerateProtocolViewTests.swift, app/MeetingTranscriber/Tests/JobStatusResponseTests.swift, app/MeetingTranscriber/Tests/TerminalJobStoreTests.swift, app/MeetingTranscriber/Tests/TerminalJobRecordTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift]

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
- Finished jobs leave `PipelineQueue.jobs` after 60 s; the terminal store (last 1000 since gh-13) is the only durable record. Since gh-13 it stores `TerminalJobRecord` (`Sources/TerminalJobRecord.swift`): the wire `JobStatusDTO` flat next to `appName`, `meetingStartTime: Date?`, `enqueuedAt`, `audioDuration`, `participants`; `TerminalJobStore` is `@Observable` with `records: [TerminalJobRecord]` and `lookup(jobID:)` still returns the DTO. `ProtocolRegenerationTarget` takes the meeting start from `record.meetingStartTime`; the new `JobStatusDTO.meetingStartedAt` is the wire exposure of the same value (the DTO doc comment says a field added there reaches wire and history alike; keep the two in step in `TerminalJobRecord.init(job:)` / `JobStatusDTO.init(job:)`).
- Checked 2026-10-13 against `wapp/main` 557170da (fit check): `generateProtocol` is at `PipelineQueue+Stages.swift:929-991`; `docs/automation-api.md` has the job-status example at about `:404-424` and its field list at about `:428-445`; the scene's windows are `speaker-naming`, `settings`, `record-app` (`MeetingTranscriberApp.swift:305-322`) and `TranscriptionsView.windowID` (gh-13's Transcriptions window, `PipelineController+Transcriptions.swift` with `transcriptionEntries`, `canRetryJob`, `retryJob`); `bringWindowToFront(id:)` at `:428`. "Open Protocols Folder" is at `MenuBarView.swift:316-320` inside `protocolActions` (`:305-321`). `MeetingTranscriberApp.swift` is at 531 lines and `MenuBarView.swift` at 479 against a 600-line SwiftLint warning: keep the new window scene and menu item small.
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
"Regenerate Protocol…" (menu, under Open Protocols Folder) opens a window with the latest finished meeting preselected, a Choose File… button for any protocol (.md) or transcript (.txt), the shared template and background form, and Generate. The new protocol replaces the old one only after it has been generated and the meeting's files are confirmed unchanged; the old one goes to the Trash, or stays beside the new one when the Trash refuses. GET /v1/jobs/<id> and the finished-job history gain meetingStartedAt.

stage: impl-review - ran [..2026-10-13T19:47:15Z] (codex gpt-5.6-sol at xhigh, receipts effort xhigh; r1 NEEDS_WORK 2 findings: 1 fixed, 1 declined; r2 SHIP with one P2 note, fixed; r3 SHIP 0 findings on 7a15d2b2; receipts /tmp/impl-review-receipt-gh2-gh-2-protocol-templates-and-background-info.4-r1.json, -r2.json, -r3.json)
Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

Baseline: green before any edit (227 tests, the task's acceptance filter, rc=0).

Commits:
- 24c8b16a feat(app): regenerate a finished meeting's protocol. New Sources/ProtocolRegeneration.swift (ProtocolRegenerationError, RegenerationTranscript, ProtocolRegenerationFiles, ProtocolRegenerationTarget, ProtocolRegenerationFileOperations, ProtocolRegenerator) and Sources/RegenerateProtocolView.swift (RegenerateProtocolDraft, RegenerateProtocolView, the open panel). JobStatusDTO.meetingStartedAt, AppState.protocolRegenerator, the window scene, the menu item, three A11yID constants, docs/automation-api.md.
- 3bdf5ce5 fix(app): review r1 finding 1. A provider failure shows one fixed sentence and the log names only the error type, because ProtocolError.httpError carries the endpoint's error body, which can echo the transcript and background (R9).
- 7a15d2b2 fix(app): review r2 note. A failed staging-file creation no longer removes whatever already holds the `<basename>.md.regenerating` name (a folder there was deleted recursively).

Acceptance evidence:
- DTO: JobStatusResponseTests.testMeetingStartedAtIsSentForARecordingAndOmittedForAnImport ("2025-10-09T08:53:20Z" on the wire; key absent for an import). TerminalJobRecordTests.testARecordWrittenBeforeMeetingStartedAtDecodesWithoutIt.
- Target: ProtocolRegenerationTargetTests. The .txt beside the file is preferred whichever file is chosen. Without a usable .txt the protocol's Full Transcript section is used and marked. Neither gives noTranscript. A record found by either path gives title, start and job id, with the record stored under /private/var and the file reached through /var. No record gives the stripped basename and a nil start. latest skips records whose files are gone.
- Regenerator: ProtocolRegeneratorTests, real temp files with an injected generator, Trash and single failing steps.
  - Success: the new file is at the old path, mode 0600, the old one trashed, no staging or previous file left, transcript untouched.
  - A refusing Trash leaves `<basename>.previous-<stamp>.md` beside the new protocol.
  - A failing staging write, permission change or final rename each leave the folder byte-identical.
  - A folder at the staging name is left alone.
  - A throwing generator changes no file, and its error text, carrying background and transcript, reaches neither the phase nor the notification.
  - A protocol-sourced transcript keeps its Full Transcript section with "Include full transcript" off.
  - Provider None, record-only and a busy job are refused before generating.
  - With the generator suspended, a Retry still running aborts the commit (meetingBusy). A Retry that finished and rewrote both files aborts it too (filesChanged), and its files stay byte-identical.
  - Template B and the background reach the generator; a missing template falls back with its warning.
- View: RegenerateProtocolViewTests. Generate is disabled without a target, while running, with provider None and in record-only mode, and enabled otherwise. Generate hands over the target and the draft's options. The Trash and unknown-date lines follow the target. Choose File… resolves the picked file or shows why not. MenuBarViewTests.testRegenerateProtocolCallsItsClosure.
- Mutation checks, each reverted (cmp against a backup): dropping the busy re-check, the byte comparison, the forced full transcript or the rename-back turned the matching tests red. Rethrowing the provider's own error turned the leak test red.

Gates on the committed tree 7a15d2b2:
- Acceptance filter "ProtocolRegenerat|RegenerateProtocol|JobStatus|TerminalJobStore|TerminalJobRecord|MenuBar|DebugRPCServerIntegration": 255 tests, rc=0 (log /private/tmp/mt-gh2-home/t4-final.log).
- ./scripts/lint.sh with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1: rc=0, 0 violations.
- swift build -c release -Xswiftc -DAPPSTORE: rc=0. swift build -c release (Homebrew): rc=0 on 24c8b16a, before the two small fixes.
- Not run: CI's swiftlint analyze (unused_declaration), which needs an xcodebuild build-for-testing. Every new declaration is referenced from Sources (checked by reading; the test-only `target.transcript` accessor was removed).

DECIDED:
- The review ran as the dispatch's host form (flowctl codex impl-review --spec codex:gpt-5.6-sol:xhigh --sandbox workspace-write), not through the impl-review skill, as for tasks 1 and 3.
- The meeting start comes from TerminalJobRecord.meetingStartTime (task Key context), not from parsing meetingStartedAt.
- The busy check also matches the record's job id (a retry keeps its id and namingSlug), besides basename and both paths. Paths are compared through symlinks with the folder resolved on its own, because resolvingSymlinksInPath leaves a missing /private/var path as is.
- A job that owns the meeting at commit reports "still being processed". The spec's step (1) gives the files-changed sentence for both cases; byte differences keep that sentence.
- Provider None is refused with ProtocolDestination.off.notice ("the same notice").
- Both files are read when Generate is pressed and compared at commit against that read, not against the read made when the window opened. A window left open across a Retry therefore still works.
- latest skips a record whose file exists but holds no transcript, and moves to the next record.
- Phase.succeeded carries warnings: [String] (template fallback, Trash refusal). Every outcome notifies: "Protocol Regenerated" (title plus warnings) or "Protocol Not Regenerated" (title: reason). Refusals notify too.
- "Include full transcript" is read when Generate is pressed. The language comes with the generator from PipelineController.makeProtocolGenerator, so there is no separate language closure.
- A chosen file without a transcript clears the preselected meeting and shows why under the meeting line. The window's last result is cleared when the window opens, unless a run is going.
- The staging write is three seam steps (create empty owner-only, restrict to owner, write) so each can fail on its own. Cleanup runs only after this run created the file.
- ProtocolRegeneration.swift carries "swiftlint:disable:this file_name" with its reason: the task fixes that file name for several types, as task 1 did.
- Declined review r1 #2 (a `.previous-<stamp>` name colliding within one second): it needs two commits in the same second, and runs go one at a time behind a provider call. It also fails safely: the original stays at its path and nothing is replaced.

ASSUMED: wording of the refusal and failure messages ("No transcript was found for this meeting: …", "Record-only mode is on: no protocol is made on this Mac.", "This meeting is still being processed. Try again once it has finished.", "The meeting's files changed while the protocol was being made, so nothing was replaced.", "Protocol generation failed, so nothing was replaced.", "The new protocol could not be saved, so the previous one was left in place: <reason>", and the restore-failed sentence) · flip at: app/MeetingTranscriber/Sources/ProtocolRegeneration.swift:ProtocolRegenerationError.errorDescription · test: ProtocolRegeneratorTests (asserts the case through localizedDescription, so the wording is free to change)
ASSUMED: window status copy ("Generating the protocol…", "Protocol regenerated: <file name>", the Trash-refused warning "The previous protocol could not be moved to the Trash and was kept as <name>.") and the menu icon arrow.triangle.2.circlepath · flip at: app/MeetingTranscriber/Sources/RegenerateProtocolView.swift:RegenerateProtocolView.status and ProtocolRegeneration.swift:ProtocolRegenerator.replaceProtocol · test: ProtocolRegeneratorTests.testARefusingTrashLeavesThePreviousProtocolBesideTheNewOne (counts the warning, not its words)

BLOCKED: none.

Owner checks (not checked live here):
- A real regeneration on the owner's provider: template B and background, the new file at the old path, the old one in the Finder Trash.
- Look of the window and the NSOpenPanel filter (.md/.txt, starting in the protocols folder).
- Return inside the background editor next to Generate's .keyboardShortcut(.defaultAction): if Return starts generation instead of adding a line, Generate needs another key binding (same open point as task 3's Start).

Follow-ups (not fixed): none new. No .flow/features map exists; the new user route is the menu item "Regenerate Protocol…" under "Open Protocols Folder", opening the window "Regenerate Protocol" (id regenerate-protocol, kept off the /screenshot, /ui/tree and /ui/press allowlists).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 24c8b16a163d991858e23c8926026bc987b2270f, 3bdf5ce5e2a759670d346c8218bf499701512c4a, 7a15d2b2478cfff23f9a075a0bdc97fcec9d8acd
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh2-home swift test --parallel --filter "ProtocolRegenerat|RegenerateProtocol|JobStatus|TerminalJobStore|TerminalJobRecord|MenuBar|DebugRPCServerIntegration" (255 tests, rc=0), PATH=/tmp/gh2-tick/lint-bin:$PATH ./scripts/lint.sh (rc=0, 0 violations), cd app/MeetingTranscriber && swift build -c release -Xswiftc -DAPPSTORE (rc=0)
- PRs: