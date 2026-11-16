---
satisfies: [R1, R2, R3, R4, R5, R6, R7]
---
# gh-255-record-a-call-after-answering-ignore.1 Implement Record a call after answering Ignore

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
After an "Ignore" on "Record <App> meeting?" while watching runs, the menu offers "Record (<App>)" in the place of "Record Again" for as long as that call runs; a click records the rest of the call at the next poll like a detected meeting, without a question, and ends the app's decline quiet time so its next call is asked about as usual.

- `IgnoredCalls` (new pure value) keeps the ignored meeting per identity key; `WatchLoop+RecordIgnored.swift` places it in `finishConsent` for a decline of the still-open question, releases it at the first poll with the signal gone, hides it while that app's question is open and lifts it on a click.
- `RecordAgainOffer` gains a `kind` (held or ignored call); `recordAgainOffers`, `recordAgain(identityKey:)` and `takeRecordAgain()` handle both; the parked request keeps the offer so a dropped click logs the right line.
- `BrowserConsentPolicy.endSuppression(app:)` ends one app's quiet time; the deny list is never touched.
- Any recording of the app forgets its entry (`handleMeeting`), "Never" forgets it, `stop()` discards all.
- Menu: "Record (<App>)" with its own `A11yID.recordIgnoredMenuItem`, no shortcut.
- `returnToWatching` moved to `WatchLoopState.swift` to keep `WatchLoop.swift` under the 600-line cap.
- Docs: detection.md bullet, architecture-macos.md rows.
- Tests: IgnoredCallsTests, BrowserConsentPolicyTests (endSuppression), WatchLoopRecordIgnoredTests (+Refusals), WatchLoopRecordIgnoredSplitTests (real PowerAssertionDetector), MenuBarViewSessionControlsTests; each wiring line checked to turn a test red when removed.

Tests: full suite 6737 tests, 0 failures (45 skipped), two shards; lint clean (SwiftFormat 0.64.6, SwiftLint 0.65.1).

stage: impl-review - ran [codex:gpt-6.1-sol:xhigh, three lenses, round 1] SHIP, no findings

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 05db1a3243f717cca8e09b4bf0d44e58ae53bccc, 3c89ade902e7c66d679137c0dcdba968d0354f7f
- Tests: CFFIXED_USER_HOME=<scratch> swift build -j 6 --build-tests && ../../scripts/ci/test-shards.sh run --shards 2 --skip ModelPreloadTests, ./scripts/lint.sh
- PRs: