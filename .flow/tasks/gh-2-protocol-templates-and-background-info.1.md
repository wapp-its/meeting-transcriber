---
satisfies: [R2, R3, R7, R9]
---
# gh-2-protocol-templates-and-background-info.1 Template store, migration and per-job template in the prompt

## Description
Builds the template engine without any UI: template identity and the folder store, the default-template setting and the migration of the existing custom prompt, the two new job fields with their admission stamp, and the prompt the provider receives (spec "Templates" and "Per-job capture and the prompt"). It comes first because every later task uses these types, and it is the early proof point: a named template and a background text travel from enqueue to the provider's prompt, and the built-in prompt stays byte-identical.

**Size:** L (cohesive engine change, no UI; splitting it would leave a half-wired generator interface between tasks)
**Files:** new `app/MeetingTranscriber/Sources/ProtocolTemplates.swift` (`ProtocolTemplateID`, `ProtocolTemplateName`, `ProtocolTemplateStore`, `ProtocolTemplateMigration`), `Sources/AppPaths.swift`, `Sources/AppSettings.swift`, `Sources/AppSettings+RPC.swift`, `Sources/AppState.swift`, `Sources/ProtocolGenerator.swift`, `Sources/ClaudeCLIProtocolGenerator.swift`, `Sources/OpenAIProtocolGenerator.swift`, `Sources/PipelineJob.swift`, `Sources/PipelineQueue.swift`, `Sources/PipelineQueue+Stages.swift`, `Sources/PipelineController.swift`, `Sources/PipelineSnapshot.swift`, tests under `app/MeetingTranscriber/Tests/`
**Touches:** [app/MeetingTranscriber/Sources/ProtocolTemplates.swift, app/MeetingTranscriber/Sources/AppPaths.swift, app/MeetingTranscriber/Sources/AppSettings.swift, app/MeetingTranscriber/Sources/AppSettings+RPC.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/ProtocolGenerator.swift, app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator.swift, app/MeetingTranscriber/Sources/OpenAIProtocolGenerator.swift, app/MeetingTranscriber/Sources/PipelineJob.swift, app/MeetingTranscriber/Sources/PipelineQueue.swift, app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift, app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift, app/MeetingTranscriber/Sources/PipelineController.swift, app/MeetingTranscriber/Sources/PipelineSnapshot.swift, app/MeetingTranscriber/Tests/ProtocolTemplate*Tests.swift, app/MeetingTranscriber/Tests/PipelineQueueProtocolTemplateTests.swift, app/MeetingTranscriber/Tests/TestHelpers.swift, app/MeetingTranscriber/Tests/PipelineQueueSecurityScopeTests.swift, app/MeetingTranscriber/Tests/ProtocolGeneratorTests.swift, app/MeetingTranscriber/Tests/MeetingPromptMetadataTests.swift, app/MeetingTranscriber/Tests/OpenAIProtocolGeneratorTests.swift, app/MeetingTranscriber/Tests/ClaudeCLIProtocolGeneratorTests.swift, app/MeetingTranscriber/Tests/PipelineSnapshotTests.swift, app/MeetingTranscriber/Tests/RPCSettingsStateTests.swift]

### Approach
- **Tests first** for the contracts the spec pins: (a) before touching `ProtocolGenerator`, record today's `buildSystemPrompt` output for the built-in prompt (diarized and not, with and without a meeting start, fixed time zone) as expected strings, then keep that test green after the refactor with `ProtocolInstructions(template: ProtocolGenerator.protocolPrompt, background: nil)`; (b) the background block text and position exactly as written in the spec; (c) stamping and fallback in the queue.
- `AppPaths.protocolTemplatesDir` = `dataDir/"Protocol Templates"` next to `customPromptFile` (`AppPaths.swift:46-47`).
- `ProtocolTemplateStore` is a value type over one `directory: URL` with a `static let production`; every read lists the folder anew. `trash(name:)` takes an injectable trash closure (default `FileManager.default.trashItem`) so tests never touch the real Trash. `resolve(_:)` returns text, the ID used and the warning sentence from the spec's Edge Cases when it fell back.
- `AppSettings.defaultProtocolTemplate`: follow `protocolLanguage` (`AppSettings.swift:515-517`, init `:712`); stored string `""` = built-in.
- `ProtocolTemplateMigration.run(defaults:legacyPrompt:store:)`: the two steps from the spec, keyed on the hidden marker file `.legacy-prompt-migrated` inside the templates folder (its content = the migrated template name, empty when nothing was copied), never on the folder existing; the marker is written only after the copy succeeded. Expose the marker name as a constant on the migration type so task 2's "Open Templates Folder" never writes it. Call it in `AppState.makeDefaultSettings()` right after `LegacyDefaultsMigration.run(into: .standard)` (`AppState.swift:191-204`). Failures are logged (`.public` error text only, no prompt content) and never thrown.
- `ProtocolGenerator`: add `ProtocolInstructions`, change `buildSystemPrompt` to take it (drop `loadPrompt(from:)` and `promptURL`; `swiftlint analyze` would flag `loadPrompt` as unused), add `fullTranscriptSeparator`, `composeDocument(protocolMarkdown:transcript:includeFullTranscript:)`, `fullTranscript(in:)` (last separator) and `looksDiarized(_:)`, moving the inline code from `PipelineQueue+Stages.swift:938-966`.
- `ProtocolGenerating.generate(transcript:title:diarized:meetingStartTime:instructions:)`; both generators pass `instructions` into `buildSystemPrompt` (`ClaudeCLIProtocolGenerator.swift:45`, `OpenAIProtocolGenerator.swift:64-68`).
- `PipelineJob`: `protocolTemplate: ProtocolTemplateID?`, `protocolBackground: String?`, both init parameters defaulting to nil; `prepareForRetry` leaves them alone.
- `PipelineQueue`: both inits gain `protocolTemplateStore: ProtocolTemplateStore = .production` and `defaultProtocolTemplateProvider: @escaping () -> ProtocolTemplateID = { .builtIn }`; `stampTranscriptOutputOptions(on:)` (`PipelineQueue.swift:507-515`) also stamps a nil `protocolTemplate` (it already serves enqueue and orphan recovery, `PipelineQueue+Recovery.swift:487`); `generateProtocol` (`PipelineQueue+Stages.swift:921-979`) gets its `ProtocolInstructions` and fallback warning from the shared `ProtocolTemplateStore.instructions(for:background:)` (job gone → current default, no background) and adds the warning with `addWarning`; task 4's regenerator calls the same helper. `PipelineController.makeQueue` (`PipelineController.swift:249-283`) wires the production store and `{ [settings] in store.effectiveDefault(settings.defaultProtocolTemplate) }`.
- `PipelineSnapshot.save` (`PipelineSnapshot.swift:24-30`): create the staging file owner-only before writing (for example `FileManager.createFile(atPath:contents:attributes:)` with the owner-only mode constant from `FileManager+OwnerOnly.swift`, not `Data.write` followed by a chmod), remove it when `replaceItemAt` throws, and `restrictToOwner` the final file after the replace; a restrict failure is logged and swallowed (pattern `TerminalJobStore.swift` save).
- `/state`: `hasCustomPrompt` (`AppSettings+RPC.swift:96`) becomes `defaultProtocolTemplate != .builtIn`.
- Logging: never the background text; at most `background=present|absent` and the template name at `.private`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/ProtocolGenerator.swift:81-136` — prompt assembly to change
- `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift:915-979` — the single protocol-generation point
- `app/MeetingTranscriber/Sources/PipelineQueue.swift:479-515` — enqueue and the admission stamp to extend
- `app/MeetingTranscriber/Sources/PipelineJob.swift:127-211` — per-job captured options and init
- `app/MeetingTranscriber/Sources/AppState.swift:191-204` — the only production `AppSettings` construction (migration call site)

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/LegacyDefaultsMigration.swift` — one-shot migration style
- `app/MeetingTranscriber/Tests/TestHelpers.swift:366-406` — `MockProtocolGen` and the test-only `generate` overloads to keep compiling
- `app/MeetingTranscriber/Tests/PipelineQueueSecurityScopeTests.swift:143` — second test conformer (`GatedProtocolGen`)
- `app/MeetingTranscriber/Tests/OpenAIProtocolGeneratorTests.swift:162-210` and `Tests/ClaudeCLIProtocolGeneratorTests.swift:395-470` — request-body capture and fake CLI script for the "background reaches the provider" tests
- `app/MeetingTranscriber/Tests/ProtocolGeneratorTests.swift:190-260,355-386`, `Tests/MeetingPromptMetadataTests.swift` — tests using `promptURL`/`loadPrompt` that move to template text

### Key context
- Tests must never read or write the real Application Support folder: inject a temp-directory store into every queue that stamps or resolves a `.file` template; `CFFIXED_USER_HOME` only redirects models.
- Keep the old call shapes compiling in tests through the `extension ProtocolGenerating` helper in `TestHelpers.swift` (built-in template, no background); `MockProtocolGen` records the `instructions` it received.
- Synthesized `Codable` decodes a missing optional key as nil; add a test that decodes a snapshot JSON written without the new keys.
- `ClaudeCLIProtocolGenerator` is `#if !APPSTORE`; the App Store build must still compile.
- Do not edit `CLAUDE.md` or `AGENTS.md`.
## Acceptance
- [ ] With `ProtocolInstructions(template: ProtocolGenerator.protocolPrompt, background: nil)`, `buildSystemPrompt` returns exactly the strings recorded from the pre-change code (R3).
- [ ] A non-nil background produces the spec's block, verbatim and unsubstituted, between the meeting-time context and the template; a blank background produces none (R3).
- [ ] A queued job stamped `.file("B")` with a background yields a generator call whose instructions carry B's file text and the background; changing the default after enqueue does not change it; a retried job keeps both (R7).
- [ ] A missing or blank template file falls back to the built-in and adds the spec's warning to the job; a job without `protocolTemplate` (old snapshot) uses the current default; a recovered orphan is stamped (R3, R7).
- [ ] The restore's protocol-only resume uses the job's template (R3).
- [ ] Both generators put the background block into what they send (OpenAI system message, Claude CLI stdin) (R3).
- [ ] Migration: no legacy file → built-in default and an empty marker; non-blank legacy file → "Custom Prompt" file, marker and default; "Custom Prompt" already taken → "Custom Prompt 2"; a folder that already exists without the marker (created by Settings) still migrates; a failed copy writes no marker and a later run migrates; marker present and key absent (the other build) → default from the marker; key present → untouched; legacy file byte-identical afterwards (R2).
- [ ] `ProtocolTemplateStore` and `ProtocolTemplateName.validate` covered against a temp directory (listing filter and order, blank file, create, trash via injected closure, `effectiveDefault`, every refusal) (R1 groundwork).
- [ ] An old snapshot without the new keys decodes; the staging file is created mode 0600 before its bytes are written and is removed when the replace throws; `pipeline_queue.json` is mode 0600 after a save (R9).
- [ ] No log statement interpolates the background text (R9).
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<scratch> swift test --parallel --filter "ProtocolGenerator|ProtocolTemplate|MeetingPromptMetadata|OpenAIProtocolGenerator|ClaudeCLIProtocolGenerator|PipelineQueue|PipelineSnapshot|PipelineJob|AppSettings|RPCSettingsState" > /private/tmp/<scratch>/t1.log 2>&1` passes (read the log file, never pipe into tail/head/grep).
- [ ] `./scripts/lint.sh` passes with the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 from `scripts/tool-versions.sh` (fetched into a temp dir, first on `PATH`; no `brew install`), and `swift build -c release -Xswiftc -DAPPSTORE` compiles.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
