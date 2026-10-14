---
satisfies: [R1, R2, R3, R4, R5, R6]
---
# gh-125-menu-job-lines-that-stay-still-while-a.1 Implement Menu job lines that stay still while a job runs

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
The menu no longer changes on a timer while a job runs. A running stage now reads "<stage> · since <start> · ready about <finish>", where the finish is fixed once from the recording's length and the history's speed for the run's own engine and diarizer mode. Jobs sit under "In progress" and "Needs you", and finished jobs leave the menu. "All Transcriptions..." sits next to "Open Protocols Folder". "Open Last Protocol" follows the job history, so it works after the queue drops the job and after a restart, and it reports a moved file.

stage: impl-review - ran [2026-10-14T09:59:35Z..2026-10-14T10:08:42Z] (codex gpt-6-astra xhigh; round 1 NEEDS_WORK 2xP2, round 2 SHIP)
Tier: implementer (explicit invocation: opus at xhigh) (model: claude-opus-5-5)
baseline: green (focused Quick command, 86 tests, before any edit)

### Verification
- Spec Quick command: 87 tests, rc 0.
- Widened focused set (menu, list, timing, stage-clock, naming session, PipelineQueueTests, MeetingTranscriberAppTests, ProcessingStats, ProtocolResume): 408 tests, rc 0.
- ./scripts/lint.sh with the pinned tools: 0 violations.
- swiftlint analyze after a clean xcodebuild (run on both commits): 2 unused_declaration hits, both in Sources/RecordingProvider.swift:144/146 (the pending-cut stubs storePendingCut / recordPendingCutResolution). Inherited: this diff neither touches that file nor mentions either name. Not re-checked against the base commit; if they are on wapp/main, CI's analyze job fails there too.
- Mutation checks: a late re-diarization that reads the stored mode fails PipelineQueueStageClockTests (offline instead of sortformer), and turning off the history read at creation fails all three stage-clock tests.

### Review findings and fixes (round 1 to round 2)
- R2: a stage resumed at launch got no finish, because the history was read in a background Task. Fix: the queue reads the history when it is created (StageTimingLog.loadRecentNow, nonisolated). Awaiting the read in processNext was tried and rejected because it reopened a double-run window (details in the commit body and the bug memory entry).
- R6: a moved file under "Open Last Protocol" opened nothing. Fix: MeetingTranscriberApp.openLastProtocol posts "The file was moved or deleted." (the window's sentence) as a standard notification, through its own onOpenLastProtocol callback.

### Decisions (continuing after the spec's A6)
- A7 · An expected finish is computed only at job events: a stage starting, or the audio length becoming known. A history reload never fills or changes one; the history is read when the queue is created, so a stage resumed at launch has it · flip at: PipelineQueue.estimateStageFinish and its callers · alternative: also fill a missing finish once when a reload first makes a speed usable.
- A8 · The stage label drops the state label's trailing "..." (Transcribing / Diarizing / Generating Protocol), matching the spec example · flip at: JobMenuSummary.stageProgress · alternative: keep "Transcribing...".
- A9 · "Open Last Protocol" on a missing file posts a standard notification with the window's sentence, because the menu has closed by then. A job line's Open keeps opening nothing · flip at: MeetingTranscriberApp.openLastProtocol · alternatives: an NSAlert, opening the Transcriptions window, or the same notification for job lines too.
- A10 · Transcription speed is keyed by engine alone; diarization and protocol by engine plus mode. The protocol's mode is the mode the job's diarization recorded (usedDiarizerMode) when the protocol stage starts. A late re-diarization passes the mode it runs in, never the stored one · flip at: StageTimingStats.speedByConfig / PipelineQueue.startStageClock · alternative: key transcription by engine plus mode too.
- A11 · Order of the file actions: Open Last Protocol, All Transcriptions..., Open Protocols Folder. "Needs you" uses the exclamationmark.circle symbol, and each section has a divider above it · flip at: MenuBarView.protocolActions / jobSections · alternative: All Transcriptions after the folder item.
- A12 · Every failed job in the history is listed under "Needs you", with no 3-item cap · flip at: TranscriptionList.menuSections · alternative: cap the list.
- A13 · The late-diarization delegate hook is now startDiarizing(jobID:mode:); namingStageDidEnd was deleted along with the timer · flip at: SpeakerNamingSessionDelegate · alternative: none needed.
- A14 · The old Open Last Protocol path was deleted: PipelineQueue.completedJobs (its only production reader went with the old action) and MeetingTranscriberApp.lastCompletedProtocolPath (already test-only), plus their tests · flip at: git history of this task · alternative: keep them as test-only leftovers.

### Notes for the conductor
- R5: ViewInspector 0.10.3 cannot read .keyboardShortcut, so keeping ⌘T and ⌘O is shown by the code only, not by a test.
- The NSMenu itself is manual-QA only: that the open menu really stays still under the pointer can only be seen in the running app. The tests show that the menu's texts and the job's clock stay identical between job events, after more than a second has passed and after a history reload.
- CLAUDE.md / AGENTS.md: no Architecture Note mentions the menu's elapsed time, average or finished-job lines, so nothing there became untrue.
- Feature map: the way to "Open Last Protocol" and "All Transcriptions..." changed (both now sit in the file-actions group, and Open Last Protocol now shows whenever a finished job exists). Finished jobs are reached through All Transcriptions... instead of the menu.
- Follow-ups (not filed): TranscriberStatus.protocolPath is no longer read by the menu; the negative-rank branch in TranscriptionList.finishOrders is now nearly unused.
- Memory: bug entry .flow/memory/bug/runtime-errors/launch-time-task-loads-race-restored-2026-10-14.md.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 3d113def8ae3cde645390828db7de8a044768c99, 7ccbf66b8feee94ca6b142b12f953bd42b1ac319
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh125-home swift test --parallel --filter 'MenuBarJobMenuTests|MenuBarViewTests|TranscriptionListTests|StageTimingStatsTests|PipelineQueueStageTimingTests' (87 tests, rc 0), swift test --parallel --filter 'MenuBarJobMenuTests|MenuBarViewTests|TranscriptionListTests|StageTimingStatsTests|PipelineQueueStageTimingTests|PipelineQueueStageClockTests|SpeakerNamingSessionTests|AccidentalNamingAcceptTests|MenuBarMicrophoneTests|MenuBarViewConsentPromptTests|MenuBarViewSessionControlsTests|MeetingTranscriberAppTests|PipelineQueueTests|SpeakerNaming|ProcessingStats|ProtocolResume' (408 tests, rc 0), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (0 violations), swiftlint analyze --strict after clean xcodebuild build-for-testing (2 inherited unused_declaration hits in Sources/RecordingProvider.swift:144/146, untouched by this diff)
- PRs: