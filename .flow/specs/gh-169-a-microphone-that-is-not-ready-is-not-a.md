# A microphone that is not ready is not a broken permission

## Conversation Evidence

> owner (paraphrased, 2026-10-20): why does the app believe all the time that there is no microphone input? (screenshot: the menu bar icon carries the red warning badge)
> issue #169: the badge stayed for three days after one failed check about three minutes after a wake from sleep; both probe attempts logged an invalid input format (0 Hz, 0 channels); the check runs only at launch and when the app is activated; every probe failure counts as a broken grant.

## Goal & Context

<!-- Source: 50% issue #169 / 20% [paraphrase] / 30% [inferred] -->

The permission health check tests the microphone grant by opening the microphone for about half a second. When that test fails while the system reports the grant as allowed, the app calls the grant "broken": the menu bar icon gets the red warning badge, and a "Permission Problem" notification tells the user to toggle the microphone permission off and on in System Settings.

Once the test failed about three minutes after the Mac woke from sleep, because the input device reported no usable audio format yet (0 Hz, 0 channels). Both attempts failed the same way, the retry from #124 included. The grant was fine: bringing the app to the front three days later ran the check again and it passed at once. Until then the badge stayed, because the check runs again only at launch and when one of the app's windows comes to the front, which a menu bar app rarely does. The owner read the badge as "the app thinks there is no microphone input". [paraphrase]

So two things are wrong: a device that is not ready is reported as a broken grant, and nothing clears a false verdict without a click. The advice the notification gives (toggle the permission) cannot help in that case.

Who it is for: everyone who keeps the app running across sleep. Why now: the false badge and its advice sent the owner looking for a microphone problem that did not exist.

Upstream check (2026-10-20): the original project has no open issue or pull request about this. Its closed issue on the health check (a log line "Health Check Failed") is a different problem.

## Architecture & Data Models

<!-- Source: 30% issue #169 / 70% [inferred] -->

- The microphone verdict distinguishes failures that say something about the grant from failures that only say the device is not ready. A missing input device and an input device without a usable format (zero sample rate or zero channels) belong to the second kind. An allowed grant whose probe delivers no buffer at all before the timeout stays the signature of a broken grant. [inferred]
- A probe that fails only for device reasons gives an inconclusive answer, and an inconclusive answer counts as healthy, the way the Accessibility probe already treats an inconclusive answer. The raw reason is still logged. [inferred]
- The permission check gains two more triggers besides launch and activation: a wake from sleep and a change of the system default input device. Both run the same check as activation does, with the same debounce. [paraphrase]
- **One check at a time.** Today's debounce stamps its time only when a check finishes, so it does not stop a second check from starting while the first one is still probing (the probe plus its retry take over 2 s). Events that arrive while a check runs are folded into at most one follow-up check, which starts after the running one has finished. A result is applied only by the check that is the latest one started, so an older failing check can never overwrite a newer passing one. [inferred]
- No trigger runs the check while a recording is capturing: the probe opens the microphone a second time, and opening an input can switch a Bluetooth headset out of its music profile underneath the recording. A trigger that arrives during a recording runs once the recording has stopped. "Capturing" means the capture is still running, including a capture that still finishes after Stop Watching has already reset the menu's state; the app's existing recording-activity signal (`WatchingController.isRecordingActivity`) already answers exactly that, so the check reads it rather than a second notion of "recording". [inferred]
- **A running check yields to a recording that starts.** Before the probe's retry opens the microphone again, the check looks whether a recording started in the meantime. If so, it ends without a new verdict (the previous verdict stays) and one check is queued for after the recording. [inferred]

## API Contracts

<!-- Source: 100% [inferred] -->

- `/state.permissionHealth` keeps its fields. A microphone whose probe was inconclusive reports `healthy`, as it would after a passing probe. [inferred]

## Edge Cases & Constraints

<!-- Source: 100% [inferred] -->

- A Mac without any microphone (a Mac mini with nothing attached) no longer gets the badge for the microphone. [inferred]
- The system's own verdicts stay as they are: denied or restricted reports `denied`, not determined reports `notDetermined`; neither runs the probe. [inferred]
- A real broken grant (allowed, but the probe gets no buffer) is still reported after the existing retry, with the existing notification. [inferred]
- A wake or device change that fires many times in a row (a headset reconnecting) runs the check once per debounce window, not once per event, and never two checks at the same time. [inferred]
- A check that yields to a recording does not count as a completed check for the debounce, so the queued check after the recording is not skipped by it. [inferred]

## Acceptance Criteria

- **R1:** With the grant allowed, a microphone probe that fails because no input device exists or because the input device reports a zero sample rate or zero channels does not report the microphone as broken: the menu bar icon shows no warning badge for it and no "Permission Problem" notification is posted. The log line still names the reason. Errors: a probe that delivers no buffer before its timeout on both attempts still reports `broken` and notifies once, as today. [paraphrase]
- **R2:** A microphone verdict of `broken` is replaced by the next check's result without the user opening a window: the check runs again after the Mac wakes from sleep and after the system default input device changes. A passing check clears the badge. Errors: events closer together than the existing debounce run the check once; events that arrive while a check runs start at most one further check after it, never a second probe at the same time; a result from a check that is no longer the latest one started is discarded. [paraphrase]
- **R3:** No check started by a wake or input device change runs while a recording is capturing, and a check already running does not open the microphone again for its retry once a recording has started: it ends without a new verdict. In both cases one check runs after the capture has finished. Errors: a recording that stops and a new one that starts before the deferred check runs defer it again; a capture still finishing after Stop Watching counts as capturing. [inferred]
- **R4:** A test feeds the probe outcomes "invalid format on both attempts" and "no input device" through the live microphone check and asserts a healthy result with no notification. A second test fails the check once with "no buffer before timeout", then lets a wake trigger a passing check, and asserts that the badge input (`hasPermissionProblem`) goes back to false. A third test holds the first probe open, delivers a wake and two device changes, and asserts that only one probe runs at a time, that one follow-up check runs afterwards, and that a failing result from the held probe does not bring the badge back after a later passing check. A fourth test starts a recording while a check waits for its retry and asserts that no second probe runs, the previous verdict stays, and one check runs after the recording. All four fail on today's code. [inferred]

## Boundaries

- The Screen Recording and Accessibility checks are not changed. [inferred]
- No periodic timer re-runs the check. Wake and input device changes are the triggers. [inferred]
- The notification text for a real broken grant stays as it is. [inferred]
- No change to what the probe itself does (the half-second open, the retry after 2 s). [inferred]

## Decision Context

### Motivation

- **A1 · A probe failure that only shows a missing or not-ready input device counts as inconclusive and reports healthy.** flip at: the microphone verdict mapping · test: R4's first test · status: active [agent-inferred 2026-10-20]
- **A2 · Wake from sleep and a change of the default input device trigger a re-check; no periodic timer.** flip at: the permission check triggers · test: R4's second test · alternatives: a timer that re-runs the check every few minutes while a problem is shown (opens the microphone again and again in the background, and wake plus device change cover the observed case); clearing the badge when a recording's microphone track carries audio (ties two subsystems together for a case R1 already removes at its source) · status: active [agent-inferred 2026-10-20]
- **A3 · No re-check while a recording is capturing, and a running check yields before its retry; one check runs after the capture has finished.** flip at: the permission check triggers · test: R4's fourth test · status: active [agent-inferred 2026-10-20]
- **A4 · One check at a time: events during a running check fold into one follow-up check, and only the latest check's result is applied.** flip at: the permission check entry point · test: R4's third test · status: active [agent-inferred 2026-10-20]
- **A5 · When the two microphone probe attempts fail for different reasons, the retry's failure decides the verdict.** alternatives: B — any no-buffer attempt makes the grant broken; C — the first attempt decides · flip at: `PermissionHealthCheck+MicrophoneRetry.swift:probeWithOneRetry` · test: `PermissionsControllerTests.testAMicrophoneThatIsNotReadyIsNotReportedAsABrokenGrant` · status: active [agent-assumed 2026-10-20]
- **A6 · "Only the latest check's result is applied" holds by construction: checks run one at a time and apply in start order, with no generation id.** alternatives: B — a generation id per check, a result with a stale id discarded · flip at: `PermissionsController.swift:runOneCheck` · test: `PermissionsControllerRecheckTests.testEventsDuringARunningCheckFoldIntoOneFollowUpAndAStaleFailureCannotWin` · status: active [agent-assumed 2026-10-20]

FIT: GO · 2026-10-20 · base 5978abbf · engine flow-next 9.1.1 · gh-105 left the recording-activity signal and the permission check path unchanged; it only hides Stop Watching during a manual recording, detected recordings and the API still reach it
