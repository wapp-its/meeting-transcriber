---
satisfies: [R1, R2, R3, R5, R6, R7]
---
# gh-3-ask-before-recording-detected-meetings.1 Implement Ask before recording detected meetings

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
Every meeting the watcher detects now asks before it records, through the prompt browser meetings already used (Record / Ignore / Never for this app, same cooldowns, same deny list, one open prompt at a time), unless the user switched that app on under Settings > General > Record Without Asking. The switch exists for Teams, Zoom, Webex, WeChat, Tencent Meeting, FaceTime and WhatsApp, is off by default and disabled while the app is not watched; browser meetings always ask, "Never for this app" outranks the switch, and manual starts and the end-to-end meeting simulator never ask. The prompt names the app, a Record answer that lands while another meeting records is dropped and asked again later, and the notification-visibility warning in Settings now covers every watched app that asks.

Review: the first round (three Codex draws) found that an ask-first app waiting on an open prompt could hide a meeting that records without asking, and that the Settings warning counted denied apps as asking; both were fixed in 5bf8e16 and the re-review returned SHIP with no surviving findings.

Tests that cover the acceptance criteria: WatchLoopAskBeforeRecordingTests (every answer for native, mic-input and browser apps; switch on and off; deny-list precedence; browser always asks; competing meetings; record-only; manual start; simulator), WatchingControllerAskBeforeRecordingTests (setting reaches the loop, start stays announced), AppMeetingPatternTests.testWhoAsksBeforeRecording, AppSettingsRecordWithoutAskingTests (default, persistence, warning input), GeneralSettingsRecordWithoutAskingTests and GeneralSettingsBrowserWarningTests (UI wiring), MeetingDetectorExclusionTests (detectors pass over waiting apps; mic-input deny list). The test that pinned native meetings auto-starting without a prompt (WatchLoopBrowserConsentTests.testNativeMeetingNeverPromptsAndAutoStarts) encoded the old default and now asserts the prompt (testNativeMeetingAsksBeforeRecording).

baseline: red (WatchLoopE2ETests, 5 tests, failed pre-edit: model-dependent end-to-end tests that cannot load WhisperKit models under the redirected home; skipped in verification; the other 534 focused tests were green)
verify: focused suites 945/945 green on the final code; ./scripts/lint.sh 0 violations; swift build -c release clean. Five key behaviours were mutation-checked: each test goes red with its fix reverted.

Follow-ups (not done, listed for the owner):
- CLAUDE.md / AGENTS.md (not editable here): the Architecture Notes still describe the consent prompt as browser-only (Detection: browser meetings "gated behind a consent prompt", MicInputDetector "a confirmed hit starts recording without a prompt", the BrowserConsentReadiness paragraph). Needs a doc update in the original's instruction file.
- Pre-existing, now reachable for native apps: after a decline, the suppressed app re-confirms every few seconds and the gate's detector.reset clears every app's confirmation counter; at a poll interval of 5 s or more this can starve mic-input detection for the length of the cooldown. Matters if users raise the poll interval.
- /state.settings (automation API) does not expose recordWithoutAskingApps; add it if a driver needs to read the switch.
- Several types and identifiers keep browser names although they now serve every app (BrowserConsentReadiness, BrowserConsentPolicy, resolveBrowserConsent, the BROWSER_MEETING_* notification ids, the /action/confirmBrowserConsent route); renaming was out of scope. docs/architecture-macos.md's BrowserConsentPolicy row still says "browser-meeting".
- Two reviewer draws saw output-folder notification tests fail inside the Codex sandbox; they pass locally (945/945). Watch for them in CI.
- Memory capture of the review lesson failed: .flow/memory is not initialized in this repo (flowctl memory init).

Decisions: the "ignore unknown names" rule lives in AppMeetingPattern.asksBeforeRecording (only the seven apps with a switch can be listed); the shared test meeting moved from a made-up "Test App" to Zoom so tests can switch it to record without asking.

Tier: IMPLEMENTER opus at xhigh (actual model: claude-opus-5-5)

stage: impl-review - ran (codex:gpt-5.6-sol:xhigh; fan-out NEEDS_WORK, validator kept 2/2, fix 5bf8e16, re-review SHIP)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 8ba8600a1434443e98dc00c99ab75eae479323ef, 5bf8e16d907229be4bf08188e44986ad3554fb31
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch> swift test --parallel --skip WatchLoopE2ETests --filter "WatchLoop|Consent|GeneralSettings|AppSettings|NotificationManager|WatchingController|PowerAssertionDetector|MicInputDetector|MeetingPatterns|AppMeetingPattern|MeetingDetectorExclusion|SettingsInteraction|ManualRecording|RecordOnly|AppStateTests|DebugRPCServerIntegration|RPC|MeetingDetector|SettingsView" (945/945 passed), ./scripts/lint.sh (0 violations), swift build -c release (clean)
- PRs: