---
satisfies: [R1, R2, R3, R4, R8]
---
# gh-52-keep-added-apps-apart-from-same-named.1 Carry an identity key through detection and the consent gate

## Description
Introduce the identity key and switch every place that remembers or compares an app, in both detectors and in the consent gate, from `appName` to `identityKey`, while everything a person reads keeps `appName` (spec §Architecture "Identity key", "Identity vs. display", "Open-prompt state"). One task because the detectors and the gate must change together: a gate that still passes display names to `reset(appName:)` while the mic detector keys by identity would leave the cooldown on the wrong key. This is the early proof point (R1-R3, the prompt / recording / `pendingConsentApp` part of R4, R8).

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/AddedAppIdentity.swift` (new), `Sources/MeetingPatterns.swift`, `Sources/MicInputDetector.swift`, `Sources/MeetingDetecting.swift`, `Sources/PowerAssertionDetector.swift` (only `isMeetingActive`), `Sources/WatchLoop.swift`, `Sources/WatchLoop+Consent.swift`, `Sources/RedetectionHolds.swift`, `Sources/WatchLoop+RedetectionHold.swift` (doc comment and log line only), `Sources/ConsentDenyList.swift` (doc comment only); tests listed below, including the new shared `Tests/ConsentLoopDoubles.swift` and a new case in `Tests/RedetectionHoldsTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/AddedAppIdentity.swift, app/MeetingTranscriber/Sources/MeetingPatterns.swift, app/MeetingTranscriber/Sources/MicInputDetector.swift, app/MeetingTranscriber/Sources/MeetingDetecting.swift, app/MeetingTranscriber/Sources/PowerAssertionDetector.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/WatchLoop+Consent.swift, app/MeetingTranscriber/Sources/RedetectionHolds.swift, app/MeetingTranscriber/Sources/WatchLoop+RedetectionHold.swift, app/MeetingTranscriber/Sources/ConsentDenyList.swift, app/MeetingTranscriber/Tests/AddedAppIdentityTests.swift, app/MeetingTranscriber/Tests/RedetectionHoldsTests.swift, app/MeetingTranscriber/Tests/WatchLoopAddedAppIdentityTests.swift, app/MeetingTranscriber/Tests/ConsentLoopDoubles.swift, app/MeetingTranscriber/Tests/WatchLoopAskBeforeRecordingTests.swift, app/MeetingTranscriber/Tests/MicInputDetectorTests.swift, app/MeetingTranscriber/Tests/CustomWatchedAppConsentTests.swift, app/MeetingTranscriber/Tests/CompositeMeetingDetectorTests.swift]

### Approach
Tests first (this is a bug fix): write the new tests below, run them, see them fail for the stated reason (same-named apps share state, or `identityKey` does not exist yet), then implement.

1. `Sources/AddedAppIdentity.swift` (new, fork-local): an `enum AddedAppIdentity` namespace with `key(bundleID:) -> String` (`"custom:" + bundleID`) and `bundleID(fromKey:) -> String?` (nil without the prefix). Doc comment: why a prefix (bundle IDs never contain `:`, built-in and browser keys are plain names), and that nothing else may spell it.
2. `Sources/MeetingPatterns.swift:4-37`: add `let identityKey: String` and a trailing init argument `identityKey: String? = nil` stored as `identityKey ?? appName`. No existing call site changes. Document it as the key all per-app detection and consent state is filed under, with `appName` for display only.
3. `Sources/MicInputDetector.swift`
   - `:44-55` custom branch of `meetingPattern`: pass `identityKey: AddedAppIdentity.key(bundleID: bundleIDs.first ?? appName)`. The built-in branch is unchanged.
   - `:150-152` key `matchers` by `meetingPattern.identityKey`.
   - `:174-200` `checkOnce(excluding:)`: the local `appName` is today both key and display name; split it. The key (`pattern.meetingPattern.identityKey`) drives `isIdentityDenied`, `cooldownUntil`, `hitsThisRound`, `firstMatch`, `matchedPattern`, `consecutiveHits`, `excludedApps` and the `matchers` lookup; the placeholder title (`PowerAssertionDetector.placeholderTitle(appName:)`) and `ownerName:` use the display name (`meetingPattern.appName`).
   - `:210-216` `isMeetingActive`: filter `patterns` by `meetingPattern.identityKey == meeting.pattern.identityKey`.
   - `:125-130` doc comment of `isIdentityDenied`: it receives identity keys.
4. `Sources/MeetingDetecting.swift:32-44, 57-60`: document that `excludedApps` and `reset(appName:)` carry identity keys; the default `checkOnce(excluding:)` compares `meeting.pattern.identityKey`. Do not rename the parameters (spec A6).
5. `Sources/PowerAssertionDetector.swift:369-370`: pass `meeting.pattern.identityKey` to `identifies(meetingAppName:processName:)`. For every meeting this detector produces the key equals `appName`, so its behaviour is unchanged; an added app's key matches none of its identities.
6. `Sources/WatchLoop+Consent.swift:25-72, 103-153`: `let key = meeting.pattern.identityKey` for `denyListStore.isDenied/deny`, `consentPolicy.decision/recordDecline/recordExpiry`, `appsWaitingForPrompt`, `detector.reset(appName:)` and the open-prompt slot. The prompt label stays the display name: `meeting.pattern.appName`, falling back to `meeting.ownerName` when empty (today's rule at `:58`). Log lines may keep the key.
7. `Sources/WatchLoop.swift:89-100, 110-117, 386`: the open-prompt state must hold the key (gating, `appsExcludedFromDetection`, `declineParkedConsent`) and the display name, and `pendingConsentApp` must keep returning the display name, because `Sources/AppState+RPC.swift:88,120` reads it for `/state` and `/v1/watch` and must stay untouched. `runMeeting`'s reset at `:386` passes `meeting.pattern.identityKey`. Suggested shape: replace the stored `pendingConsentApp` with a stored `pendingConsent` value (key + display name, a small struct declared in `WatchLoop+Consent.swift`) and make `pendingConsentApp` a computed property in `WatchLoop+Consent.swift`.
8. `Sources/ConsentDenyList.swift:17-20` doc comment: entries are identity keys; an added app's is `custom:<bundleID>`.
9. The re-detection hold set (merged after this plan was written, stop-by-hand work): `Sources/RedetectionHolds.swift:21` keys `hold(_:)` by `meeting.pattern.identityKey` (doc comment `:4-6`: keyed by `AppMeetingPattern.identityKey`, the key `checkOnce(excluding:)` takes), `Sources/WatchLoop.swift:345` compares `approved.pattern.identityKey` against `appsHeldFromDetection` (`:347` needs no change once the set carries keys), and the `redetect_hold_set` log line at `Sources/WatchLoop+RedetectionHold.swift:28` logs the key. `release(where:)` and `heldApps` keep their shape; a hold is set from `WatchLoop+MeetingEnd.swift:49`, which passes the meeting and needs no change.

### Tests
- New `Tests/AddedAppIdentityTests.swift`: key format and round trip; `bundleID(fromKey:)` is nil for "Zoom", "" and a browser name; every `AppMeetingPattern.all` pattern and a browser identity from `PowerAssertionDetector.meetingIdentity` has `identityKey == appName`; an added app's `MicPattern.meetingPattern` has key `custom:<bundleID>` and its display name as `appName`.
- `Tests/MicInputDetectorTests.swift` (helpers at `:6-22`, same-name cases at `:223-251`): built-in WeChat plus an added "WeChat" (`com.example.wechat`): denying "WeChat" leaves the added one detected, denying `custom:com.example.wechat` leaves the built-in detected and not the added one; `reset(appName: "WeChat")` leaves the added one detected on the next poll while the built-in is cooled down (use `confirmationCount: 1`: a reset still restarts every app's count, which is out of scope); each one's meeting is not kept active by the other's bundle holding the mic. Two added apps named "Meet" (`com.a.meet`, `com.b.meet`) keep separate cooldowns and liveness. The added app's placeholder title and `ownerName` are its display name.
- Changed requirement (say so in the commit message): `MicInputDetectorTests.testCustomAppNamedLikeABuiltInInAnotherCaseStaysActiveAndCoolsDown` resets with `meeting.pattern.identityKey` (`:249`); `CustomWatchedAppConsentTests.testDeniedCustomAppIsNotDetected` denies `custom:com.example.callapp` (`:83`) and also asserts that denying the display name "CallApp" no longer suppresses it.
- `Tests/CompositeMeetingDetectorTests.swift`: a composite of `PowerAssertionDetector(patterns: .patterns(watching: ["Zoom"]))` and a `MicInputDetector` with an added "Zoom" (`com.example.zoom`): after the added app's meeting is detected and its mic is released, a `zoom.us` "Zoom call" assertion (`PowerAssertionFixture.assertions`) does not keep it active; control: the built-in Zoom meeting is active under that assertion.
- Shared loop-test doubles, no copy: move the scripted detector, the answering and parking notifiers and the recorder pool out of `Tests/WatchLoopAskBeforeRecordingTests.swift:15-111` into a new internal namespace `enum ConsentLoopDoubles` in `Tests/ConsentLoopDoubles.swift` (precedent: `Tests/PowerAssertionFixture.swift`, extracted for the same reason; the enum name satisfies SwiftLint's `file_name` rule and `single_test_class` forbids a second test class in one file). The scripted detector excludes and tracks running meetings by `pattern.identityKey`, which equals `appName` for every built-in, so the existing suite's assertions do not change; only its references to the doubles do. Keep `makeLoop` per suite or move it too, whichever keeps both files simplest.
- New `Tests/WatchLoopAddedAppIdentityTests.swift`, driven through `start()` like the existing suite, using `ConsentLoopDoubles`. Meetings: `AppMeetingPattern.zoom` and an added "Zoom" built from `MicInputDetector.MicPattern(appName: "Zoom", bundleIDs: ["com.example.zoom"], matchesHelpers: true, usesBuiltInMeetingPattern: false).meetingPattern`. Cases: Never on the added Zoom stores `custom:com.example.zoom` (not "Zoom"), its prompt title is "Record Zoom meeting?", and the built-in Zoom is still asked about; Never on the built-in leaves the added one asked about; Ignore (`.declined`) on the built-in does not suppress the added one's prompt; no answer (`.expired`) on the built-in keeps the built-in suppressed while the added one is still asked about, and the same the other way round; while the added one's prompt is parked, `pendingConsentApp == "Zoom"` and `appsExcludedFromDetection == ["custom:com.example.zoom"]`; a granted added-app recording runs with `currentMeeting?.pattern.appName == "Zoom"`.
- `Tests/RedetectionHoldsTests.swift` (existing cases stay as they are): a new case where a hold on an added "Zoom" (the `MicPattern.meetingPattern` above) reports `heldApps == ["custom:com.example.zoom"]`, a second hold on the built-in `.zoom` is new and held beside it, and `release(where:)` releases each by its own meeting.
- Leave the private doubles in `Tests/WatchLoopStopByHandTests.swift` (and the other loop suites) where they are: they only drive built-ins, whose key equals the name, and the shared-doubles move above is the one permitted edit to another existing test file.
- Not in this task: the detector reset after an answer still clears every app's confirmation count (spec Boundaries follow-up); do not make `reset(appName:)` identity-scoped.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/MicInputDetector.swift:29-231` — custom patterns, per-app state, liveness, reset
- `app/MeetingTranscriber/Sources/WatchLoop+Consent.swift:18-154` — the consent gate
- `app/MeetingTranscriber/Sources/WatchLoop.swift:80-118, 335-390` — open-prompt state, poll loop (with the hold release and union), reset after a recording
- `app/MeetingTranscriber/Sources/RedetectionHolds.swift`, `Sources/WatchLoop+RedetectionHold.swift` — the re-detection hold set (step 9)
- `app/MeetingTranscriber/Sources/MeetingPatterns.swift:1-197` — the pattern type and `asksBeforeRecording`
- `app/MeetingTranscriber/Tests/WatchLoopAskBeforeRecordingTests.swift:1-280` — loop-test doubles to move into `ConsentLoopDoubles`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/PowerAssertionDetector.swift:82-116, 355-378` — identity keys and liveness in the assertion detector
- `app/MeetingTranscriber/Tests/PowerAssertionDetectorIdentityTests.swift:148-182` — cross-pattern liveness test shape
- `app/MeetingTranscriber/Tests/PowerAssertionFixture.swift` — assertion fixtures

### Key context
- `MicInputDetector.customPattern(bundleID:)` resolves the display name through NSWorkspace (an uninstalled bundle reads as its bundle ID); in tests build `MicPattern` directly as `MicInputDetectorTests.swift:20-22` does.
- `WatchLoop.swift` is 589 lines and `./scripts/lint.sh` runs SwiftLint `--strict` (`file_length` warns at 600 → error): keep that file's net growth within 11 lines; put new members in `WatchLoop+Consent.swift`.
- `AppMeetingPattern`'s synthesized `Equatable` now includes `identityKey`; `asksBeforeRecording` compares whole patterns with built-ins, which keep `identityKey == appName`, so nothing changes there.
- No `#if APPSTORE` code is touched.
- Commit messages are written for the original's readers: no fork issue numbers or `gh-`/`fn-` ids (fork rule, `submit.sh` refuses them). Conventional Commits, scope `app` / `test`; stage files explicitly.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<your scratch>/home swift test --parallel --skip WatchLoopE2ETests --filter "AddedAppIdentity|MicInputDetector|CustomWatchedApp|CompositeMeetingDetector|MeetingDetectorExclusion|PowerAssertionDetector|WatchLoop|ConsentDenyList|BrowserConsent|AppMeetingPattern|WatchingController|DebugRPCServer" > /private/tmp/<your scratch>/t1-tests.log 2>&1` and read the log (never pipe a test run into tail/head/grep). Model-download suites failing under a scratch home are environmental.
- `./scripts/lint.sh`: SwiftFormat 0.63.0 and SwiftLint 0.65.1 are not installed globally on this Mac; fetch the pinned release assets named in `scripts/tool-versions.sh` (verify the SHA-256) into a scratch dir and run `PATH="<that dir>:$PATH" ./scripts/lint.sh`. Do not `brew install`.
## Acceptance
- [ ] `AppMeetingPattern.identityKey` exists and equals `appName` for every built-in pattern and browser identity; an added app's pattern carries `custom:<bundleID>` as key and its display name as `appName` (R8, R4).
- [ ] `MicInputDetector` files counters, cooldowns, deny checks, title matchers and liveness by identity key: the same-named built-in/added and two-added-apps tests pass (R1, R2, R3).
- [ ] A built-in Zoom call assertion does not keep an added "Zoom" meeting active through `CompositeMeetingDetector`, and the built-in's own meeting still is (R3).
- [ ] The consent gate files the deny list, both cooldowns, the open-prompt slot, the waiting set and every detector reset by identity key; the prompt text, the recording's app name and `pendingConsentApp` show the display name (R1, R2, R4), proven by `WatchLoopAddedAppIdentityTests`, including the Never, Ignore (`.declined`) and no-answer (`.expired`) cases in both directions.
- [ ] The loop-test doubles live once, in `ConsentLoopDoubles`, used by both loop suites; `WatchLoopAskBeforeRecordingTests` keeps every assertion unchanged.
- [ ] `Sources/AppState+RPC.swift` is unchanged; `WatchLoop.swift` stays at or below 600 lines.
- [ ] Only the two named existing tests changed their assertions, each for the changed requirement as the commit message says; every other test in the verification filter passes unchanged (R8).
- [ ] `./scripts/lint.sh` passes with the pinned tools.
## Done summary
Every meeting pattern now carries an identity key (`custom:<bundleID>` for an app added through "Add App…", the name for built-in apps and browsers). The microphone detector, the assertion detector's liveness check, the default excluding poll, the consent gate and the re-detection holds file their state under that key; a microphone-holding process is filed under the pattern whose matching bundle ID is longest, so two added apps with prefix-related bundle IDs stay apart too. Everything a person reads still shows the display name, including `pendingConsentApp` on `/state` and `/v1/watch`. Built-in apps and browsers behave exactly as before, because their key equals their name.

stage: implement - ran (model: claude-opus-5-5; worker in lane worktree, parallel-wave handover)
stage: impl-review - ran [2026-10-13T14:45Z..15:02Z] (model: gpt-5.6-sol xhigh; round 1 three-draw fan-out: correctness NEEDS_WORK, contracts SHIP, integration SHIP; one P1 finding fixed in a4d2e4ac; round 2 SHIP, no surviving findings)
stage: plan-sync - skipped(config: planSync.enabled=false)

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

baseline: green (task verification filter, 572 tests, rc 0, pre-edit at 1f4b14b3)

### Commits (base 1f4b14b3)
- 989607d3 feat(app): give every meeting pattern an identity key
- 1220fbdf refactor(test): share the consent loop test doubles
- 94a34db6 fix(app): keep added apps apart from same-named apps
- a4d2e4ac fix(app): file a mic process under its most specific added app (review fix: `MicPattern.matchLength(bundleID:)` plus `MicInputDetector.mostSpecificPattern(for:)` used by both detection and liveness; `matches(bundleID:)` removed, no caller left; regression test `testPrefixRelatedAddedAppsAreFiledUnderTheMostSpecificBundleID`, red before the fix on both assertions, green after)

### Acceptance → tests
- identityKey is the name for built-ins and browsers; an added app gets `custom:<bundleID>` (R8, R4): `AddedAppIdentityTests` (4).
- MicInputDetector keys counters, cooldowns, deny checks, title matchers and liveness by key (R1, R2, R3): `MicInputDetectorTests.testANeverForOneOfTwoSameNamedAppsLeavesTheOtherDetected`, `testAResetCoolsDownOnlyTheSameNamedAppItNames`, `testOneOfTwoSameNamedAppsHoldingTheMicDoesNotKeepTheOthersMeetingActive`, `testTwoAddedAppsWithTheSameNameKeepSeparateCooldownsAndLiveness`, `testPrefixRelatedAddedAppsAreFiledUnderTheMostSpecificBundleID`, `testEachSameNamedAppTitlesItsMeetingWithItsOwnMatcherAndName`.
- A built-in Zoom call assertion does not keep an added "Zoom" active, with a control showing the built-in's own meeting still is (R3): `CompositeMeetingDetectorTests.testABuiltInCallDoesNotKeepASameNamedAddedAppsMeetingActive`.
- The consent gate keys the deny list, both cooldowns, the open prompt, the waiting set and every reset (R1, R2, R4): `WatchLoopAddedAppIdentityTests` (4 tests through `start()`): Never, Ignore (`.declined`) and no answer (`.expired`) in both directions; a Never on the added app stores `custom:com.example.zoom` only; while the added app's prompt is parked, `pendingConsentApp == "Zoom"` and the gate excludes `["custom:com.example.zoom"]`; a decline resets the detector only under the added app's key; a granted added app records with `currentMeeting?.pattern.appName == "Zoom"`.
- Re-detection holds are keyed by identity: `RedetectionHoldsTests.testAnAddedAppIsHeldUnderItsKeyBesideASameNamedBuiltIn`.
- The loop-test doubles exist once, in `ConsentLoopDoubles`, used by both loop suites; every assertion in `WatchLoopAskBeforeRecordingTests` is unchanged.
- `AppState+RPC.swift` is unchanged; `WatchLoop.swift` stays at 589 lines.
- Only the two named tests changed their assertions, for the changed requirement as the fix commit says.

### Gates
- Task verification filter plus `RedetectionHolds`, `--skip WatchLoopE2ETests`: rc 0, 591 tests (worker, lane). After the review fix, on the integrated branch: rc 0, 135 tests over `MicInputDetector|CustomWatchedApp|CompositeMeetingDetector|MeetingDetectorExclusion|WatchingController|WatchLoopAddedApp|WatchLoopAskBeforeRecording`.
- The spec's settings suites (`AppSettingsRecordWithoutAsking|GeneralSettingsConsentDenyList`): rc 0, 9 tests.
- `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1: rc 0, 0 violations in 714 files, before and after the review fix.
- Not run: `swiftlint analyze` (CI only; `AddedAppIdentity.bundleID(fromKey:)` gets its production caller in task .2), `./scripts/pre-push.sh`, the installed app (two same-named call apps holding the microphone are not available; the loop tests drive the real `start()` poll loop).

### Decisions
1. Rule 1 (task: keep `makeLoop` per suite or move it): per suite; the new suite has a two-parameter version.
2. Rule 6: the existing loop suite reaches the shared doubles through private typealiases, so its body is untouched.
3. Rule 1 (acceptance: every detector reset by identity key, proven by the loop suite): `ConsentLoopDoubles.ScriptedDetector` records each reset's key.
4. Rule 1 (R8, A6): `PendingConsent.appName` holds `meeting.pattern.appName` exactly, so `pendingConsentApp` stays identical for built-ins.
5. Rule 1 (task: log lines may keep the key): consent and `redetect_hold_set` log lines log the identity key.
6. Rule 6: `RedetectionHolds` added to the verification filter, since the stated filter does not match that suite.
7. Rule 6 (conductor): the review's validator pass was not run for round 1; its single finding was confirmed by reading `MicInputDetector.checkOnce` (first-match helper-prefix selection) before the fix.
8. Rule 1 (CI `unused_declaration`): `MicPattern.matches(bundleID:)` removed once the longest-match helper replaced its last caller; task .3's reference re-pointed to `matchLength(bundleID:)`.

### Open / follow-ups
- Until task .2 lands, a legacy name entry on the deny list no longer suppresses an added app of that name (asks again: the safe direction); task .2's one-shot migration adds the key. Both ship in the same PR.
- Open fork PR #109 edits `WatchLoop.swift`, `WatchLoop+Consent.swift` and `WatchLoopAskBeforeRecordingTests.swift`; whichever lands second must use the stored `pendingConsent` and `ConsentLoopDoubles`.
## Evidence
- Commits: 989607d35ce23ac0d3d44130b528e057d73d1e5d, 1220fbdf25c61932a622da8a36d5c7d677ff29f6, 94a34db6d6354b7365461202d59b66e5a0143655, a4d2e4ac4f38268cf6868460104862703cea65b7
- Tests: swift test --parallel --skip WatchLoopE2ETests --filter "MicInputDetector|CustomWatchedApp|CompositeMeetingDetector|MeetingDetectorExclusion|WatchingController|WatchLoopAddedApp|WatchLoopAskBeforeRecording" (rc 0, 135 tests at a4d2e4ac); worker lane filter rc 0, 591 tests at 94a34db6; settings suites rc 0, 9 tests, PATH="/private/tmp/gh52-tick/lint-bin:$PATH" ./scripts/lint.sh (rc 0, 0 violations)
- PRs: