---
satisfies: [R3]
---
# gh-105-watching-pauses-during-a-recording-and.1 List the meetings signalling now and hold them when a watch loop is started by a resume

## Description
The detector side of R3 plus the loop entry point the resume (task .2) calls. A read-only detector query lists every watched app identity whose call signal is present right now, without confirmation and without touching detection state; a watch loop can then hold all of them before it starts. Proves the approach (spec Early proof point) before any controller wiring.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/MeetingDetecting.swift`, `app/MeetingTranscriber/Sources/PowerAssertionDetector.swift`, `app/MeetingTranscriber/Sources/MicInputDetector.swift` (incl. `CompositeMeetingDetector`), new `app/MeetingTranscriber/Sources/WatchLoop+ResumeHold.swift`, new `app/MeetingTranscriber/Tests/SignallingMeetingsTests.swift`, new `app/MeetingTranscriber/Tests/WatchLoopResumeHoldTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/MeetingDetecting.swift, app/MeetingTranscriber/Sources/PowerAssertionDetector.swift, app/MeetingTranscriber/Sources/MicInputDetector.swift, app/MeetingTranscriber/Sources/WatchLoop+ResumeHold.swift, app/MeetingTranscriber/Tests/SignallingMeetingsTests.swift, app/MeetingTranscriber/Tests/WatchLoopResumeHoldTests.swift]

### Approach
- `MeetingDetecting` (`MeetingDetecting.swift:28-44`): add `func signallingMeetings() -> [DetectedMeeting]` with a doc comment stating the contract (spec Architecture, "Which calls are skipped"). The protocol extension (`:46-60`) gives a default `[]` for detectors that cannot enumerate (test doubles and the window-title `MeetingDetector`, which is not the production detector); say so in its comment.
- `PowerAssertionDetector`: implement it from the same per-assertion matching as `checkOnce(excluding:)` (`PowerAssertionDetector.swift:246-310`): same `identityKey`, same denied-identity skip, same `matchAssertion` (which carries the native-process exclusion for the browser pattern), one entry per identity key, and the `DetectedMeeting` built exactly as `checkOnce` builds it (`meetingIdentity(pattern:processName:)` at `:325`, `lookupWindowTitle ?? placeholderTitle`, `ownerName`, `windowPID`). Ignore cooldowns (a meeting in cooldown still signals and is held). Do NOT touch `consecutiveHits`, `cooldownUntil` or `logUnmatchedWatchedAssertions`. Prefer extracting the shared matching into one private helper both methods call over a second copy of the loop.
- `MicInputDetector`: same for `checkOnce(excluding:)` (`MicInputDetector.swift:159-205`): empty pattern set returns `[]` without enumerating; skip denied identities; no `logUnmatchedRunningInput`; build the meeting as `checkOnce` does (`tapRootPID`, matcher title or placeholder).
- `CompositeMeetingDetector` (`MicInputDetector.swift:351-382`): union of its detectors' lists, first entry per `pattern.identityKey` kept (the per-browser identity, never the "Browser Meetings" category name; since gh-52 two added apps can share an `appName` and differ in `identityKey`). The shared matching in `PowerAssertionDetector.checkOnce` (now `:266-340`) also skips `isAddedAppHit` hits (`:509`) and goes through `matchAssertion` as a wrapper over the static `matches` (`:477`, `:499`); the helper carries both.
- New `WatchLoop+ResumeHold.swift` (`WatchLoop.swift` is at 599 of the 600 lines lint allows; do not grow it): `func holdSignallingMeetings()` calls gh-94's `holdRedetection(of:)` (`WatchLoop+RedetectionHold.swift:25-29`, which logs `redetect_hold_set app=<app>`) for each meeting in `detector.signallingMeetings()`, then writes one `diagnostics.notice("watch_resumed_after_manual_recording held=<n>")` line (R7; no app names in it). Called on a loop before `start()`: `start()` (`WatchLoop.swift:198-211`) does not clear holds, `stop()` does (`:221`).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/PowerAssertionDetector.swift:240-380` — matching, identity, `isMeetingActive`
- `app/MeetingTranscriber/Sources/MicInputDetector.swift:150-215, 323-352` — mic detector and composite
- `app/MeetingTranscriber/Sources/WatchLoop+RedetectionHold.swift` and `app/MeetingTranscriber/Sources/RedetectionHolds.swift` — gh-94's hold
- `app/MeetingTranscriber/Sources/WatchLoop.swift:330-350` — poll order: holds released first, then `checkOnce(excluding:)` with held apps

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/PowerAssertionFixture.swift`, `PowerAssertionDetectorIdentityTests.swift`, `MicInputDetectorTests.swift`, `CompositeMeetingDetectorTests.swift` — injected providers to copy
- `app/MeetingTranscriber/Tests/WatchLoopStopByHandTests.swift:400-470` — hold tests through `start()` with a scripted detector

### Key context
- A meeting needs `confirmationCount` (2) consecutive polls before `checkOnce` returns it, and a poll returns one meeting; that is why the snapshot is a separate query (spec A5).
- Browser meetings: the hold key must be the synthesised per-process identity, or two browsers collapse into one hold and the second records at once.

## Acceptance
- [ ] `SignallingMeetingsTests`: `PowerAssertionDetector` lists every matching identity on the first call (no confirmation needed), one entry per identity, with the same `pattern.appName`/`windowPID` a confirmed `checkOnce` would return for it; two browsers give two entries; a deny-listed identity and a native app's process under the browser pattern give none; after the call, two `checkOnce()` polls still need the usual count to confirm (counters untouched) and an identity in cooldown is still listed.
- [ ] `MicInputDetector`: lists each watched app holding the mic; empty pattern set returns `[]`; deny-listed skipped. `CompositeMeetingDetector` returns the union, deduplicated by identity.
- [ ] `WatchLoopResumeHoldTests` (TestClock or short real polls, scripted detector): a loop given `holdSignallingMeetings()` before `start()` neither records nor asks about a meeting that keeps signalling; once its signal is absent for one poll and comes back, it is recorded (or asked about) as usual; a meeting that starts signalling only after the start is recorded as usual; the diagnostic sink got `redetect_hold_set` per held app and one `watch_resumed_after_manual_recording held=<n>` line with the right count.
- [ ] Existing detector, hold and stop-by-hand suites pass unchanged.
- [ ] Focused run green, read from the log file: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh105-home swift test --parallel --filter "SignallingMeetings|WatchLoopResumeHold|PowerAssertionDetector|MicInputDetector|CompositeMeetingDetector|RedetectionHolds|WatchLoopStopByHand" > /private/tmp/mt-gh105-t1.log 2>&1; echo "exit=$?"` (never pipe the run into tail/head/grep).
- [ ] `PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh` reports 0 violations.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
