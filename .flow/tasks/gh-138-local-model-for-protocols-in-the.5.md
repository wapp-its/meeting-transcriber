---
satisfies: [R4, R5, R8, R11]
---
# gh-138-local-model-for-protocols-in-the.5 Pipeline outcomes, notifications and Try Again

## Description
Turn each local outcome into the job result, warning and notification R11 lists, for the queue, the naming paths and gh-2's regeneration, and add the three notifications from the accepted mockup with their actions.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift`, `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift`, `app/MeetingTranscriber/Sources/NotificationManager.swift`, `app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift` (new), `app/MeetingTranscriber/Sources/AppNotifying.swift`, `app/MeetingTranscriber/Sources/PipelineController.swift`, tests
**Touches:** [app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift, app/MeetingTranscriber/Sources/ProtocolRegeneration.swift, app/MeetingTranscriber/Sources/NotificationManager*.swift, app/MeetingTranscriber/Sources/AppNotifying.swift, app/MeetingTranscriber/Sources/PipelineController.swift, app/MeetingTranscriber/Tests/LocalModelOutcomeMappingTests.swift, app/MeetingTranscriber/Tests/NotificationManagerLocalModelTests.swift, app/MeetingTranscriber/Tests/ProtocolRegenerationLocalModelTests.swift]

### Approach
- `generateProtocol`'s catch-all (gh-2 version around `PipelineQueue+Stages.swift:938-993`): catch `LocalModelOutcome` first and map per R11; incomplete saves the returned text through the normal save path plus an incomplete warning; everything else keeps the existing generic warning. Other providers untouched.
- gh-2's `ProtocolRegenerator`: refuse to start while a recording runs; map local outcomes to its result and notification instead of `generationFailed`.
- Notifications: a third category for local-model notices with actions Try Again, Show Transcript and Open Settings, registered beside `makeConsentCategory`/`makeMeetingEndCategory` (`NotificationManager.swift:98`), and an explicit branch in `userNotificationCenter(_:didReceive:)` (`:467-474`): anything not meeting-end currently falls through to the consent handler. A new `AppNotifying` method with a default no-op, like `askToRecord`. Titles and bodies exactly as the accepted mockup: "Protocol paused for your recording", "Protocol not written: low memory", "Protocol not written: no local model".
- Try Again starts gh-2's regeneration for that meeting with its template and background; Show Transcript reveals the transcript file (or the protocol's full-transcript section when the raw transcript was not kept); Open Settings opens Settings → Output.
- Regeneration stopped by a recording ends with its own reason (a new `ProtocolRegenerationError` case with a plain message) and is not resumed; refusal at start while a recording runs uses the same case.
- Try Again carries the meeting target (folder and basename) and the job id in the notification's user info, resolves it through `ProtocolRegenerationTarget.resolve`, and falls back to Show Transcript when the files are gone; it is refused in record-only mode.
- At most one low-memory and one no-local-model notification per gate episode; further jobs in the same episode raise a count in the existing notification instead of new ones.
- Show Transcript opens the raw transcript if kept, else the protocol (its Full Transcript section), else reveals the folder.
- The notification routing gets an explicit no-op for unknown categories.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/PipelineQueue+Stages.swift` `generateProtocol` (gh-2 version)
- `app/MeetingTranscriber/Sources/ProtocolRegeneration.swift` `ProtocolRegenerator.run` (gh-2)
- `app/MeetingTranscriber/Sources/NotificationManager.swift:90-110,380-480` — categories and routing
- `app/MeetingTranscriber/Sources/AppNotifying.swift`

**Optional:**
- `app/MeetingTranscriber/Tests/NotificationManagerMeetingEndTests.swift`, `FakeNotificationScheduler.swift`, `RecordingNotifier.swift`
## Acceptance
- [ ] Per outcome, a pipeline test with a fake generator shows the job state, warning and notification R11 names; an incomplete protocol is saved and flagged.
- [ ] Notification routing test: each local-model action reaches its handler and never the consent handler.
- [ ] Try Again runs only the protocol stage of that meeting via regeneration; pressed during a recording it is refused with a visible reason.
- [ ] Regeneration with the local provider reports local outcomes, not the generic failure.
- [ ] Three queued jobs failing on low memory in one episode raise one notification, not three.
## Done summary
Blocked:
Released by the attended session that babysits loop run 20261015T181628Z-39446-5158: the tick that claimed this task was stopped at its 18000 s limit (loop log 2026-10-15T23:16:45Z, TICK protocol=timeout) and no process of it is alive, so the claim belonged to an ended invocation. The next tick starts the task fresh.
## Evidence
- Commits:
- Tests:
- PRs:
