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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
