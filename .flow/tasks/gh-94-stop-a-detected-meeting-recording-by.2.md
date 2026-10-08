---
satisfies: [R1, R2, R6]
---
# gh-94-stop-a-detected-meeting-recording-by.2 Offer Stop Recording in the menu for every recording

## Description
Wires the menu to task .1 (R1, R2's entry point, R6): one `WatchingController.stopRecording()` that stops whatever records, an `AppState.canStopRecording` accessor, the scene passing the stop closure for every recording, and the architecture-doc rows for the new files. The automation API is deliberately untouched (spec A4); this task adds a test that pins it.

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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
