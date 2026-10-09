---
satisfies: [R1, R2, R6]
---
# gh-94-stop-a-detected-meeting-recording-by.2 Offer Stop Recording in the menu for every recording

## Description
Wires the menu to task .1 (R1, R2's entry point, R6): one `WatchingController.stopRecording()` that stops whatever records, an `AppState.canStopRecording` accessor, the scene passing the stop closure for every recording, and the architecture-doc rows for the new files. The automation API's opt-in stop is task .3; this task leaves the existing `/v1/record` verbs alone and adds a test that pins them (R6).

**Size:** S
**Files:** new `app/MeetingTranscriber/Sources/WatchingController+StopRecording.swift`, `app/MeetingTranscriber/Sources/AppState.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/MenuBarView.swift` (doc comment only), `docs/architecture-macos.md`, new `app/MeetingTranscriber/Tests/WatchingControllerStopRecordingTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/WatchingController+StopRecording.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, docs/architecture-macos.md, app/MeetingTranscriber/Tests/WatchingControllerStopRecordingTests.swift]

### Approach
- **`WatchingController+StopRecording.swift`** (new; pattern `WatchingController+WatchControl.swift:1-10`, a `@MainActor extension`; `WatchingController.swift` is at 580 lines): `func stopRecording()` — nothing when `watchLoop?.state != .recording`; a manual loop (`isManualRecording` on the loop) → the existing `stopManualRecording()` (`WatchingController.swift:527-530`, unchanged); otherwise `watchLoop?.stopDetectedRecording()` from task .1, keeping the loop (watching continues).
- **`AppState.swift`**: add `var canStopRecording: Bool { watching.isRecording }` next to `isManualRecording` (`:520-535`), with a doc comment carrying the existing reasoning: the loop-only predicate, because during a manual start that has registered but not built its loop there is nothing to stop yet. Rewrite `isManualRecording`'s doc comment so it no longer claims to drive the menu item; keep the property (`RPCManualRecordingStateTests` uses it, and SwiftLint's analyzer counts test references).
- **`MeetingTranscriberApp.swift:145-147`**: `onStopManualRecording: appState.canStopRecording ? { appState.watching.stopRecording() } : nil`. Keep this exact shape: the scene body is under the 300 ms type-check budget (note at `:111-118`).
- **`MenuBarView.swift:20`**: keep the label `onStopManualRecording` (the planned specs gh-43, gh-46 and gh-49 construct `MenuBarView` with it); add a one-line doc comment that it stops whatever is recording, a detected meeting included. No other view change: the view already shows "Stop Recording" whenever the closure is set (`:135-141`).
- **`docs/architecture-macos.md`**: rows for `RedetectionHolds.swift`, `WatchLoop+RedetectionHold.swift` and `WatchLoop+StopByHand.swift` in the WatchLoop table (`:133-152`), and for `WatchingController+StopRecording.swift` beside the other `WatchingController+…` rows (`:208-211`). Do not edit `CLAUDE.md` or `AGENTS.md` (fork rule).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/AppState.swift:500-540` — hoisted single-member accessors and why
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:111-160` — menu scene wiring and the type-check note
- `app/MeetingTranscriber/Sources/WatchingController.swift:170-195, 527-530` — `isWatching`, `isRecording`, `stopManualRecording`
- `app/MeetingTranscriber/Tests/WatchingControllerRecordControlTests.swift:118-133, 257-290, 329-345` — controller tests over `makeTestWatchLoop` with `FixedMeetingDetector`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/RPCManualRecordingStateTests.swift:14-30` — `makeRPCTestState()` with an injected loop
- `app/MeetingTranscriber/Tests/MenuBarViewTests.swift:721-760` — the existing Stop Recording button tests (already the wiring test for the control)

### Key context
- `makeTestWatchLoop(detector: FixedMeetingDetector(), notifier: RecordingNotifier(consentAnswer: .granted), pipelineQueue:)` records a detected meeting within a couple of 0.05 s polls once `controller.watchLoop = loop; loop.start()`; `FixedMeetingDetector` reports the meeting active forever, which is exactly the lingering signal the hold is for. Count recordings with `loop.onStateChange` (nothing else sets it on an injected loop).
- `MenuBarViewTests.swift` is at 980 lines: put new tests in the new file.
## Acceptance
- [ ] `WatchingControllerStopRecordingTests`: with a detected meeting recording on an injected loop, `stopRecording()` makes the loop leave `.recording` within 1 s, `controller.watchLoop` is still that loop, `controller.isWatching` is true, the recorder was stopped and one job is in the queue; over the next 0.5 s (detector still reporting the meeting) the loop does not enter `.recording` again.
- [ ] `stopRecording()` on a manual microphone recording ends it as `stopManualRecording()` does (`watchLoop` nil, recording enqueued); with the loop only watching it changes nothing and watching stays on.
- [ ] `AppState.canStopRecording` (via `makeRPCTestState()` and an injected loop) is false while only watching, true while a detected meeting records, and true while a manual recording records.
- [ ] R6 pin: `applyRecordAction(.stop)` while a detected meeting records returns `.unchanged` and the meeting keeps recording; the existing `WatchingControllerRecordControlTests` and `MenuBarViewTests` pass unchanged.
- [ ] `docs/architecture-macos.md` has rows for the four new source files.
- [ ] Focused run green, read from the log file: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "WatchingController|MenuBarView|RPCManualRecordingState|AppStateTests|WatchLoopStopByHand" > /private/tmp/mt-gh94-t2.log 2>&1; echo "exit=$?"` (never pipe the run into tail/head/grep).
- [ ] `PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh` reports 0 violations, and `./scripts/pre-push.sh --with-appstore` (release build, both variants) is clean.


## Done summary
The menu now shows "Stop Recording" for every running recording, a detected meeting included. `WatchingController.stopRecording()` sends a manual recording to the existing `stopManualRecording()` and a detected meeting to task .1's `WatchLoop.stopDetectedRecording()`, so watching stays on. `AppState.canStopRecording` (the loop is recording, any kind) decides when the menu scene passes the stop closure.

Integrated onto feat/gh-94-stop-detected-recording as 07b8c8cf (feat: offer Stop Recording in the menu for every recording) and 86a651a4 (docs: list the stop-by-hand and re-detection hold files); base a36bd26b. Worker commits 354aacbd/316a4b16 on wave/gh-94.2 were cherry-picked unchanged.

stage: impl-review - ran [22:01:37..22:09:55] SHIP, 0 findings, 1 draw (correctness; panel rule: small diff in one area, delegation only); receipt /tmp/impl-review-receipt-846594bd1b60-gh-94-stop-a-detected-meeting-recording-by.2.json (model: codex gpt-5.6-sol xhigh). An earlier draw [21:56:35..22:00:34] also returned SHIP but its round was refunded: the conductor committed a .flow line re-pin before the finalize, which refused on head_moved.
stage: wave-join - ran (cherry-pick of 2 commits, no collision)

Tier: session (jev-unavailable(no_key)); explicit invocation: opus at xhigh; actual model: claude-opus-5-5 (host-reported model id; effort not exposed by the host)

Gates (logs under /private/tmp)
- baseline: green via handoff (verified at 70ebb830 by the conductor's integrated verify, 176 tests); only `.flow/` paths changed since. Lint baseline exit 0 (`mt-gh94-t2-lint-baseline.log`).
- Task acceptance command (`mt-gh94-t2.log`) exit 0, 193 tests, all 5 new ones included; `WatchingControllerRecordControlTests` and `MenuBarViewTests` unchanged and green.
- Spec Quick command (`mt-gh94-t2-quick.log`) exit 0, 181 tests (176 + 5 new).
- Conductor's integrated verify on the target (`mt-gh94-verify-t2.log`) exit 0, 286 tests.
- `./scripts/lint.sh` with the pinned tools (`mt-gh94-t2-lint.log`) exit 0, 0 violations, 0/707 files to format.
- `./scripts/pre-push.sh --with-appstore` (`mt-gh94-t2-prepush.log`) exit 0, both release variants, 0 compiler warnings.
- `flowctl gate classify` returned FULL (Swift code changed). No GATE_SKIPPED lines.
- Mutation check against the new suite, then reverted byte-identically: four mutations at once each turned its own test red (`mt-gh94-t2-mutant1.log`); routing a detected stop to `stopManualRecording()` failed the detected-stop test on 6 assertions (`mt-gh94-t2-mutant2.log`).
- Not run: CI's `swiftlint analyze` (needs a clean xcodebuild).
- Build logs carry SwiftPM "Stale file" warnings from the cloned `.build` cache and pre-existing actor-isolation warnings in `ViewInspectorIdentifierTests.swift`; both predate this task.

Tests per acceptance criterion (Tests/WatchingControllerStopRecordingTests.swift)
- Detected stop: testStoppingADetectedMeetingEndsItsRecordingAndWatchingCarriesOn (loop leaves `.recording` within 1 s, stays on the controller with `isWatching` true, recorder stopped, 1 job, no second `.recording` entry over 0.5 s).
- Manual stop and watching-only no-op: testStoppingAManualMicrophoneRecordingEndsItAsAManualStopDoes, testWithTheLoopOnlyWatchingNothingChanges.
- `canStopRecording`: testTheMenuOffersAStopForEveryRecordingAndNotWhileOnlyWatching (watching-only false, detected true, manual microphone true).
- R6 pin: testAPlainRecordStopLeavesADetectedMeetingRecording (`applyRecordAction(.stop)` returns `.unchanged`; after 300 ms the meeting still records and its recorder was never stopped).
- Doc rows: `docs/architecture-macos.md` lists all four new source files.

Decisions (worker, rule 6)
- The doc comment on `AppState.isManualRecording` now says the `/state` snapshot and the automation API read the controller's wide predicate (`AppState+RPC.swift:89,119`); the property is kept as the task asks.
- `AppState.swift` would have reached 602 lines; condensing two doc comments brought it to 598 (2 below the strict 600-line cap; task .3 adds a closure there).
- `stopRecording()` returns early unless the loop is `.recording`, because `stopManualRecording()` drops the loop whatever it is doing; pinned by testWithTheLoopOnlyWatchingNothingChanges.
- The R6 pin lives in the new test file because Touches names only that test file.
- Two commits under the atomic-commit rule: the menu change with its own doc row, and the three doc rows for task .1's files separately.

Integration notes for tasks .3 and .4 are in the run notes dir (gh-94.2-integration.md).

stage: plan-sync - skipped(config: planSync.enabled=false)
## Evidence
- Commits: 07b8c8cf4f7cf3b13babcb2fc335edf4037297dc, 86a651a4d46a98a704dbdc59175ec27103e9a5a8
- Tests: worker (wave/gh-94.2): cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "WatchingController|MenuBarView|RPCManualRecordingState|AppStateTests|WatchLoopStopByHand" > /private/tmp/mt-gh94-t2.log 2>&1 (exit 0, 193 tests), worker (wave/gh-94.2): cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "RedetectionHolds|WatchLoopStopByHand|WatchLoopMeetingEnd|WatchingControllerStopRecording|WatchingControllerRecordControl|MenuBarView|RecordActionPayload|RPCRecordStatus|DebugRPCServerIntegration" > /private/tmp/mt-gh94-t2-quick.log 2>&1 (exit 0, 181 tests), worker (wave/gh-94.2): PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh > /private/tmp/mt-gh94-t2-lint.log 2>&1 (exit 0, 0 violations, 0/707 files to format), worker (wave/gh-94.2): ./scripts/pre-push.sh --with-appstore > /private/tmp/mt-gh94-t2-prepush.log 2>&1 (exit 0, both release variants, 0 warnings), conductor integrated verify (feat/gh-94-stop-detected-recording @ 86a651a4): cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "WatchingController|MenuBarView|RPCManualRecordingState|AppStateTests|WatchLoopStopByHand|RedetectionHolds|WatchLoopMeetingEnd|RecordActionPayload|RPCRecordStatus|DebugRPCServerIntegration" > /private/tmp/mt-gh94-verify-t2.log 2>&1 -> exit 0, 286 tests, impl-review receipt: /tmp/impl-review-receipt-846594bd1b60-gh-94-stop-a-detected-meeting-recording-by.2.json -> SHIP (codex gpt-5.6-sol xhigh, 1 draw: correctness SHIP, 0 findings; the first round's draw also returned SHIP but was refunded because the conductor committed bookkeeping before finalize)
- PRs: