---
satisfies: [R1, R2, R3, R4, R5]
---
# gh-127-start-the-app-at-login-and-date-both.1 Implement Start the app at login and date both ends of the not-running notice

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
After a restart the fork's builds in /Applications now start at login by themselves, once by default and never against a user's later off switch, and the not-running notice dates both ends of a gap that crosses a day ("10:52 on 8 Mar ... until 10:53 on 10 Mar"). New fork-only file `LoginItemDefault.swift`, wired from `AppLauncher.main()`; `PreviousExitNotice` dates both times when the days differ.

stage: impl-review - ran (codex gpt-6-astra xhigh, three draws correctness/contracts/integration, all SHIP, no findings; receipt effort xhigh)

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

Verification (measured):
- R1 red on base: 4 tests failed with the launch time undated, e.g. "...until 10:53. Nothing was recorded in between." against "...until 10:53 on 10 Mar. ..."; green on head.
- Focused suite on head, Homebrew variant: LoginItemDefaultTests, LoginItemTests, PreviousExitNoticeTests, MeetingTranscriberAppTests, LivenessMarkerTests - 50 tests, 0 failures. App Store variant (-DAPPSTORE, separate build folder): LoginItemDefaultTests, LoginItemTests, PreviousExitNoticeTests, MeetingTranscriberAppTests - 28 tests, 0 failures.
- Mutation check: dropping the already-applied guard and the own-name exclusion made 5 of the 8 LoginItemDefaultTests fail; file restored.
- ./scripts/lint.sh clean (0 violations, 1212 files). swiftlint analyze not run (CI).
- Not verified: the wiring line `LoginItemDefault.applyAfterLaunch()` in `AppLauncher.main()` (xctest never enters main), and R5's live check after two mt-update installs, deferred to the landing agent per the spec. The line it reads: `login_item status=<enabled|requiresApproval|notRegistered|notFound> default=<outcome>`, notice level, subsystem com.meetingtranscriber, category LoginItem.

Choices the spec left open (choice - rule - what was built):
1. Check order - rule 6 - App Store, then already-applied, then location, then other copy, then status; every launch after the default was spent logs `already-applied` wherever the bundle runs, which is what R5's second install expects.
2. Status unknown to this SDK (`@unknown default`) - rule 6 - treated like off (register once), matching `LoginItemState`, which shows it as off; the log word is `unknown(<raw value>)`. Switch point `LoginItemDefault.decide`.
3. Other-copy detection - rule 1 (A4, spec decision inputs) and rule 6 - a file check for `/Applications/MeetingTranscriber.app` and `/Applications/MeetingTranscriber-Dev.app`, minus the running bundle's own name compared case-folded, so the running copy never counts as the other one. Test `testAnotherCopyInApplicationsSpendsTheDefaultWithoutRegistering` and the first-launch test with the running bundle on disk.
4. "Directly in /Applications" - rule 1 (R3) - symlinks resolved, then the parent folder must be exactly `/Applications`; `/Applications/Utilities/...` is skipped. Test `testABundleOutsideApplicationsIsSkippedAndKeepsTheDefault`.
5. When the step runs - rule 1 (spec Architecture) - an observer of `NSApplication.didFinishLaunchingNotification` registered in `AppLauncher.main()` right after the liveness marker; the status in the log line is read after the step.
6. App Store - rule 1 (spec Architecture and decision inputs) - `isAppStore` is a decision input defaulting to the compile-time flag, so the App Store case is tested in both variants, and the `register()` call itself is compiled out under APPSTORE.
7. Test fake - rule 1 (spec Edge cases allow either) - a new `FakeRegistrar` in the fork-only `LoginItemDefaultTests.swift`; the original's `LoginItemTests.swift` is untouched.
8. README bullet - rule 4 (copy) - assumption: one bullet under "What this build adds" saying the app opens at login, not when the original app is installed too, and where to switch it off. Switch point `.github/README.md`, that bullet; docs only, no test.
9. After-midnight time in the R1 test - rule 6 - this macOS prints en_GB short time as `0:10`, so that one time comes from the system time style and the test pins the date after it; the reproduction keeps its exact literal text.

Follow-ups (not built):
- `default=failed` carries no error code, so a refused register on a user's Mac gives no reason in the log; the contract fixes the line's words.
- Pre-existing build warnings in ViewInspectorIdentifierTests (main-actor init called from a nonisolated context), present on base.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: abe989662e34e81399773ca58d73929c13998a87, b129f51f27898e9c32e75ba71f9f918f22cb04f9, f3b1b0e8d77065ca2bb80711fdf89090bb550bc2
- Tests: cd app/MeetingTranscriber && swift build -j 6 --build-tests && swift test --skip-build --filter 'LoginItemDefaultTests|LoginItemTests|PreviousExitNoticeTests|MeetingTranscriberAppTests|LivenessMarkerTests' (50 tests, 0 failures), swift build -j 6 --build-tests -Xswiftc -DAPPSTORE (scratch build path) && swift test --skip-build --filter 'LoginItemDefaultTests|LoginItemTests|PreviousExitNoticeTests|MeetingTranscriberAppTests' (28 tests, 0 failures), ./scripts/lint.sh (0 violations)
- PRs: