---
satisfies: [R1, R2, R3, R4]
---
# gh-124-retry-the-microphone-check-before.1 Implement Retry the microphone check before calling it broken

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
The microphone health check now retries a failed probe once after a 2 s pause and reports the microphone as broken only when the retry fails too, so a transient "try again" refusal from the audio system right after launch no longer posts the false "Permission Problem" notice; each failed attempt writes its failure kind to the unified log.

Tier: implementer (explicit invocation: opus at xhigh) (model: claude-opus-5-5)

stage: impl-review - ran [2026-10-14T09:40:14Z..2026-10-14T09:43:08Z] (codex gpt-6-astra xhigh, three draws correctness/contracts/integration, all SHIP, 0 findings; receipt /tmp/impl-review-receipt-d05befa0f1ef-gh-124-retry-the-microphone-check-before.1.json)

What changed:
- `PermissionHealthCheck.probeMicrophone()` returns `MicProbeOutcome` (`.delivered` / `.failed(MicProbeFailure)`), one failure kind per branch: no-input-device, invalid-format, tap-install-failed, engine-start-failed, no-buffer-before-timeout.
- `checkMicrophoneLive(authStatus:probe:sleep:logFailure:)` (new file `app/MeetingTranscriber/Sources/PermissionHealthCheck+MicrophoneRetry.swift`) runs the probe, and on failure logs it, pauses `micProbeRetryPause` (2.0 s, `Task.sleep`, never blocks a thread) and probes once more. `runLive()` is unchanged, so launch, activation and uncached checks all get the retry; cached readers see the retried verdict. Notification text, dedup and check scheduling unchanged.
- Each failed attempt: `logger.notice("Microphone probe attempt N of 2 failed: <kind>")`, subsystem com.meetingtranscriber, category PermissionHealthCheck, kind public.

Tests (app/MeetingTranscriber/Tests/PermissionsControllerTests.swift, all through `PermissionsController.check()` with the real `checkMicrophoneLive` and a scripted probe on a virtual clock):
- R1 `testMicProbeRecoveringOnRetryIsHealthyAndPostsNothing` (all five failure kinds: healthy, no notification, two probes, one 2 s pause)
- R2 `testMicProbeFailingOnRetryTooIsBrokenAndNotifiesOnce` (broken, exactly one "Permission Problem" with today's text)
- R3 `testMicProbeDeliveringFirstTimeIsNotRetried` (one probe, no pause)
- R4 `testEachFailedMicProbeAttemptIsLoggedWithItsKind` (one log entry per failed attempt with its own kind, every kind at both attempts; tokens distinct)

Verification (measured):
- baseline: green (focused Quick command, 59 tests, rc 0, before any edit)
- base observation: with the outcome seam but no retry, R1/R2/R4 failed exactly as the defect (first failure -> microphone .broken + "Permission Problem" posted, one probe, no pause); R3 passed
- head: focused Quick command, 63 tests, rc 0 (/private/tmp/mt-gh124-focused.log)
- lint: ./scripts/lint.sh with pinned SwiftFormat/SwiftLint, rc 0
- CI analyzer reproduced locally (clean xcodebuild build-for-testing + swiftlint analyze --strict): no finding in the changed files; 2 pre-existing findings elsewhere (follow-up 1)
- unified log: a throwaway test (not committed) called the default log writer for each kind; `log show` showed all five lines at default level with the kind readable
- not run: ./scripts/pre-push.sh release-build parity; live app run (installed app must not be restarted, and the error-35 refusal cannot be triggered on demand)

Defect route:
- prior fixes: none. git log on PermissionHealthCheck.swift / PermissionsController.swift (last mic change 1f7038b1, buffer flow); open fork PRs #115 #116 #117 and upstream PR #713 touch no permission file; memory bug track has no match; issue search finds only #124 itself
- diagnosis: eliminated a genuinely broken grant (every later check in the same run healthy, the next call recorded a normal mic track, per the spec's system-log diagnosis); confirmed a transient engine-start refusal (HALC StartIO error 35, about 3 s after launch) counted as broken with no retry (system log, both launches, in the spec)
- introduced by: skipped: no known-good revision
- base: bf27a994 + outcome seam without retry: R1/R2/R4 red (false notice posted) | head: 7e3e1bbe: 63/63 focused tests green
- live: not run: installed app must not be restarted; the refusal cannot be provoked on demand

In-task choices (for the spec's Decision Context):
- A5 · failed attempts log at notice (default) level, which is retained and reaches the persistent log stream · flip at: PermissionHealthCheck.logMicProbeFailure · alternative: warning level
- A6 · only the failure kind is logged, not the underlying error code (e.g. 35) · flip at: MicProbeFailure / logMicProbeFailure · alternative: carry the NSError code on tap-install and engine-start failures and log it
- A7 · the live microphone check and its retry live in a new file PermissionHealthCheck+MicrophoneRetry.swift, because PermissionHealthCheck.swift passed the 600-line lint cap · flip at: the file split · alternative: trim existing doc comments in the main file
- A8 · the AC tests sit in PermissionsControllerTests and drive the check through PermissionsController.check(), since PermissionHealthCheckTests is near the 400-line type-body cap and a new class would miss the spec's Quick-command filter · flip at: test placement · alternative: a new test class plus a widened filter
- A9 · the log sink is an injected closure; the real unified-log write was checked by hand with log show, not by a committed test · flip at: checkMicrophoneLive(logFailure:) · alternative: an OSLogStore-reading unit test (slower, may be flaky on runners)

Follow-ups (found, not part of this task):
1. swiftlint analyze --strict reports 2 unused_declaration findings in app/MeetingTranscriber/Sources/RecordingProvider.swift:144 and :146 (the no-op storePendingCut / recordPendingCutResolution defaults). Not touched by this change; inferred pre-existing, not measured on base. CI's analyze job would fail on them once fork CI runs.
2. ViewInspectorIdentifierTests.swift:45/53/64 print "call to main actor-isolated initializer in a synchronous nonisolated context" warnings whenever the test target recompiles. Pre-existing file, not touched.
3. PermissionsController.swift comments still call the probe "~500 ms"; true for a healthy check, but a check whose first attempt fails now takes about 3 s.

Feature map: no change to how a user reaches any feature.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 7e3e1bbe75743825408ee71f02e85b9fd5a542ac
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh124-home swift test --parallel --filter 'PermissionHealthCheckTests|PermissionsControllerTests|PermissionsControllerNotificationTests' (63 tests, rc 0), ./scripts/lint.sh (pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1, rc 0)
- PRs: