---
satisfies: [R4, R5, R6, R7]
---
# gh-105-watching-pauses-during-a-recording-and.3 Automation API: cancel the resume on stop, answer after it, and document the behaviour

## Description
The automation API part (R4, R5) and the docs for the whole spec. A `/v1/watch` stop during a manual recording cancels the pending resume; `/v1/record` stop and failed start answer after the resume ran; the old API-only restore after a failed microphone start is removed in favour of task .2's resume (spec A3, A6).

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchingController+WatchControl.swift`, `app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift`, `app/MeetingTranscriber/Tests/WatchingControllerResumeWatchingTests.swift`, `app/MeetingTranscriber/Tests/WatchingControllerRecordControlTests.swift`, `docs/automation-api.md`, `docs/stream-deck.md`, `docs/architecture-macos.md`
**Touches:** [app/MeetingTranscriber/Sources/WatchingController+WatchControl.swift, app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift, app/MeetingTranscriber/Tests/WatchingControllerResumeWatchingTests.swift, app/MeetingTranscriber/Tests/WatchingControllerRecordControlTests.swift, docs/automation-api.md, docs/stream-deck.md, docs/architecture-macos.md]

### Approach
- `stopWatching()` (`WatchingController+WatchControl.swift:47-52`): clear the pending resume BEFORE the `isWatching` guard, so a stop during a manual recording (which returns `.unchanged`) cancels it; write one diagnostic line `watch_resume_cancelled` when there was one to cancel (R7, same log path as task .2's failure line). `start` and a `toggle` resolving to a start keep returning `.blocked` (409) during a manual recording.
- `applyRecordStart` (`WatchingController+RecordControl.swift:73-95`): remove `rearmWatching` (`:97-106`) and its two calls; task .2's failed-start resume covers it. Await `joinResume()` before returning `.refused`/`.failed`, so the answer arrives with watching already back.
- `applyRecordStop` (`:115-120`) and `applyRecordStopAny` (`:130-140`): when they stopped a manual recording, await `joinResume()` before answering. `applyRecordStop` is synchronous today; make it `async` only if needed and keep the outcome mapping and codes unchanged.
- Docs: `docs/automation-api.md` `/v1/watch` section (`:230-273`, the 200 bullet at `:258-261`): watching resumes after a manual recording when it was on before; a `stop` sent during the recording cancels that and still answers 200. `/v1/record` (`:305-340`): stop and failed start answer once watching is back. `docs/stream-deck.md` (`:126-175`): the same two facts where stop-watching keys are described. `docs/architecture-macos.md`: rows for `WatchLoop+ResumeHold.swift` beside the WatchLoop rows (`:136-139`) and `WatchingController+ResumeWatching.swift` beside the other `WatchingController+…` rows (`:213-217`). Do not edit `CLAUDE.md` or `AGENTS.md` (fork rule).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift` — start/stop outcomes and the rearm
- `app/MeetingTranscriber/Sources/WatchingController+WatchControl.swift`
- `app/MeetingTranscriber/Tests/WatchingControllerRecordControlTests.swift:150-200` — `testARefusedStartPutsMeetingWatchingBack` and neighbours
- `docs/automation-api.md:230-340`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/DebugRPCServerIntegrationTests.swift:1108-1210` — `/v1/watch` route tests (closure-injected; they need no change)

### Key context
- The `/v1/watch` route tests inject closures and never reach the real controller, so the cancel behaviour is pinned in controller tests, not there.

## Acceptance
- [ ] Controller tests: watching on, manual recording running, `stopWatching()` returns `.unchanged`; after the recording ends, `isWatching` stays false and `watch_resume_cancelled` was logged once. Without the stop, it resumes (task .2 behaviour unchanged).
- [ ] `startWatching()` during a manual recording still returns `.blocked`.
- [ ] `applyRecordAction(.stop)` of a microphone-only recording and `applyRecordStopAny()` of a manual app recording return their usual outcomes with `isWatching` already true when they return (watching was on before).
- [ ] `WatchingControllerRecordControlTests`: the refused/failed-start cases still end with watching back on when the call returns, now through the shared resume; no `rearmWatching` remains (`grep -rn rearmWatching app/MeetingTranscriber/Sources` finds nothing). Any test changed is named in the done summary with the reason (changed mechanism, A3).
- [ ] Docs updated as listed; `DebugRPCServerIntegrationTests` pass unchanged.
- [ ] Focused run green, read from the log file: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "WatchingController|DebugRPCServerIntegration" > /private/tmp/mt-gh105-t3.log 2>&1; echo "exit=$?"`.
- [ ] Lint 0 violations, and `./scripts/pre-push.sh --with-appstore` is clean.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
