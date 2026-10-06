---
satisfies: [R7, R8]
---
# gh-52-keep-added-apps-apart-from-same-named.3 Keep added apps out of the browser-meeting path

## Description
Keep an added app out of the browser-meeting path, so one call in an added Electron app is detected once, through the microphone, and one answer covers it (spec §Architecture "An added app is never also a browser meeting", A5; R7). Split from .1 because it is a separate mechanism in the assertion detector and its wiring; it depends on .1 because both edit `PowerAssertionDetector.isMeetingActive`.

**Size:** S
**Files:** `app/MeetingTranscriber/Sources/PowerAssertionDetector.swift`, `Sources/WatchingController+Detectors.swift`, new `Tests/PowerAssertionDetectorAddedAppTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/PowerAssertionDetector.swift, app/MeetingTranscriber/Sources/WatchingController+Detectors.swift, app/MeetingTranscriber/Tests/PowerAssertionDetectorAddedAppTests.swift]

### Approach
Tests first (contract known up front), then implement.

1. `Sources/PowerAssertionDetector.swift`: add `var addedAppBundleIDs: [String] = []` and `var bundleIDForPID: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }` beside the other injectable closures (`:192-211`; this needs `import AppKit`, as `MicInputDetector.swift:1` has). A private helper decides whether a PID belongs to an added app: false at once when `addedAppBundleIDs` is empty; otherwise look the bundle ID up and match it exactly or as `<bundleID>.<anything>`, the rule `MicInputDetector.MicPattern.matches(bundleID:)` applies with `matchesHelpers` (`Sources/MicInputDetector.swift:40-42`); a nil bundle ID is not an added app.
2. In `checkOnce(excluding:)` (`:251-282`): for a process-open pattern (`pattern.processNames.isEmpty`), once `matchAssertion` has returned true and before anything is counted, skip the assertion when its PID belongs to an added app. Same rule in `isMeetingActive` (`:355-378`; iterate `(pid, pidAssertions)` there). The lookup therefore only runs for a WebRTC-keyword hit with a non-empty added list.
3. Leave the static `matches(...)`, `claimedProcesses` and the unmatched-assertion diagnostic (`PowerAssertionDetector+Diagnostics.swift`) unchanged: they are pure and name-based. Add a doc comment next to the new properties saying why (spec A5) and how this differs from `claimedProcesses` (`:422-439`: by bundle ID, from the user's list, so removing an app from the list gives today's behaviour back).
4. `Sources/WatchingController+Detectors.swift:20-28`: set `assertions.addedAppBundleIDs = settings.watchCustomApps`, read at each watch start like the mic patterns.

### Tests
New `Tests/PowerAssertionDetectorAddedAppTests.swift`, using `PowerAssertionFixture.browserDetector()` and `PowerAssertionFixture.assertions(...)` with `PowerAssertionFixture.webRTC`:
- With `addedAppBundleIDs = ["com.example.slack"]` and `bundleIDForPID` mapping 7 → `com.example.slack`, 9 → `com.example.slack.helper`, anything else → nil: assertions from PID 7 ("Slack") and PID 9 ("Slack Helper") are never detected; PID 8 ("Brave Browser") still is; a PID resolving to nil still is.
- With an empty `addedAppBundleIDs`, PID 7's assertion is detected as "Slack" (today's behaviour) and `bundleIDForPID` is never called (count calls).
- A browser meeting synthesised for "Slack" (`PowerAssertionDetector.meetingIdentity`) is not kept active by PID 7's assertion while Slack is in the added list.
- Native patterns are unaffected: with the added list set, a `zoom.us` "Zoom call" assertion still detects Zoom.
- Wiring, like `Tests/MicInputDetectorTests.swift:253-276`: an `AppSettings` over a throwaway defaults suite with `watchBrowserMeetings = true` and `watchCustomApps = ["com.example.slack"]`; take the `PowerAssertionDetector` out of `WatchingController.defaultDetectors(settings:)`, inject `bundleIDForPID` and `assertionProvider`, and PID 7 is not detected; with `watchCustomApps = []` it is.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/PowerAssertionDetector.swift:183-312, 355-378, 422-477` — state, `checkOnce`, `isMeetingActive`, claimed processes and matching
- `app/MeetingTranscriber/Sources/WatchingController+Detectors.swift` — detector wiring
- `app/MeetingTranscriber/Tests/PowerAssertionFixture.swift` — fixtures

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/PowerAssertionDetectorOpenMatchingTests.swift` — open-matching test style
- `app/MeetingTranscriber/Tests/MicInputDetectorTests.swift:253-276` — wiring test through `defaultDetectors`

### Key context
- Measured at plan time: an Electron app's power assertion is held by its main process, and `NSRunningApplication(processIdentifier:)` returns its bundle ID; daemons return nil (spec §Resolved via Research).
- `PowerAssertionDetector.swift` is 528 lines; stay under 600 (strict lint).
- Commit messages for the original's readers: no fork issue numbers or `gh-`/`fn-` ids; Conventional Commits; stage files explicitly.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<your scratch>/home swift test --parallel --skip WatchLoopE2ETests --filter "PowerAssertionDetector|MeetingDetectorExclusion|CompositeMeetingDetector|MicInputDetector|WatchingController|WatchLoop" > /private/tmp/<your scratch>/t3-tests.log 2>&1` and read the log.
- `./scripts/lint.sh` with the pinned tools fetched per `scripts/tool-versions.sh` (`PATH="<that dir>:$PATH"`); do not `brew install`.
- Run `swift build -c release` in `app/MeetingTranscriber` once (release mode catches Sendable diagnostics debug tolerates).

## Acceptance
- [ ] While an app's bundle ID is in `watchCustomApps`, a WebRTC assertion from its process (or a `<bundleID>.*` helper) is neither detected nor counted as keeping a browser meeting alive; other browsers and native apps are detected as before (R7, R8).
- [ ] With no added apps the browser path behaves exactly as today and performs no bundle lookup.
- [ ] `WatchingController.defaultDetectors` passes `settings.watchCustomApps` to the assertion detector, proven by the wiring test.
- [ ] Every existing `PowerAssertionDetector*` test passes unchanged; the verification filter passes and `swift build -c release` is clean.
- [ ] `./scripts/lint.sh` passes with the pinned tools.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
