---
satisfies: [R1, R2, R3, R4, R5, R6, R7]
---
# gh-130-record-a-meeting-again-after-stopping.1 Implement Record a meeting again after stopping it by hand

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
When a detected meeting's recording is stopped by hand or on the silence question while its call goes on, the menu now shows "Record Again (<App>)" under the status line. One click records the rest of that call at the watch loop's next poll as a detected recording, without a consent question or a "Meeting Detected" notice. That recording ends with the call by every rule a detected one ends by, and leaves no hold, so the next call is detected as usual. Detectors gained `markConfirmed(appName:)`, so Teams' new-call split still starts the next call's recording at once when the click came right after the stop.

stage: impl-review - ran [2026-11-14T21:07Z..2026-11-14T21:10Z] (codex gpt-6-astra xhigh, 3 draws, SHIP, 0 findings)

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

Baseline: green (build, the focused detector/loop/controller/menu suites with 595 tests, and lint, all before the first edit).

Verification on HEAD 3278535f:
- `swift build -j 6 --build-tests`: rc 0.
- Focused suites (`WatchLoop|WatchingController|MenuBarView|RedetectionHolds|PowerAssertionDetector|MicInputDetector|CompositeMeetingDetector|MeetingDetector`, with `WatchLoopMicSettingsTests` run separately): 612 + 7 tests, 0 failures. `WatchLoopStopByHandTests`, `WatchLoopSilencePromptDetectedTests`, `WatchLoopResumeHoldTests` and `WatchingControllerCallSplitTests` are green and unchanged.
- `./scripts/lint.sh`: 0 violations.
- Each new wiring line was falsified once: without `markConfirmed` in the click's step the split test fails, without dropping the approved answer the consent test fails, and without `cause != .recordAgain` the notification test fails.
- Not run: the App Store variant build. No `#if !APPSTORE` code was touched.

Tests by acceptance criterion:
- R1: `WatchLoopRecordAgainTests` (testRecordAgainIsOfferedAfterEitherStopUntilTheHoldIsReleased, testNoOfferForACallHeldWhenWatchingResumesAfterAManualRecording, testEachHeldAppHasItsOwnOfferAndAClickLiftsOnlyItsOwn, testNoOfferWhileTheLoopIsInItsErrorState) and `MenuBarViewSessionControlsTests.testRecordAgainLinesComeBetweenTheStatusAndTheWatchToggle`.
- R2: testAClickRecordsTheHeldMeetingAtTheNextPollWithoutAsking, testAClickForACallThatEndedBeforeThePollIsDropped, testAClickFromAStaleMenuChangesNothingAndLogsNothing, testTwoClicksBeforeThePollStartOneRecording, testARecorderThatFailsToStartIsReportedAndTheCallIsDetectedAnew, testAnApprovedAnswerForAnotherAppIsDroppedWhenAClickStartsARecording, testStopWatchingDiscardsAParkedClick, `MenuBarViewSessionControlsTests.testATapOnRecordAgainPassesTheOfferItShows`, `WatchingControllerRecordAgainTests.testTheClicksRecordingIsNotAnnouncedAndASplitAfterItIs`.
- R3: testTheNextCallIsDetectedAfterARecordAgainRecordingEndsWithTheCall, testTheNewRecordingIsItsOwnJobWithDefaultOptions, testRecordOnlyWritesTheNewRecordingWithAnAutoTrigger, `WatchLoopRecordAgainSplitTests` (real `PowerAssertionDetector`), and testAMarkedAppIsReturnedByTheNextPollAlsoInsideItsCooldown in `PowerAssertionDetectorTests` and `MicInputDetectorTests`, plus `CompositeMeetingDetectorTests.testMarkConfirmedReachesEveryStrategy`.
- R4: testTheNextCallIsDetectedAfterARecordAgainRecordingEndsWithTheCall (once per consent setting), testEachHeldAppHasItsOwnOfferAndAClickLiftsOnlyItsOwn (held and offered again).
- R5: `RedetectionHoldsTests` (testOnlyOfferedHoldsAreOffered, testLiftOfferedTakesOnlyAnOfferedHoldWhoseMeetingRuns) and the unchanged hold suites.
- R6: `MenuBarViewSessionControlsTests.testTheRecordItemsShowBesideARecordAgainOffer`.
- R7: the exact log assertions in `WatchLoopRecordAgainTests`, plus `docs/architecture/detection.md` (new hold and Record Again bullet) and `docs/architecture-macos.md` (new files, updated `RedetectionHolds` and `MenuBarView` rows).

Choices:
- Moved the Teams participant read out of `WatchLoop.swift` into `WatchLoop+Participants.swift` first, to pay for the poll hook's lines (598 lines now). Rule 1: the brief's line-cap rule.
- Named the new types, files and tests `RecordAgainOffer`, `WatchLoop+RecordAgain.swift`, `WatchingController+RecordAgain.swift`, `AppState+RecordAgain.swift`, `A11yID.recordAgainMenuItem`, `WatchLoopRecordAgainTests` (+Refusals), `WatchLoopRecordAgainSplitTests` and `WatchingControllerRecordAgainTests`. Rule 6.
- The loop marks the click's recording with a new `PhaseChangeCause.recordAgain`, passed through `runMeeting`/`handleMeeting` (`startCause`) to the move into `.recording`. `WatchingController` skips "Meeting Detected" on it; a split after it starts with `.regular` and is announced. Rule 6.
- `RedetectionHolds.hold(_:offered:)` defaults `offered` to false; production passes it explicitly (true from both stops, false from the resume snapshot), so the existing hold tests stay unchanged. Rule 6.
- The test harness gives each mock recorder a mix path with no file behind it, so a recording cut back at the end of a call never touches a shared `/tmp` file. Rule 6.
- Assumption: a click for a second app while one click waits for the poll is refused, and the first stands. switch: `app/MeetingTranscriber/Sources/WatchLoop+RecordAgain.swift:recordAgain(identityKey:)` · test: `WatchLoopRecordAgainTests.testTwoClicksBeforeThePollStartOneRecording`. Rule 4.
- Assumption: all Record Again lines share one identifier, with no index and no app name in it. switch: `app/MeetingTranscriber/Sources/A11yID.swift:recordAgainMenuItem` · test: `MenuBarViewSessionControlsTests.testATapOnRecordAgainPassesTheOfferItShows`. Rule 4.
- Assumption: the item's icon is `record.circle`, the same icon as the consent prompt's Record. switch: `app/MeetingTranscriber/Sources/MenuBarView.swift:recordAgainItems` · test: none pins the icon. Rule 4.

Questions:
- None.

Notes:
- Seen once under load: a debug build failed the 300 ms type-check limit on `WatchingController+LoopFactory.swift:makeAutoWatchLoop()` (306 ms). That file is unchanged, and the next build passed. CI's analyze build may hit the same limit under load.
- The reviewers' own test runs failed the unchanged `testAppDisplayNameUsesInstalledAppNameAndFallsBackToBundleID` (Finder's display name). That failure is environmental and predates this change.
- Follow-up for the owner, live: in a real call, stop by hand, click Record Again, end the call, then start a next call. Expected: two jobs, and the next call is detected.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 399b58cc1cbead1792eabbae95483936bbe733a2, 544938b88fb6600297a4573a655599bd8f8bd939, 131c784e09ecef32ab5ab7235dc2b3d68e04959e, 3278535f124fdbd3e47cb70cf57e9702ce28e76f
- Tests: cd app/MeetingTranscriber && swift build -j 6 --build-tests (rc 0), cd app/MeetingTranscriber && swift test -j 6 --skip-build --filter 'WatchLoop|WatchingController|MenuBarView|RedetectionHolds|PowerAssertionDetector|MicInputDetector|CompositeMeetingDetector|MeetingDetector' --skip 'WatchLoopMicSettingsTests' (612 tests, 0 failures), cd app/MeetingTranscriber && swift test -j 6 --skip-build --filter 'WatchLoopMicSettingsTests' (7 tests, 0 failures), ./scripts/lint.sh (0 violations)
- PRs: