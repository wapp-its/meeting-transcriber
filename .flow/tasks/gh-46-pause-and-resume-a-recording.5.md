---
satisfies: [R5, R8]
---
# gh-46-pause-and-resume-a-recording.5 Pauses at the recording's end: cut and sidecar

## Description
The pauses at the end of a recording: gh-54's cut lands on the pause-free timeline and clips the job's pauses, and record-only mode writes and re-imports them through the sidecar (spec: Architecture "One conversion for cuts", "Dependency on gh-54"; Edge Cases "gh-54 countdown during a pause"; R5 cut part; R8). Needs task 4 (pauses reach `enqueueRecording`) and gh-54 merged. Kept apart from task 4 because the cut is the one place where a wrong conversion keeps room audio after a meeting, which deserves its own review.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/RecordingCut.swift` and `WatchLoop+MeetingEnd.swift` (from gh-54), `WatchLoop.swift` (`handleMeeting` / `enqueueRecording` hand-over), `WatchLoop+RecordOnly.swift`, `RecordingSidecar.swift`, `PipelineController.swift`; tests: gh-54's `Tests/RecordingCutTests.swift` and its meeting-end loop tests, `Tests/RecordingSidecarTests.swift`, new `Tests/WatchLoopPauseEndTests.swift`, `Tests/PipelineControllerTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/WatchLoop*.swift, app/MeetingTranscriber/Sources/RecordingCut.swift, app/MeetingTranscriber/Sources/RecordingSidecar.swift, app/MeetingTranscriber/Sources/PipelineController.swift, app/MeetingTranscriber/Tests/RecordingCutTests.swift, app/MeetingTranscriber/Tests/WatchLoopMeetingEnd*Tests.swift, app/MeetingTranscriber/Tests/WatchLoopPauseEndTests.swift, app/MeetingTranscriber/Tests/RecordingSidecarTests.swift, app/MeetingTranscriber/Tests/PipelineControllerTests.swift]

## Approach
- **The cut.** gh-54 turns its cut time into kept seconds in `RecordingCut.keptSeconds(cutAt:startedAt:stoppedAt:mixDuration:)` (at planning time on the gh-54 branch: the later of `cutAt − startedAt` and `mixDuration − (stoppedAt − cutAt)`, because the start estimate can lie after the first frame and the end estimate is early when a track ran short), called from `WatchLoop+MeetingEnd.swift`. Re-read the merged code and keep its structure; pass the stop-time pause list task 4 builds and subtract, in each wall-clock estimate, the paused time inside the interval it spans: `pausedDuration(from: startedAt, to: cutAt)` from the start estimate, `pausedDuration(from: cutAt, to: stoppedAt)` from the stop-to-cut distance of the end estimate (task 2's helpers). With no pauses the result is exactly gh-54's, so its existing tests (among them the delayed-start case: a 140 s mix, stop at start + 130 s, cut at start + 10 s keeps 20 s) stay green unchanged. Whatever stop time the cut reports for the sidecar stays the cut time on the wall clock; pauses never shorten it. When the cut succeeds, the job's and sidecar's pauses are `pauses.clipped(at: cutAt)`; when it fails, the recording is processed uncut with the pauses as recorded.
- **Keep the positions through the cut.** `RecordingCut.redirect(_:to:)` rebuilds a `RecordingResult` with the memberwise initialiser; make it carry `pauseOffsets` (task 3's field), or the job silently falls back to wall-clock marker positions after a failed swap.
- **Sidecar.** `RecordingSidecar` (`RecordingSidecar.swift:7-110`): bump `currentVersion` to the next number (3 at planning time) and extend the version comment; add `let pauses: [RecordingPause]?` with a `pauses` coding key, encoded only when non-empty, decoding as nil when absent (a v1/v2 sidecar); init parameter `pauses: [RecordingPause] = []`. Doc comment: `startedAt`/`stoppedAt` stay wall-clock, so recorded audio ≈ `stoppedAt − startedAt − Σ pause durations`. `writeRecordOnlySidecar` (`WatchLoop+RecordOnly.swift:12-61`) takes the pauses from `enqueueRecording`'s record-only branch (`WatchLoop.swift:475-502`).
- **Reimport.** `PipelineController.enqueueFiles` (`PipelineController.swift:425-450`) passes `pauses: sidecar?.pauses ?? []` into the paired group's `PipelineJob`. `PipelineController.swift` is at 590 lines: keep the change to that one argument.
- **Tests that pin today's version.** `Tests/RecordingSidecarTests.swift:43` asserts `version == 2` and `:120-150` use `"version": 3` as a future version; move those to the new current and next numbers.

## Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift` and `RecordingCut.swift` (from gh-54) — the cut and its tests (find them with `grep -rln "RecordingCut\|cutBack" app/MeetingTranscriber/Tests`)
- `app/MeetingTranscriber/Sources/RecordingSidecar.swift` — schema, lenient decode of `trigger`
- `app/MeetingTranscriber/Sources/WatchLoop+RecordOnly.swift:12-61` — sidecar write
- `app/MeetingTranscriber/Sources/PipelineController.swift:420-450` — reimport

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/WatchLoopTests.swift:410-490` — record-only recording through the loop, decoding the written sidecar
- `app/MeetingTranscriber/Tests/PipelineControllerTests.swift:220-240` — reimport with a sidecar
- `app/MeetingTranscriber/Tests/SidecarFixture.swift`

## Key context
- `RecordingSidecar.read` swallows decode errors with `try?`, so a malformed `pauses` value would drop the whole sidecar on reimport; only this app writes it, so a plain optional field is enough, but keep it optional.
- A pause spanning the cut time ends at the cut; a cut time inside a pause keeps exactly the audio before that pause.
- Commit messages are written for the original project's readers: no fork issue numbers or spec ids.

## Acceptance
- [ ] `keptSeconds` tests (extending `RecordingCutTests`, written first so they fail on the unadapted conversion): a pause between start and cut reduces the start estimate by its length; a pause between cut and stop raises the end estimate by its length; a cut time inside a pause lands at that pause's position; with no pauses every existing case, including the delayed-start one, returns what it returns today.
- [ ] `redirect(_:to:)` keeps `pauseOffsets`.
- [ ] The job (and in record-only mode the sidecar) of a cut recording carries the pauses clipped at the cut time (a pause after it dropped, a pause spanning it ending at it); a failed cut leaves the pauses as recorded; the sidecar's `stoppedAt` is the cut time.
- [ ] Record-only: a paused recording's sidecar has `pauses` with `startedAt`, `endedAt`, `offsetSeconds` and the new `version`; an unpaused one has no `pauses` key; a v2 sidecar (no `pauses`) still decodes with all its other fields.
- [ ] Reimporting a paused record-only recording through `PipelineController.enqueueFiles` produces a job carrying those pauses.
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'RecordingCut|MeetingEnd|WatchLoop|RecordingSidecar|RecordOnly|PipelineController|WatchingControllerRecordOnly' > <scratch>/t5.log 2>&1` green (read the log).
- [ ] `./scripts/lint.sh` clean with the pinned tools; `PipelineController.swift` and `WatchLoop.swift` stay at or under 600 lines.

## Done summary
A paused recording that ends through the meeting-end question or the long-silence question is now cut where the cut time falls on the saved tracks, which leave the paused time out. Before this, a pause before the cut made the cut keep the paused span's length of room audio from after the meeting. The job and the record-only sidecar carry the pauses clipped at the cut. The sidecar goes to version 3 with an optional `pauses` list, and a reimport hands those pauses to the job.

- `RecordingCut.keptSeconds` subtracts the paused time inside the interval each estimate spans (start to cut, cut to stop).
- `RecordingCut.redirect` keeps `pauseOffsets`.
- `cutBack` takes and returns `(recording:, pauses:)` and clips the pauses at the cut time only when the cut succeeds.
- The record-only branch writes the pauses into the sidecar, and `PipelineController.enqueueFiles` passes `sidecar?.pauses ?? []` to the job.

stage: impl-review - skipped(policy: parallel-wave - conductor owns the review after integration)

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

baseline: green via handoff (green at e9bb94be) + lint measured green pre-edit (`./scripts/lint.sh`, 0 violations, /tmp/gh46-tick/w5/lint-baseline.log)

### Commits (lane, base e9bb94be)

- 06cbc34c feat(app): place the meeting-end cut on the pause-free timeline
- f06a7a29 feat(app): keep a recording's pauses in the record-only sidecar

### Gates (worker, all measured, logs under /tmp/gh46-tick/w5/)

- Red first (red.log): with the conversion unadapted and nothing wired, every new test failed for its stated reason. Cuts kept 30 s or 15 s, the pauses arrived unclipped, the sidecar and the reimport carried no pauses, and `redirect` dropped the offsets.
- Focused, on the final committed tree (final-focused.log): `WatchLoopPauseEndTests|RecordingSidecarTests|PipelineControllerTests|RecordOnly|RecordingCutTests|WatchLoopMeetingEnd|WatchLoopPause`, 116 tests, rc 0.
- Task AC filter `RecordingCut|MeetingEnd|WatchLoop|RecordingSidecar|RecordOnly|PipelineController|WatchingControllerRecordOnly` with scratch home /tmp/gh46-home-t5 (t5.log): 303 tests, rc 1.
  - The only failures are the 5 known environmental `WatchLoopE2ETests`: testDiarizationSkippedWhenNotAvailable, testDualSourceTranscriptionPath, testFullPipelineDetectRecordTranscribeProtocol, testFullPipelineWithRealDiarization and testResamplePathProduces16kHzForWhisperKit.
  - The serial rerun of that class with `CFFIXED_USER_HOME=/tmp/gh46-home-t2b` (e2e-serial.log) passed 8 of 8, rc 0.
- Spec app Quick filter plus `RecoveredCut|PendingRecordingCut|AppStateTests` (quick.log): 387 tests, rc 0. The crash-recovery cut tests (A9) pass unchanged.
- `./scripts/lint.sh` with the pinned tools (final-lint.log): rc 0, 0 violations in 799 files, no file needs formatting.
- `./scripts/pre-push.sh` (prepush.log): rc 0, "pre-push parity check passed".
- `flowctl gate classify` exited 1 (FULL), so the focused commands above ran and no GATE_SKIPPED line applies.
- Mutation M4 (mutation-m4.log): a failed cut that clips the pauses anyway. `testAFailedCutKeepsThePausesAsRecorded` caught it, and it was reverted.
- Measurement point: the AC filter run, the serial E2E rerun, the Quick run and pre-push ran on the full working tree before the split into two commits. Commit 2 restored that tree byte for byte from a backup copy. The focused run and lint ran again on the committed tree.
- Not run:
  - CI's `swiftlint analyze` (`unused_declaration`), because it needs a clean `xcodebuild build-for-testing`. Every new declaration has a reference.
  - The App Store variant build (`pre-push.sh --with-appstore`). No `#if APPSTORE` code was touched.
  - The audiotap Quick command, because this task changed nothing under tools/audiotap.
- Line caps: `WatchLoop.swift` 590 to 591 lines, `PipelineController.swift` 584 to 585 lines (cap 600 for both).

### Tests by acceptance criterion

1. `keptSeconds` is covered by `RecordingCutTests.testTheCutPointLeavesOutThePausedTime`, written first and red on the unadapted conversion. Start 0, cut 10, stop 130.

   | Pause or pauses | Mix | Kept | Shows |
   |---|---|---|---|
   | 2-5 s | none | 7 | before the cut, lowers the start estimate |
   | 50-80 s | 110 | 20 | between cut and stop, raises the end estimate |
   | 5-20 s | none and 115 | 5 | cut inside a pause, lands at the pause's position |
   | 2-5 s and 50-80 s | 107 | 17 | both together |

   The existing no-pause cases, the delayed-start one included, are unchanged and green.
2. `redirect` keeps `pauseOffsets`. The redirect test in `RecordingCutTests` sets `[2.5, 6]` and asserts them.
3. Cut recordings:
   - `WatchLoopPauseEndTests.testTheQuestionsCutLandsOnThePauseFreeTimelineAndClipsThePauses` has two rows. It checks track frames, `recording_cut kept_s=`, the stored recovery resolution's `keptSeconds` and the job's clipped pauses.
     - In the first row, the pause after the cut is dropped.
     - In the second row, the cut falls inside a pause, so the pause ends at the cut and the cut lands at its position.
   - `testASilenceStopOfAPausedManualRecordingCutsOnThePauseFreeTimeline` covers the long-silence path.
   - `testAFailedCutKeepsThePausesAsRecorded` covers the failed cut.
   - `testARecordOnlyCutRecordingsSidecarCarriesTheClippedPausesAndStopsAtTheCut` checks that the sidecar `stoppedAt` is the cut time and that the sidecar holds the clipped pauses.
4. Record-only sidecar:
   - `WatchLoopPauseEndTests.testARecordOnlySidecarCarriesThePausesUnderTheNewVersion` checks raw JSON `version` 3, a `pauses` key only when paused, and the decoded pauses.
   - `RecordingSidecarTests.test_encode_writesPausesOnlyWhenThereAreSome` checks the `startedAt`/`endedAt` ISO 8601 strings and `offsetSeconds`.
   - `RecordingSidecarTests.test_read_v2SidecarWithoutPauses_decodesEveryOtherField` covers a v2 sidecar.
   - The existing version assertion moved from 2 to 3, and the future-version fixture from 3 to 4.
5. Reimport: `PipelineControllerTests.testPairedReimportCarriesTheSidecarsPauses` has a paused row and an unpaused row through `enqueueFiles`.
6. AC filter: see Gates, with the 5 environmental failures and the green serial rerun recorded.
7. Lint and line caps: see Gates.

### Decisions:

- D-a (rule 1, spec A9 and the FORBIDDEN surface): `keptSeconds` takes `pauses: [RecordingPause] = []`.
  - Effect: the crash-recovery cut (`RecoveredCut` / `PendingRecordingCut`) calls it without pauses and keeps its wall-clock conversion.
  - Alternative: a required parameter. That would have changed the recovery call sites and extended the recovery cut, which A9 rules out.
  - The live cut records its pause-adjusted `keptSeconds` in the pending cut resolution, so a crash after that store applies the same cut.
  - Switch point: `RecordingCut.swift:keptSeconds`.
  - Tests: `testTheCutPointLeavesOutThePausedTime`, the `recordPendingCutResolution` assertion in the question-cut test, and the Quick run's recovery tests.
- D-b (rule 6): a `StoppedRecording = (recording:, pauses:)` typealias is `cutBack`'s input and output, which keeps `cutBack` at 5 parameters.
  - Alternatives: a sixth parameter with a suppression, or a new struct.
  - Switch point: `WatchLoop+MeetingEnd.swift:StoppedRecording` / `cutBack`.
  - Tests: the three cut tests in `WatchLoopPauseEndTests`.
- D-c (rule 1, AC 3): only a successful cut clips the pauses. A failed cut returns them as recorded, both on the generic failure and when it rolls back to the uncut tracks, because the tracks then stay uncut.
  - Switch point: `cutBack`.
  - Test: `testAFailedCutKeepsThePausesAsRecorded`, which caught mutation M4.
- D-d (rule 1, AC 3): `recordedUntil`, which becomes the sidecar's `stoppedAt`, stays the wall-clock cut time. The pauses do not shorten it.
  - Switch point: `cutBack` / `recordedUntil`.
  - Test: `testARecordOnlyCutRecordingsSidecarCarriesTheClippedPausesAndStopsAtTheCut`.
- D-e (rule 6): `writeRecordOnlySidecar` takes `pauses` with no default, under a `function_parameter_count` suppression with a reason comment. The precedent is `SilencePromptPolicy.step`.
  - Alternatives: pass the `StoppedRecording` tuple, or default the parameter to `[]`. A default would let a caller drop the pauses silently.
  - Switch point: `WatchLoop+RecordOnly.swift:writeRecordOnlySidecar`.
  - Test: `testARecordOnlySidecarCarriesThePausesUnderTheNewVersion`.
- D-f (rule 1 for the format, settled by the task; rule 6 for the shape):
  - The init parameter `pauses: [RecordingPause] = []` comes last.
  - The stored value is nil when empty, so synthesized encoding omits the key.
  - Dates use the sidecar encoder's ISO 8601 strategy.
  - Alternative: always write `"pauses": []`, which the AC rules out ("an unpaused one has no `pauses` key").
  - Switch point: `RecordingSidecar.init`.
  - Test: `test_encode_writesPausesOnlyWhenThereAreSome`.
- D-g (rule 5): `pauses` decodes as a plain optional. A sidecar whose `pauses` value is present but malformed fails to decode as a whole, because `RecordingSidecar.read` is a `try?`, so a reimport then runs without the sidecar.
  - Only this app writes the field, so the case needs a hand edit or a future change to `RecordingPause`'s shape.
  - Alternative: a lenient custom decode, like `triggerRaw`, that drops only the bad `pauses`.
  - Switch point: `RecordingSidecar.pauses` decoding.
  - Test: `test_read_v2SidecarWithoutPauses_decodesEveryOtherField` covers the absent case. The malformed case has no test.
- D-h (rule 6): the `takeRecordingPauses` doc (`WatchLoop+Pause.swift`) and the `stopManualCapture` doc (`WatchLoop+SilencePrompt.swift`) now say the cut places its cut point with the pauses and clips them there. They replace the stale reason left by task .4. Doc text only, no test.
- D-i (rule 6): two commits. One is the cut on the pause-free timeline. The other is the sidecar and reimport, which depends on the first. Each commit's tree passed the focused tests and lint (c1.log, lint-c1.log, final-focused.log, final-lint.log).

### Follow-ups (outside this task's Touches, not filed by the worker)

- The `CLAUDE.md` Record-only note still reads `RecordingSidecar.currentVersion = 2` and lists the fields without `pauses`. This worker may not edit `CLAUDE.md`.
- `docs/architecture-macos.md` describes the sidecar without `pauses` (about line 419). It is outside Touches, and the sibling task .6 owns docs.
- D-g's lenient decode, if the conductor wants a malformed `pauses` value to cost only the pauses.

### Notes for the conductor

- Every changed file is inside the declared Touches:
  - `RecordingCut.swift`, `RecordingSidecar.swift`, `PipelineController.swift`
  - `WatchLoop.swift`, `WatchLoop+MeetingEnd.swift`, `WatchLoop+SilencePrompt.swift`, `WatchLoop+Pause.swift`, `WatchLoop+RecordOnly.swift`
  - `RecordingCutTests.swift`, `RecordingSidecarTests.swift`, `PipelineControllerTests.swift`, the new `WatchLoopPauseEndTests.swift`
- No route to a mapped feature changed.
- Integration overlap with task .6: none in source files. Task .6 edits `WatchingController*` and the docs, and this task touches neither.

### Review and integration (conductor)

stage: impl-review - ran [codex gpt-6-astra xhigh; round 1: three draws (correctness, contracts, integration) all SHIP, 0 findings; no fix pass]

Integrated onto feat/gh-46-pause-recording as abefd90c, 659c699e (lane commits 06cbc34c, f06a7a29), base d60ca904. Focused integrated verify at 659c699e: task AC filter plus the recovery-cut classes 329 tests with 3 environmental WatchLoopE2E failures (fresh scratch home without a model) that pass 8/8 in a serial rerun with a complete model; lint exit 0.

Conductor decisions on the worker's report: D-g (plain optional decode of the sidecar's pauses; a malformed value drops the whole sidecar on reimport) is a rule-5 assumption recorded as A16; D-a (keptSeconds pauses default [] so gh-60's recovery cut keeps its wall-clock conversion, spec A9, rule 1), D-c, D-d, D-f (rule 1), D-b, D-e, D-h, D-i (rule 6) accepted.

Follow-ups outside this task's Touches (listed in the spec's work summary): the CLAUDE.md Record-only note still says RecordingSidecar.currentVersion = 2 and lists the fields without pauses (CLAUDE.md edits need the owner's agreement in this fork); docs/architecture-macos.md describes the sidecar without pauses; a lenient decode for a malformed pauses value (A16 alternative B).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: abefd90cf6a967f10dbfdf6aba09dff13f7cac56, 659c699e53d4915d1cabded0ebb00d45ae0a7aa8
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/gh46-home-c5 swift test --parallel --filter 'RecordingCut|MeetingEnd|WatchLoop|RecordingSidecar|RecordOnly|PipelineController|WatchingControllerRecordOnly|RecoveredCut|PendingRecordingCut|RecordingPause' (integrated head 659c699e: 329 tests, 3 failed, all WatchLoopE2ETests under a fresh scratch home without a WhisperKit model), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/gh46-home-t2b swift test --filter 'WatchLoopE2ETests' (flaky-gate rerun, serial, scratch home with a complete model: exit 0, 8 tests, 0 failures), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (integrated head 659c699e: exit 0, 0 violations in 801 files), worker at lane head f06a7a29 (same tree): red-first run, every new test failed for its stated reason; focused 116 tests exit 0; task AC filter 303 tests with the 5 environmental E2E failures, serial rerun 8/8; spec Quick filter plus RecoveredCut|PendingRecordingCut|AppStateTests 387 tests exit 0; lint exit 0; pre-push exit 0; mutation M4 (a failed cut clipping anyway) caught by testAFailedCutKeepsThePausesAsRecorded, review: codex gpt-6-astra xhigh, round 1 three draws (correctness, contracts, integration) all SHIP, 0 findings (receipt /tmp/impl-review-receipt-d1afe3212e3b-gh-46-pause-and-resume-a-recording.5.json), cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'RecordingCut|MeetingEnd|WatchLoop|RecordingSidecar|RecordOnly|PipelineController|WatchingControllerRecordOnly', ./scripts/lint.sh
- PRs: