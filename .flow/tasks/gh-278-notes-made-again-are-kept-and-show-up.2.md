---
satisfies: [R3, R9]
---
# gh-278-notes-made-again-are-kept-and-show-up.2 Record a local-model stop for low memory or a missing model as failed notes, with its figures

## Description
Makes a local-model stop for low memory or a missing model a recorded notes failure with its figures (R3, A2, A6, A7), so the job stays under "Needs you" with Retry Meeting Notes instead of leaving the list after 60 s. The storage stays readable by a build without this spec. The row's wording comes in .4.

**Size:** M
**Files:** `Sources/LocalModel/LocalModelOutcome.swift`, `Sources/LocalModel/LocalModelGate.swift`, a new `Sources/LocalModelShortfallDetail.swift`, `Sources/PipelineJob.swift`, `Sources/PipelineQueue.swift`, `Sources/PipelineQueue+Stages.swift`, `Sources/PipelineQueue+MeetingNotes.swift`, `docs/architecture/pipeline.md`; tests `Tests/LocalModelOutcomeMappingTests.swift`, `Tests/LocalModelGateTests.swift`, `Tests/PipelineSnapshotTests.swift`, a new pure test file for the detail's sentence
**Touches:** [app/MeetingTranscriber/Sources/LocalModel/**, app/MeetingTranscriber/Sources/LocalModelShortfallDetail.swift, app/MeetingTranscriber/Sources/PipelineJob.swift, app/MeetingTranscriber/Sources/PipelineQueue.swift, app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift, app/MeetingTranscriber/Sources/PipelineQueue+MeetingNotes.swift, app/MeetingTranscriber/Tests/LocalModel*.swift, app/MeetingTranscriber/Tests/PipelineSnapshotTests.swift, app/MeetingTranscriber/Tests/LocalModelShortfallDetailTests.swift, docs/architecture/pipeline.md]

Paths under `Sources/` and `Tests/` are relative to `app/MeetingTranscriber/`.

### Approach
Test first: the mapping table and the decode test fail on today's code.
1. **The needed figure travels with the outcome.** `.lowMemory(LocalModelMemoryReading)` (`Sources/LocalModel/LocalModelOutcome.swift:75-77`) also carries the weight size, set at the admission refusal (`Sources/LocalModel/LocalModelGate.swift:288-291`, where `job.weightBytes` is known). The watchdog stop (`:335`, a 4 GB floor with no weights compared) passes none, which gives the memory-pressure sentence. Update every pattern match (`LocalModelGate.swift`, `Tests/LocalModelGateTests.swift`, `Tests/LocalModelOutcomeMappingTests.swift`).
2. **The detail type**, in a file compiled in both variants (`PipelineJob` exists in the App Store build, `LocalModelNotice.Shortfall` does not): a plain `Codable`, `Equatable`, `Sendable` struct, for example `LocalModelShortfallDetail { kind: lowMemory | noModel; neededBytes: Int64?; freeBytes: Int64? }`, with a pure sentence: low memory with both figures and free below needed → "Not enough free memory for the local model: needs about 22.5 GB, 21.5 GB free" (needed = weights + `LocalModelMemoryGuard.admissionHeadroomBytes`, `Sources/LocalModel/LocalModelMemoryGuard.swift:103`; free = the reading's `availableBytes`); a figure missing, or free not below needed → a sentence that names memory pressure without figures; no model → "No local model is chosen, or it cannot be reached". Decimal GB with one decimal (A7), formatted independently of the user's locale.
3. **The job field**: `PipelineJob.localModelShortfall: LocalModelShortfallDetail?`. `PipelineJob` has synthesized `Codable` and no `CodingKeys`, so an older snapshot decodes the field as absent, and an older build ignores the unknown key.
4. **The queue** (`Sources/PipelineQueue+Stages.swift:1795-1840`, `#if !APPSTORE`): for `.lowMemory` and `.noModel` keep the warning and the `.notWritten` event word for word, then record the failure as `.deadline` and `.failure` already do (`recordNotesFailure(id:, .other)`, `Sources/PipelineQueue.swift:1224`) and set the detail. Every other notes failure leaves the detail nil, so a later provider failure never shows old figures.
5. **Clearing** (`Sources/PipelineQueue+MeetingNotes.swift:139-148`): `clearNotesFailure(at:)` also clears the detail and removes the two shortfall warnings (`LocalModelNotice.Shortfall.allCases.map(\.warning)`, under `#if !APPSTORE`). `updateJobState` already calls it when notes are saved (`Sources/PipelineQueue.swift:1109`), so a successful Retry leaves no low-memory line. .3 relies on this.
6. **Notifications stay as they are** (A6): `LocalModelJobNotices.install` (`Sources/NotificationManager+LocalModel.swift:244-254`) already swallows the done notification of a job it noticed. Do not touch `doneNotification`.
7. **Docs**, in the same change: `docs/architecture/pipeline.md`, the failed-notes paragraph (`:48`): a local-model stop for low memory or no model is now a notes failure with Retry; `docs/architecture-macos.md:829` (memory guard) only if its text says otherwise.

Tests:
- `Tests/LocalModelOutcomeMappingTests.swift:14-50` (the `Expectation` table, `makeBench`, `waitUntilDone`): low memory and no model now end with `notesFailure == .other`, the detail with the figures, the warnings exactly as today, and `doneTitle: nil` (no second notification).
- Such a job is held (`isHeldAfterCompletion`), offers a retry (`hasRetryableMeetingNotes`, which needs `transcriptPath`; assert the stage has set it) and is listed by `jobsWithRetryableMeetingNotes` (the menu bar's "Needs you").
- Retry Meeting Notes after a low-memory stop that then writes notes: failure, detail and the shortfall warning are gone. A second stop records the failure again with the new figures and the warning once (check that `addWarning` does not duplicate).
- A provider failure after a shortfall leaves the detail nil.
- Decode (pattern `Tests/PipelineSnapshotTests.swift:105`): a snapshot this build writes stores `notesFailure` as an existing raw value (`"other"`) and decodes; the same JSON with the detail's key renamed to a key no build knows still decodes, as an older build reads it; an old snapshot without the key decodes with the detail nil.
- Sentence (pure): both figures; free not below needed; a figure missing; the no-model text; `22_500_000_000` bytes → "22.5 GB".
- The App Store variant still builds: `swift build -Xswiftc -DAPPSTORE`.

### Investigation targets
**Required** (read before coding):
- `Sources/PipelineQueue+Stages.swift:1795-1840,1400-1415` — `localModelResult` and its call site
- `Sources/LocalModel/LocalModelGate.swift:280-340` — the admission refusal and the watchdog stop
- `Sources/PipelineQueue+MeetingNotes.swift:120-150` — `stopOfferingNotesRetry`, `clearNotesFailure`
- `Sources/PipelineJob.swift:180-235` — `hasRetryableMeetingNotes`, `isHeldAfterCompletion`, `notesFailure`
- `Tests/LocalModelOutcomeMappingTests.swift:14-50` — the table to extend

**Optional** (reference as needed):
- `Sources/NotificationManager+LocalModel.swift:95-130,240-256` — `Shortfall`, its warnings, the done-notification swallow
- `Sources/MeetingNotesFailure.swift` — the existing failure kinds and their sentences

## Acceptance
- [ ] A low-memory or no-model stop leaves the job `.done` with `notesFailure == .other`, the detail with its figures, today's warning text unchanged, held, and offered for retry in the menu bar.
- [ ] No second notification for such a stop.
- [ ] A successful Retry clears the failure, the detail and the shortfall warning; a second stop records new figures; a provider failure leaves no old figures.
- [ ] A snapshot with the detail decodes in this build and as a build without the field reads it; an old snapshot decodes with the detail nil.
- [ ] The sentence gives decimal GB with one decimal, and names memory pressure without figures when a figure is missing or free is not below needed.
- [ ] Homebrew and App Store variants build; `docs/architecture/pipeline.md` describes the new failure.
- [ ] Each new or changed test fails on the code before this task.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
