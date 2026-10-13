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

1. `Sources/PowerAssertionDetector.swift`: add `var addedAppBundleIDs: [String] = []` and `var bundleIDForPID: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }` beside the other injectable closures (`:192-211`; this needs `import AppKit`, as `MicInputDetector.swift:1` has). A private helper decides whether a PID belongs to an added app: false at once when `addedAppBundleIDs` is empty; otherwise look the bundle ID up and match it exactly or as `<bundleID>.<anything>`, the rule `MicInputDetector.MicPattern.matchLength(bundleID:)` applies with `matchesHelpers` (a non-nil length means the process is that app or its helper); a nil bundle ID is not an added app.
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
With Browser Web Meetings on, a call in an app added through "Add App…" (a Slack huddle, say) now reaches the user as one prompt through the microphone path, so one Ignore or Never answers it. `PowerAssertionDetector` gained `addedAppBundleIDs` and an injectable `bundleIDForPID`. The browser (process-open) pattern skips a matched WebRTC assertion whose PID resolves to an added app or a `<bundleID>.*` helper, in `checkOnce(excluding:)` and in `isMeetingActive`. `WatchingController.defaultDetectors` passes `settings.watchCustomApps` at each watch start. Native patterns, the static `matches`, `claimedProcesses` and the unmatched-assertion diagnostic are unchanged. With no added apps the detector looks nothing up, and a PID without a bundle ID stays on the browser path.

stage: implement - ran (model: claude-opus-5-5; worker in lane worktree, parallel-wave handover)
stage: impl-review - ran [..2026-10-13T15:40Z] (model: gpt-5.6-sol xhigh; three-draw fan-out in the lane worktree: correctness SHIP, contracts SHIP, integration SHIP, no findings)
stage: plan-sync - skipped(config: planSync.enabled=false)

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

baseline: green (task verification filter, 328 tests, rc 0, pre-edit at 37d24869)

### Commits (base 37d24869)
- 2b728852 fix(app): keep added apps out of the browser-meeting path

### Acceptance → tests (all in `Tests/PowerAssertionDetectorAddedAppTests.swift`)
- An added app's WebRTC assertion and its helper's are never detected as browser meetings, while a browser, a PID with no bundle ID and a bundle ID that only shares the added one's text (`com.example.slacker`) still are (R7): `testAnAddedAppAndItsHelperAreNeverBrowserMeetings`. It collects every identity one poll state reports by excluding each one already found.
- An added app's assertion does not keep a browser meeting synthesised under its name active, and removing the app from the list restores today's liveness (R7): `testAnAddedAppDoesNotKeepABrowserMeetingOfItsNameActive`.
- With no added apps, "Slack" is detected and kept active as today, and `bundleIDForPID` is called 0 times across `checkOnce` and `isMeetingActive` (R8, AC 2): `testWithNoAddedAppsTheBrowserPathIsUnchangedAndLooksNothingUp`.
- A native Zoom call is still detected when Zoom's own bundle ID is in the added list, so the exclusion is the browser path's alone (R8): `testNativeAppsAreDetectedEvenWhenTheirBundleIDIsAdded`.
- Wiring through `WatchingController.defaultDetectors` (AC 3). With `watchCustomApps = ["com.example.slack"]` PID 7 is not detected after two polls. With `[]` it is: `testDefaultDetectorPassesTheAddedAppsToTheBrowserPath`.
- Red before green. With the two properties declared and no exclusion logic, 3 of the 5 tests failed (detection, liveness, wiring) and the two guard tests passed. All 5 pass with the logic in place.
- No existing test file changed.

### Gates
- Task verification filter (`PowerAssertionDetector|MeetingDetectorExclusion|CompositeMeetingDetector|MicInputDetector|WatchingController|WatchLoop`, `--skip WatchLoopE2ETests`) passed with rc 0 over 333 tests (328 at baseline plus the 5 new ones). Log: `/private/tmp/gh52-tick/t3-tests.log`.
- `AddedAppIdentity|MeetingPatterns|CustomWatchedApp` passed with rc 0 over 22 tests. These suites reference the detector but fall outside the task filter.
- `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 exited rc 0. SwiftFormat reported 0/715 files to format and SwiftLint 0 violations. `PowerAssertionDetector.swift` is 565 lines, under the 600-line limit.
- `swift build -c release` exited rc 0 with no warnings.
- Not run: `swiftlint analyze` runs on CI only. Every new declaration has a production caller: `addedAppBundleIDs` is set in the wiring and read by the helper, `bundleIDForPID` is called by the helper, and `isAddedAppHit` has two call sites. Also not run: the App Store variant build (the change touches no `#if APPSTORE` code), `./scripts/pre-push.sh`, and the installed app, because a live call in an added Electron app with browser meetings on is not available here.

### Decisions
1. Rule 6. The helper reuses the bundle rule through `MicInputDetector.MicPattern(appName: "", bundleIDs: addedAppBundleIDs, matchesHelpers: true).matchLength(bundleID:)` instead of restating `== || hasPrefix(+ ".")`. `MicInputDetector.swift` is outside this task's Touches, so no shared helper could be extracted, and a second copy of the rule could drift from the microphone path's.
2. Rule 1 (spec A5, "frozen per watch session like the mic patterns"). `addedAppBundleIDs` is assigned once in `defaultDetectors`. The deny list, by contrast, is read through the settings on every poll.
3. Rule 1 (task step 3, spec Edge Cases). The static `matches`, `claimedProcesses` and `unmatchedWatchedAssertionKeys` stay name-based. An added app's skipped assertion can therefore appear once per session in the "power assertion did not match" log line, as the spec accepts.
4. Rule 6. Test and implementation went into one commit, because the tests do not compile without the new properties. The red run was taken with the properties declared and the logic absent.
5. Rule 6. Two choices make the guard tests able to fail. The native-pattern test maps the Zoom process to an added bundle ID, so an implementation that excludes for every pattern fails it. The detection test adds a not-a-helper boundary (`com.example.slacker`) to the same table.
6. Rule 6. Ran the extra focused suites listed under Gates because they reference the detector.

### Open / follow-ups
- None from this task. Task .2 edits `AppSettings*`, `ConsentDenyList` and `GeneralSettingsView`. This task adds one line to `WatchingController+Detectors.swift`, directly after `assertions.isIdentityDenied = isDenied`.
## Evidence
- Commits: 2b728852fbe28831052948e07edd4c21d35bb7d8
- Tests: swift test --parallel --skip WatchLoopE2ETests --filter "PowerAssertionDetector|MeetingDetectorExclusion|CompositeMeetingDetector|MicInputDetector|WatchingController|WatchLoop" (rc 0 on the integrated target; worker lane gates in the summary), PATH="/private/tmp/gh52-tick/lint-bin:$PATH" ./scripts/lint.sh (rc 0)
- PRs: