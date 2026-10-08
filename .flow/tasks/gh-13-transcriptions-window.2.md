---
satisfies: [R2, R3, R4, R5, R6, R7, R9]
---
# gh-13-transcriptions-window.2 Transcription list logic and controller actions

## Description
The one list both views read, as pure logic, plus the controller actions behind it: merge live jobs with the history, order, search, the menu's subset, the shared status wording, the scoped file opener both views use, removing a failed job for good, and starting the pipeline when the window opens. Split from the views so every rule is tested at the cheapest layer (CLAUDE.md "GUI Testing", layer 1) before any view depends on it. See spec "Architecture & Data Models" (One list, Controller actions) and R2-R4, R6, R7, R9.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/TranscriptionList.swift` (new), `app/MeetingTranscriber/Sources/TranscriptionFileOpener.swift` (new), `app/MeetingTranscriber/Sources/JobMenuSummary.swift`, `app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift` (new), `docs/automation-api.md`, `app/MeetingTranscriber/Tests/TranscriptionListTests.swift` (new), `app/MeetingTranscriber/Tests/PipelineControllerTranscriptionsTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/TranscriptionList.swift, app/MeetingTranscriber/Sources/TranscriptionFileOpener.swift, app/MeetingTranscriber/Sources/JobMenuSummary.swift, app/MeetingTranscriber/Sources/PipelineController+Transcriptions.swift, docs/automation-api.md, app/MeetingTranscriber/Tests/TranscriptionListTests.swift, app/MeetingTranscriber/Tests/PipelineControllerTranscriptionsTests.swift]

### Approach
- Tests first (`TranscriptionListTests`, then `PipelineControllerTranscriptionsTests`), from the R-IDs, red before the code.
- `struct TranscriptionEntry: Identifiable, Equatable`: `id: UUID`, `title`, `appName: String?`, `date: Date?` (meeting start, else enqueue time), `enqueuedAt: Date?`, `audioDuration: TimeInterval?`, `participants: [String]`, `state: JobState`, `error: String?`, `warnings: [String]`, `protocolURL: URL?`, `transcriptURL: URL?`, `isLive: Bool`, `finishOrder: Int?` (see `entries` below), and `fileToOpen: URL?` = protocol, else transcript (the rule at `Sources/MenuBarView.swift:272`). One init from `PipelineJob` (live), one from `TerminalJobRecord` (history; paths via `URL(fileURLWithPath:)`; a record whose `jobID` is not a UUID is skipped).
- `enum TranscriptionList` (pure, no I/O):
  - `entries(liveJobs:records:) -> [TranscriptionEntry]`: a record whose id is live is dropped (live wins); dated entries newest first by `enqueuedAt` with a stable sort; undated (pre-change history) after them, newest stored first (the store appends, so reverse store order). Every terminal entry gets `finishOrder` = the index of its job's record in `records` (taken before de-duplication, so a live failed or done job uses its record's index too); a terminal live job with no record gets an order below every record, among such jobs by enqueue order. In production that is a failed job whose record the 1000-record cap evicted (the queue keeps failed jobs indefinitely), which must not crowd recent completions out of the menu; a queue without a store (tests) has only such jobs, so they still rank by enqueue order. The store appends a record, or moves it to the end, at each terminal transition (`TerminalJobStore.upserting`), so this is the order jobs finished in, while `enqueuedAt` is not: a retry keeps it.
  - `matching(_:query:)`: query trimmed of whitespace; empty returns the input; otherwise title or any participant `localizedStandardContains` the query.
  - `menuEntries(_:finishedLimit: Int = 3)`: every entry whose state is not terminal plus the `finishedLimit` terminal ones with the highest `finishOrder`, all returned in the order jobs were added (oldest first by `enqueuedAt`, undated first), so the menu keeps today's top-to-bottom order.
- `JobMenuSummary` (`Sources/JobMenuSummary.swift`): add `status(state:hasWarnings:progress:)` and `symbol(state:hasWarnings:)`; the existing `PipelineJob` overloads delegate to them. No wording change.
- `TranscriptionFileOpener` (new file): `static func perform(_ url: URL, scopeRoot: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }, action: (URL) -> Void) -> Bool` opens the security scope on `scopeRoot` around the call the way `openProtocolsFolder` does (`Sources/MeetingTranscriberApp.swift:401-407`), returns false without calling `action` when the file is missing, otherwise calls it and returns true. The views pass `NSWorkspace.shared.open(_:)` or `activateFileViewerSelecting([url])` as `action` and `settings.effectiveOutputDir` as `scopeRoot` (tasks .3 and .4 wire it).
- `PipelineController+Transcriptions.swift` (extension; `PipelineController` is `@MainActor @Observable`):
  - `var transcriptionEntries: [TranscriptionEntry]` = `TranscriptionList.entries(liveJobs: queue.jobs, records: terminalJobStore.records)`.
  - `func prepareTranscriptionsWindow()` = `ensureQueue()` (`Sources/PipelineController.swift:239-242`), the hook the window calls on appear (A6).
  - `func canRetryJob(id:) -> Bool` and `@discardableResult func retryJob(id:) -> Bool`: thin forwarders to the queue (`Sources/PipelineQueue+Recovery.swift:363-395`).
  - `func removeFailedJob(id:)`: `ensureQueue()` first (a failed job still only in the unread snapshot would otherwise come back on the next queue build); a live job that is not `.error` is refused (return, change nothing); a live `.error` job goes through `queue.removeJob(id:)` (`Sources/PipelineQueue.swift:551-573`, which marks the audio processed and saves the snapshot); then `terminalJobStore.remove(jobID:)` when the record is `.error` or the live job was. A record that is not `.error` is never removed. No file is deleted.
- `docs/automation-api.md:155-171`: "cap 200" becomes 1000; the `404` list gains "a failed job the user removed"; the retry note names the menu bar and the Transcriptions window.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/PipelineController.swift:98-113,154-189,239-294` — store ownership, `rebuild`, `ensureQueue`, `makeQueue` (snapshot read)
- `app/MeetingTranscriber/Sources/PipelineQueue+Recovery.swift:74-165,363-414` — restore rules, retry and its checks
- `app/MeetingTranscriber/Sources/PipelineQueue.swift:551-573` — `removeJob`
- `app/MeetingTranscriber/Sources/JobMenuSummary.swift` — wording to share
- `app/MeetingTranscriber/Tests/PipelineControllerTests.swift:21-60,80-100` — controller harness with isolated folders, `activate { MockEngine() }` + `ensureQueue()`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/MenuBarJobMenuTests.swift:84-115` — expected status strings per state
- `app/MeetingTranscriber/Sources/PipelineSnapshot.swift` — `save(_:to:)` to seed a snapshot in a test
- `app/MeetingTranscriber/Sources/ProcessedRecordingsLedger.swift:36-60` — `load()` to assert the audio was marked processed

### Key context
- At launch the controller holds a bare queue that has not read the snapshot (`PipelineController.swift:112`); only `makeQueue` reads it. Tests for the restart case must build the controller with `activate { MockEngine() }` and call `prepareTranscriptionsWindow()`, after seeding `PipelineSnapshot.save` and a `TerminalJobStore` file in the test's `tmpDir`, with the job's mix file present (the restore drops jobs whose audio is missing).
- `PipelineQueue.removeJob` is also the 60 s reaper for done jobs and the menu's Dismiss for naming-pending jobs; do not put the history removal inside it, or every reaped done job would vanish from the window.
- Await `queue.awaitSnapshotFlush()` before building a second controller over the same folder, or the restored file may still show the removed job.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<your scratch dir>/home swift test --parallel --filter 'TranscriptionListTests|PipelineControllerTranscriptionsTests|PipelineControllerTests|MenuBarJobMenuTests' > <your scratch dir>/t2-tests.log 2>&1` and read the log.
- `./scripts/lint.sh` with the pinned tools from `scripts/tool-versions.sh`.

## Acceptance
- [ ] A job that is both live and in the history yields one entry carrying the live job's state (R2).
- [ ] Order: dated entries newest first by enqueue time, then pre-change records without a date, newest stored first; a retried job keeps its place (R2).
- [ ] Every `JobState` maps to the menu's existing wording through the new `JobMenuSummary` overloads, and the `PipelineJob` overloads return what they returned before (R2).
- [ ] `matching` finds an entry by part of its title regardless of case and diacritics ("muller" finds "Müller Sync"), by a participant's name, returns everything for an empty or whitespace query, and nothing for a query no title or participant contains (R4).
- [ ] `menuEntries` over 2 unfinished and 10 finished entries returns the 2 unfinished plus the 3 that finished last, oldest added first; with no finished entries it returns only the unfinished ones (R7).
- [ ] A failed job added before three others that later finished, then retried and finished last (its record moved to the end of the history), is among the menu's 3 finished entries (R7).
- [ ] Three old live failed jobs whose records are no longer in the history (evicted by the cap) do not displace the 3 latest recorded completions from `menuEntries`; with no records at all, the 3 newest-added finished live jobs are chosen (R7).
- [ ] `TranscriptionFileOpener.perform` returns false and never calls the action for a missing file, and calls it with the URL and returns true for an existing temp file (R5).
- [ ] `removeFailedJob` on a live failed job removes it from the queue and the history and marks its audio processed; on a history-only failed record it removes the record; on a done record or a live waiting job it changes nothing (R6).
- [ ] Restart case: a failed job seeded in the snapshot (audio present) and the history is live and `canRetryJob` is true after `prepareTranscriptionsWindow()` on a fresh controller; after `removeFailedJob` and a snapshot flush, a further fresh controller over the same files lists no entry for it (R3, R6).
- [ ] `docs/automation-api.md` states cap 1000 and that a removed failed job answers `404` (R9).
- [ ] Tests and lint pass.

## Done summary
The Transcriptions window and the shortened menu now have one list to read. TranscriptionList merges the queue's jobs with the finished-job history (a job in both listed once, from the live job), sorts it newest first by enqueue time, searches title and participants without regard to case or diacritics, and picks the menu's share (every unfinished job plus the 3 that finished last). PipelineController gained the list, a window-opening hook that loads failed jobs from the last session so they can be retried, retry forwarders and removeFailedJob, which takes a failed job out of the queue and the history for good without deleting a file.

Tier: session (jev-unavailable(no_key)) -> explicit invocation opus at xhigh (actual: claude-opus-5-5)

stage: impl-review - ran [2026-10-08T11:40:56Z..2026-10-08T11:45:40Z]

The review ran on codex gpt-5.6-sol at xhigh with three draws (correctness, contracts, integration), each SHIP with no findings, so the validator pass had nothing to dispatch. Receipt /tmp/impl-review-receipt-372726e60d63-gh-13-transcriptions-window.2.json, fan-out rid 574099d7527448bdbde7d7ae981e39f3. The reviewers ran the focused suites themselves under CODEX_SANDBOX=workspace-write (45 of 45 passed) and wrote nothing into the tree.

Acceptance criteria, each covered by a focused test (115 tests, rc 0, /private/tmp/gh13/t2-gate.log at 03afcc19):
- A job both live and in the history is one entry with the live state; a record whose job id is not a UUID is skipped (R2). TranscriptionListTests.testAJobBothLiveAndInTheHistoryIsListedOnceWithItsLiveState
- Dated entries newest first by enqueue time (a meeting start 100 minutes earlier does not move a job), a retried job keeps its place, records without a date last and newest stored first; the date shown is the meeting start, else the enqueue time (R2). TranscriptionListTests.testDatedEntriesComeNewestFirstThenUndatedNewestStoredFirst
- Every JobState reads through JobMenuSummary.status(state:hasWarnings:progress:) and symbol(state:hasWarnings:) exactly as the menu did; the unchanged MenuBarJobMenuTests pin the PipelineJob overloads, which now delegate (R2). TranscriptionListTests.testEveryStateReadsTheWayTheMenuSaysIt
- "muller" finds "Müller Sync", "SYNC" the same, " perez " a participant "Ana Pérez", empty and whitespace queries return everything, "Quarterly" nothing (R4). TranscriptionListTests.testSearchFindsATitleOrParticipantIgnoringCaseAndDiacritics
- 2 unfinished plus 10 finished entries give the 2 unfinished and the 3 that finished last, in the order added; with no finished entries only the unfinished ones (R7). TranscriptionListTests.testTheMenuKeepsUnfinishedJobsAndTheThreeThatFinishedLast
- A failed job added first, retried and finished last (record moved to the end via TerminalJobStore.upserting) is among the menu's 3 (R7). TranscriptionListTests.testARetriedJobThatFinishedLastIsAmongTheMenusFinishedJobs
- Three live failed jobs whose records were evicted do not displace the 3 latest recorded completions; without any records the 3 newest-added finished live jobs are chosen (R7). TranscriptionListTests.testFailedJobsWhoseRecordsWereEvictedDoNotCrowdOutRecentCompletions
- Open takes the protocol, else the transcript, else nothing, from a history record's stored paths (R5). TranscriptionListTests.testOpenTakesTheProtocolElseTheTranscript
- TranscriptionFileOpener.perform returns false without calling the action for a missing file, and calls it and returns true for an existing temp file (R5). TranscriptionListTests.testTheFileOpenerActsOnlyOnAFileThatExists
- removeFailedJob on a live failed job removes it from queue and history, marks its audio processed and leaves the audio file in place (R6). PipelineControllerTranscriptionsTests.testRemovingALiveFailedJobTakesItOutOfQueueAndHistoryAndMarksItsAudio
- On a history-only failed record it removes the record, also after the store is re-read (R6). PipelineControllerTranscriptionsTests.testRemovingAFailedJobKnownOnlyFromTheHistoryDropsItsRecord
- On a done record or a live waiting job it changes nothing (R6). PipelineControllerTranscriptionsTests.testRemoveLeavesADoneRecordAndAnUnfinishedJobAlone
- Restart case: a failed job seeded in the snapshot (audio present) and the history is history-only and not retryable before prepareTranscriptionsWindow(), live with canRetryJob true after it, and absent from a further fresh controller after removeFailedJob and a snapshot flush (R3, R6). PipelineControllerTranscriptionsTests.testAFailedJobFromTheLastSessionIsRetryableOnceTheWindowOpensAndStaysRemoved
- Remove clicked before the pipeline started (the menu case) still keeps the job gone after a relaunch, because removeFailedJob starts the pipeline first (R6). PipelineControllerTranscriptionsTests.testRemovingBeforeThePipelineStartedKeepsTheJobGone
- docs/automation-api.md states cap 1000, that a failed job the user removed answers 404, and that retry is offered from the menu bar or the Transcriptions window (R9).
- Lint with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 returned rc 0 (0 of 708 files need formatting, 0 violations, /private/tmp/gh13/t2-lint.log). ./scripts/pre-push.sh --with-appstore returned rc 0 (Homebrew and App Store release builds, /tmp/gh13/t2-prepush.out).

Baseline before the edit was green (44 tests in PipelineControllerTests, MenuBarJobMenuTests, TerminalJobStoreTests and TerminalJobRecordTests, /private/tmp/gh13/t2-baseline.log). The new tests failed to build before the code existed (/private/tmp/gh13/t2-red.log). A mutation run applied 8 source mutations one at a time (history not de-duplicated, evicted failures ranked above records, menu ordered by finish order, search only case-insensitive, Remove without starting the pipeline, list sorted by meeting date, any record removed, opener ignoring existence); each turned its intended test red, and the sources were restored byte-identical before the commit (/tmp/gh13/t2-mut.out).

Decisions:
- TranscriptionEntry's two initialisers take finishOrder as a parameter and keep it nil for an unfinished state, so the "nil while unfinished" rule lives in the type. A finished live job without a record gets a negative order (rank minus count, by enqueue order), which places it below every record index.
- TranscriptionList.entries and menuEntries break ties on equal enqueue times by input position, and menuEntries orders undated entries by finish order (oldest stored first), so neither depends on sort stability.
- testOpenTakesTheProtocolElseTheTranscript and testRemovingBeforeThePipelineStartedKeepsTheJobGone go beyond the AC list. The first gives fileToOpen a caller (CI's swiftlint analyze flags unreferenced declarations); the second pins the ensureQueue() call in removeFailedJob, which no other test could catch.
- TranscriptionFileOpener calls startAccessingSecurityScopedResource on scopeRoot directly, as openProtocolsFolder does, and runs the existence check inside the scope.

Follow-ups and notes for the next tasks:
- PipelineController.retryJob(id:) has no caller until task .4 wires the window's Retry closure. CI's swiftlint analyze (unused_declaration) would flag it at this commit; it is used by the PR head once .4 lands.
- A user-facing route changes only in tasks .3 and .4; this task adds no view.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 03afcc19e41420b951a8c25f63da7ca38c59c609
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh13-home swift test --parallel --filter 'TerminalJobRecordTests|TerminalJobStoreTests|TranscriptionListTests|PipelineControllerTranscriptionsTests|MenuBarJobMenuTests|MenuBarViewTests|TranscriptionsViewTests|PipelineControllerTests' (rc 0, 115 tests, /private/tmp/gh13/t2-gate.log), PATH=$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH ./scripts/lint.sh (rc 0, 0/708 need formatting, 0 violations, /private/tmp/gh13/t2-lint.log), ./scripts/pre-push.sh --with-appstore (rc 0, /tmp/gh13/t2-prepush.out)
- PRs: