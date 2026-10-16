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
Each local-model outcome now ends its job as spec R11 says, and the low-memory, no-model and paused notices (R4, R5, R8) have their own notification categories whose actions reach their own handlers, never the consent prompt. Try Again makes only the protocol again, through the protocol regeneration: it is refused with a reason during a recording, in record-only mode and while another protocol is being made, and a regeneration with the local model reports the local outcomes instead of a generic failure.

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

stage: impl-review - ran [2026-10-16T00:18Z..2026-10-16T00:34Z]

### Evidence

- baseline: green (focused Quick commands before any edit, 555 tests, rc=0)
- focused suite after the review fixes: 577 tests, rc=0 (`swift test --parallel --filter 'ProtocolGenerator|PipelineQueue|NotificationManager|OutputSettings|LocalModel|ProtocolRegeneration'`)
- all Settings suites after `SettingsView` changed: 376 tests, rc=0 (`--filter 'Settings'`)
- the four new or changed local-model suites: 37 tests, rc=0; `ProtocolRegenerationLocalModelTests` again after the last test commit: 9 tests, rc=0
- lint: 0 violations in 892 files (`./scripts/lint.sh`, pinned tools)
- App Store variant: `swift build --build-tests -Xswiftc -DAPPSTORE` rc=0
- CI's analyze step reproduced: clean `xcodebuild build-for-testing` rc=0, then `swiftlint analyze --strict` 0 violations in 813 files (the 3 compiler warnings in `ViewInspectorIdentifierTests.swift` were there before this task)
- not verified: the installed app. Open Settings landing on Output in a real window, and the actions pressed in Notification Center, are covered only at the ViewInspector and notification-manager layers.

### Review

- Round 1, three codex gpt-6-astra draws (correctness, contracts, integration): NEEDS_WORK with 3 findings; the validator kept all 3.
- Fixed #1: Open Settings now opens Settings on the Output tab (`SettingsNavigation` in `SettingsView.swift`).
- Fixed #2: a record-only hold no longer uses up the paused notice; a recording that defers the same job later still posts it.
- Declined #3: Try Again after an app restart runs without the meeting's background. Keeping it would need a new on-disk store of background text; the protocol-template work keeps background only with the job in the owner-only queue snapshot, and its regeneration window starts with an empty background. The reviewer's side: the task says Try Again uses the meeting's template and background, so R4 is partial after a restart. The re-review kept it as not fixed and returned SHIP.
- Round 2, one draw: SHIP.

### Touches extended

- `app/MeetingTranscriber/Sources/PipelineQueue+LocalModel.swift`: the deferral loop reports each deferral (`onLocalModelEvent`); the hand-off note named this place for the paused notice.
- `app/MeetingTranscriber/Sources/PipelineQueue.swift`: stores that callback (3 lines).
- `app/MeetingTranscriber/Sources/LocalModel/LocalModelGate.swift`: read-only `isRecordingActive`, so a regeneration refuses to start during a recording.
- `app/MeetingTranscriber/Sources/SettingsView.swift`: `SettingsTab` made internal, the `SettingsNavigation` request object and the `onChange` that applies it; needed for Open Settings on Output (review finding #1).
- `app/MeetingTranscriber/Tests/NotificationManagerSchedulingTests.swift`: the registered category set now includes the two local-model categories, which this task adds.

### Conductor decisions carried out

- A21: a record-only hold posts no notification. Flip: delete the line `guard !settings.recordOnly else { return }` in `app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift:LocalModelJobNotices.post`. Test: `LocalModelOutcomeMappingTests.testARecordOnlyHoldPostsNoNotice`, which also pins that a later recording still gets the paused notice.
- R12: notification titles, bodies, user info and log lines carry no transcript, protocol or background text; background stays in this process (`LocalModelNoticeBook`).

### Assumptions

- Notice bodies: paused "<title>: the protocol is written once the recording has ended."; low memory "<names>: there was not enough free memory for the local model. The transcript is saved."; no model "<names>: no local model is chosen, or it cannot be reached. Choose one in Settings → Output. The transcript is saved." (the mockup fixes the titles only) · alternatives: B — title-only notices; C — bodies that name the model · flip at: app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift:NotificationManager.localModelNoticeContent · test: NotificationManagerLocalModelTests.testEachNoticeIsPostedWithTheMockupsTitle
- Job warnings "Protocol not written: low memory — transcript saved", "Protocol not written: no local model — transcript saved", "Protocol incomplete — the local model stopped at its output limit" · alternatives: B — the generic "Protocol generation failed — transcript saved" for every outcome; C — warnings that name the model · flip at: app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift:LocalModelNotice.Shortfall.warning · test: LocalModelOutcomeMappingTests.testEachLocalOutcomeEndsTheJobAsR11Says
- Two categories, low memory with Try Again and Show Transcript, no model with Open Settings; the paused notice has no actions · alternatives: B — one third category with all three actions, as the task text puts it; C — a category for the paused notice too · flip at: app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift:NotificationManager.makeLocalModelCategories · test: NotificationManagerLocalModelTests.testTheShortfallCategoriesOfferTheActionsR4AndR8Name
- One notification per shortfall from its first notice until a local protocol is written, by the queue or a regeneration; later jobs join it · alternatives: B — one per model folder; C — one per job · flip at: app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift:LocalModelNoticeBook.file · test: NotificationManagerLocalModelTests.testAShortfallEpisodeKeepsOneNotificationUntilAProtocolIsWritten
- A job that got a low-memory or no-model notice posts no "Transcript Saved" beside it · alternatives: B — post both · flip at: app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift:LocalModelJobNotices.install · test: LocalModelOutcomeMappingTests.testThreeQueuedJobsShortOfMemoryRaiseOneNotification
- One paused notice per job and protocol stage, counted on notices actually posted · alternatives: B — one per deferral; C — one per recording for all jobs · flip at: app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift:LocalModelJobNotices.post · test: LocalModelOutcomeMappingTests.testARecordingPausesTheProtocolWithOneNoticePerStage
- Open Settings sends a one-time tab request the Settings view applies; otherwise Settings keeps its own tab state · alternatives: B — the tab held in a shared object, so Settings reopens on the last tab; C — the Settings window only · flip at: app/MeetingTranscriber/Sources/SettingsView.swift:SettingsNavigation · test: NotificationManagerLocalModelTests.testOpenSettingsOpensSettingsOnTheOutputTab
- Show Transcript opens the raw transcript, else the protocol, else reveals the folder · alternatives: B — always reveal the folder · flip at: app/MeetingTranscriber/Sources/NotificationManager+LocalModel.swift:LocalModelTranscriptDestination.of · test: NotificationManagerLocalModelTests.testShowTranscriptOpensTheTranscriptElseTheProtocolElseRevealsTheFolder
- Try Again after a restart keeps the template, runs without the background and says so in the result · alternatives: B — keep background owner-only on disk per open notice; C — refuse and point to Regenerate Protocol… · flip at: app/MeetingTranscriber/Sources/ProtocolRegeneration.swift:ProtocolRegenerator.tryAgain · test: ProtocolRegenerationLocalModelTests.testTryAgainAfterARestartSaysTheBackgroundWasNotUsed
- Try Again while another protocol is being made is refused with "Another protocol is being made. Try again once it has finished." · alternatives: B — queue it; C — fall back to Show Transcript · flip at: app/MeetingTranscriber/Sources/ProtocolRegeneration.swift:ProtocolRegenerator.tryAgain · test: ProtocolRegenerationLocalModelTests.testTryAgainWhileAnotherProtocolIsBeingMadeIsRefused
- A regeneration reports a recording, low memory and no local model with their own messages, a record-only deferral with the existing record-only refusal, and every other outcome as the generic failure · alternatives: B — the generic failure for all, as before · flip at: app/MeetingTranscriber/Sources/ProtocolRegeneration.swift:ProtocolRegenerator.regenerationError · test: ProtocolRegenerationLocalModelTests.testEachLocalOutcomeIsTheRegenerationsOwnResult

### Open item (rubric rule 3)

- The notification user info is a format that outlives the app: key `localModelMeetings`, one entry per meeting with jobID, title, folder, basename, template and hadBackground, never the background. A later version must keep reading these keys for notifications still on screen; an entry it cannot read makes the action do nothing (`LocalModelNoticeMeeting.meetings(in:)`).

### Routes changed (feature map)

- New: low-memory notice → Try Again (protocol only) or Show Transcript; no-model notice → Open Settings, landing on Settings → Output; paused notice, no actions.

### Follow-ups

- Background for Try Again after a restart (Declined #3): decide whether background may be kept owner-only on disk for as long as a notice is open.
- Live check in the installed app: press each notice action from Notification Center, and Open Settings with the Settings window closed and open.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: b108c81cbf9fe6e8d67bca7fbb241ad5d2d2a0aa, 65f8d6f9966df7c269e11a0c84905e5f05b52395, bbd6a759f7a01ca4a8437c121e46a21987d38bce, 940242597922d68e0fbc9a3cebf3ed4d2118a9d4
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'ProtocolGenerator|PipelineQueue|NotificationManager|OutputSettings|LocalModel|ProtocolRegeneration' (577 tests, rc=0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'Settings' (376 tests, rc=0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'ProtocolRegenerationLocalModelTests' (9 tests, rc=0), ./scripts/lint.sh (0 violations, rc=0), cd app/MeetingTranscriber && swift build --build-tests -Xswiftc -DAPPSTORE (rc=0), xcodebuild build-for-testing + swiftlint analyze --strict (0 violations, rc=0)
- PRs: