# Retry the microphone check before calling it broken

## Conversation Evidence

> user (turn 1): "I got several notifications in my notification pane. Especially the microphone Permission problem seems to be a false message"
> user (turn 1, screenshot): two "Permission Problem" notices at 06:00 and 08:03, text "Microphone looks enabled but isn't working — toggle it off and on in System Settings"
> user (selected): "A — mic + menu now (Recommended)" (fix the false microphone notice now)
> issue #124 (filed from the diagnosis, 2026-10-14): "Retry the probe after a short delay when the engine start fails, and report broken only when the retry fails too" · "Add a test with an injected probe that fails once and then works, and check that no notification is posted"
> diagnosis 2026-10-14 (system log, both launches, about 3 s after start): "HALC_ProxyIOContext::_StartIO(): Start failed - StartAndWaitForState returned error 35", then the audio engine's start failed with error 35, then "Permission health check failed: microphone=broken" and the notification. Every later check in the same run (6 checks, 09:02 to 09:23) reported the microphone healthy, and the 09:01 Teams call recorded a normal microphone track.

## Goal & Context

The permission health check tells the user to toggle the microphone permission when the system says the permission is granted but a live probe cannot get audio from the microphone. On 2026-10-14 it raised that notice twice, each time right after the app restarted for an update, while the microphone worked. [paraphrase] The cause was a transient refusal from the audio system ("try again", error 35) when the probe started its audio engine about 3 s after launch; the check counts any probe failure as broken, retries nothing, and the per-process notification dedup does not survive a restart, so every launch can raise it again. [paraphrase]

A false notice is worse than none: it sends the user to System Settings for a toggle that changes nothing, and it teaches them to ignore the notice that matters when the grant really is broken. [inferred]

## Architecture & Data Models

- The microphone verdict is computed per check: system authorization first, then the live probe when authorization is granted. [paraphrase] The probe has several failure kinds today (no input device, an unusable input format, the tap failing to install, the engine failing to start, no buffer before the probe's timeout); all of them map to the same "broken" outcome. [paraphrase]
- The change owns one thing: the probe outcome that the verdict is built from. It becomes "first attempt, and when that fails, one more attempt after a short pause"; the verdict, the notification and its dedup stay as they are. [inferred]
- The probe's waiting already runs on injectable time (now and sleep are injected in tests); the retry pause uses the same seam so tests run on a virtual clock. [paraphrase]

## Edge Cases & Constraints

- The retry applies to every caller of the check (launch, app activation, the check before a manual recording, the automation state read), because they all share the probe. [inferred]
- The pause between the attempts is short (about 2 s) [inferred], so the worst case of a check stays a few seconds; a caller waiting on it (the check before a manual recording) waits that much longer only when the first attempt failed.
- Waiting must not block the main thread. [inferred]
- A persistent failure (a really broken grant, no input device at all) still ends as broken after the retry and posts the notice exactly as today. [inferred]
- The permission-health end-to-end lane (granted microphone on the runner, expects "healthy") keeps passing. [inferred]

## Acceptance Criteria

- **R1:** When the first microphone probe fails and the retry after the pause succeeds, the check reports the microphone as healthy and posts no "Permission Problem" notification. Errors: holds for every probe failure kind (no input device, unusable format, tap install failure, engine start failure, no buffer before the timeout). [paraphrase]
- **R2:** When both the first probe and the retry fail, the check reports the microphone as broken and the existing notification is posted once, as today (no error surface beyond today's notification and dedup). [inferred]
- **R3:** A probe that succeeds on its first attempt is not retried, so a healthy check takes no longer than today (no error surface beyond R1). [inferred]
- **R4:** Each failed attempt writes its failure kind to the unified log (not only to the per-process debug file, which the next process truncates), so a later report can tell a transient failure that recovered from a persistent one. Errors: no error surface beyond a log line. [inferred]

## Boundaries

- No change to the Screen Recording or Accessibility checks. [inferred]
- No persistent dedup of the notification across launches. [inferred]
- No change to the notification's text or to when the check runs. [inferred]

## Decision Context

- **D1 · Fix the false microphone notice now, in its own spec.** why: owner picked "A — mic + menu now (Recommended)" after the diagnosis · status: active [owner-ratified 2026-10-14]
- **A1 · One retry after a short pause, not "an engine-start failure counts as healthy".** flip at: the probe outcome that the microphone verdict is built from · test: the R2 test (both attempts fail, verdict broken, one notification) · alternatives: treat an engine-start failure as inconclusive and healthy, as the Accessibility check does, which would hide a grant that is really broken · status: active [agent-assumed 2026-10-14]
- **A2 · The retry sits in the probe outcome, not in a later first check at launch.** flip at: where the startup check is scheduled · test: the R1 test (first attempt fails, retry succeeds, no notification) · alternatives: delay the launch check, which only moves the race and leaves activation and pre-recording checks exposed · status: active [agent-assumed 2026-10-14]
- **A3 · The pause between the two attempts is about 2 s.** flip at: the retry pause value · test: the R1 test on the virtual clock · status: active [agent-assumed 2026-10-14]
- **A4 · Each failed attempt logs its failure kind to the unified log (R4).** flip at: the probe's failure log line · test: a test or review check that each failure kind produces its line · alternatives: keep the reason only in the per-process debug file, which the next process truncates · status: active [agent-assumed 2026-10-14]

## Quick commands

```bash
cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh124-home swift test --parallel --filter 'PermissionHealthCheckTests|PermissionsControllerTests|PermissionsControllerNotificationTests' > /private/tmp/mt-gh124-focused.log 2>&1; rc=$?; tail -5 /private/tmp/mt-gh124-focused.log; test "$rc" = 0
```

<!-- Source: 15% user / 35% [paraphrase] / 50% [inferred] -->
