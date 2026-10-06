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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
