---
satisfies: [R2, R3, R4, R6, R7]
---
# gh-8-in-app-updates-through-mt-update.4 About and menu controls for mt-update installs

## Description
The two places a person meets the feature: About → Updates and the menu-bar menu. In mt-update mode they show the available build, an "Install Update" control gated by the install reason, the running install, and failures; GitHub mode keeps today's look and behaviour. Last because it only renders state task 3 owns.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/Settings/AboutSettingsView.swift`, `app/MeetingTranscriber/Sources/MenuBarView.swift`, `app/MeetingTranscriber/Sources/SettingsView.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Tests/AboutSettingsViewTests.swift`, `app/MeetingTranscriber/Tests/MenuBarViewTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/Settings/AboutSettingsView.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/SettingsView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/AboutSettingsViewTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift]

### Approach
- `A11yID`: `updateInstallButton` (About) and `menuInstallUpdateButton` (menu). Never add either to the `/ui/press` allowlist in `DebugRPCServer+UIPress.swift`: a press ends the app.
- `AboutSettingsView` (`AboutSettingsView.swift:59-113`): new stored properties `updateInstallBlockedReason: String? = nil` and `onInstallUpdate: (() -> Void)? = nil`. When `updateChecker.isMtUpdateMode`: keep the "Check for Updates" toggle; hide "Include Pre-Releases"; a secondary caption "Updates are built on this Mac by mt-update."; "Check Now" also disabled while installing; the status label shows `lastError` / "Update available: <summary>" / "Up to date" as today. While installing: a small `ProgressView` with "Installing update… Meeting Transcriber restarts when the build is done and nothing is recording or processing." Otherwise, with a summary: the "Install Update" button (`A11yID.updateInstallButton`, calls `onInstallUpdate`), disabled when a reason is set, a check runs or the callback is nil, and under it the reason or "Builds the new version (about 5–10 minutes), then restarts Meeting Transcriber." A set `lastInstallError` shows as a red label. GitHub mode: today's section, untouched (the "Download" button stays).
- `MenuBarView` (`MenuBarView.swift:368-381`): same two new defaulted `var`s (existing memberwise call sites in the tests keep compiling). In mt-update mode: installing → a disabled "Installing Update…" item; a summary → "Install Update: <summary>" (`A11yID.menuInstallUpdateButton`), disabled when a reason is set, a check runs or the callback is nil. GitHub mode unchanged.
- `SettingsView`: forward both values to `AboutSettingsView` (pattern: the `namingDialogActive`/`pipelineBusy` pass-through).
- `MeetingTranscriberApp`: pass `appState.updateInstallBlockedReason` and `{ appState.installUpdate() }` to both `MenuBarView` (`:144-196`) and `SettingsView` (`:278-300`), read through single-member `AppState` accessors only (300 ms type-check limit on these bodies; see the note above `body`).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/Settings/AboutSettingsView.swift:59-113` — section to extend
- `app/MeetingTranscriber/Sources/MenuBarView.swift:1-86,368-381` — properties, body split, update item
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:124-214,292-314` — scene composition and the type-check note
- `app/MeetingTranscriber/Sources/A11yID.swift` — identifier conventions

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/AboutSettingsViewTests.swift:75-112` — update-section tests
- `app/MeetingTranscriber/Tests/MenuBarViewTests.swift:772-800` — update-item tests
- `CLAUDE.md` "GUI Testing" — locate by `A11yID`, one wiring test per control

### Key context
- One ViewInspector wiring test per new control, located by its `A11yID` constant: About's button tap calls `onInstallUpdate`; the menu item tap calls it; each is `isDisabled()` with a reason set. Plus: About in mt-update mode shows the reason text, hides "Include Pre-Releases", shows the installing text instead of the button while installing, and shows `lastInstallError`. Build the mt-update-mode checker with `MockMtUpdateInstaller` from task 3 and set `availableBuildSummary` directly. Existing GitHub-mode tests stay unchanged and green.
- Do not edit `CLAUDE.md`, `AGENTS.md` or `docs/architecture-macos.md`: this is a fork-only feature and those files are the original's.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh-8-test-home swift test --parallel --filter 'AboutSettingsViewTests|MenuBarViewTests|SettingsViewTests|MtUpdate|UpdateInstall|UpdateChecker' > /private/tmp/gh-8-t4.log 2>&1` (read the log).
- `./scripts/pre-push.sh --all` (release app, test target and App Store variant).
- `./scripts/lint.sh` with the pinned tools.

## Acceptance
- [ ] About in mt-update mode: caption, no "Include Pre-Releases", "Update available: <summary>", an "Install Update" button found by `A11yID.updateInstallButton` whose tap calls the install callback, disabled with its reason shown while blocked, replaced by the installing text while an install runs, and the last install error shown.
- [ ] Menu in mt-update mode: "Install Update: <summary>" found by `A11yID.menuInstallUpdateButton` whose tap calls the install callback and which is disabled while blocked; a disabled "Installing Update…" item while an install runs.
- [ ] GitHub mode looks and behaves as before; every existing About, menu and Settings test passes unchanged.
- [ ] Neither identifier is on the `/ui/press` allowlist; `CLAUDE.md`, `AGENTS.md` and `docs/architecture-macos.md` are unchanged.
- [ ] `./scripts/pre-push.sh --all` succeeds (type-check limits, App Store variant); lint clean.

## Done summary
In mt-update mode, About → Updates and the menu-bar menu now show the build mt-update found and offer "Install Update". Both controls are disabled while a recording, a job or a check blocks the install, and About names the blocking reason. While an install runs, About shows a progress line and the menu an inert "Installing Update…" line. About keeps the last install failure on show. GitHub mode renders as before. The app passes `AppState.updateInstallBlockedReason` and `installUpdate()` to both views.

stage: impl-review - ran [2026-10-14T12:47:52Z..2026-10-14T12:50:40Z]

Tier: implementer - opus at xhigh (explicit invocation) (model: claude-opus-5-5)

Review: codex:gpt-6-astra:xhigh, receipt effort xhigh, receipt /tmp/impl-review-receipt-cfaadf991a4c-gh-8-in-app-updates-through-mt-update.4.json, terminal verdict SHIP.
- Round 1 used one reviewer, the correctness lens (Choices 8). It returned SHIP with no findings and all seven R-IDs met. The reviewer ran the focused tests itself (220 passed) and the pinned lint.
- `FLOW_VALIDATE_REVIEW=1` was set, so the finalize held the phase lease. The validator only runs on NEEDS_WORK, so it did not run, and the lease was released.
- The reviewer sandbox was workspace-write. Afterwards `git status` showed only flowctl's ledger (`.flow/specs/gh-8-in-app-updates-through-mt-update.json`), so nothing needed reverting.
- No finding was declined. Nothing was committed after the SHIP except this receipt.

Verification
- baseline: green before any edit. `--filter 'MtUpdate|UpdateInstall|UpdateChecker|AboutSettingsView|MenuBarView|SettingsViewTests'` ran 218 tests, rc 0. Lint found 0 violations in 812 files.
- the same filter on 260dcc1c ran 229 tests (11 new), rc 0.
- mutation check: ten deliberate defects each turned their target test red, and no other test. The sources were restored from HEAD afterwards (`git diff --quiet` on Sources). The defects were an About button that is never disabled, one that does not call the callback, "Include Pre-Releases" shown in mt-update mode, "Check Now" enabled while installing, the install failure hidden, a status line that ignores the build summary, the button shown while installing, a menu item that is never disabled, a clickable installing line, and a menu item that does not call the callback.
- `swift build --build-tests -Xswiftc -DAPPSTORE`: rc 0.
- `./scripts/pre-push.sh --all`: rc 0, "OK — pre-push parity check passed" (release build, App Store release build, test target; the 300 ms type-check flags with warnings as errors).
- `./scripts/lint.sh` with the cached pinned tools: 0/812 files require formatting, 0 violations.
- not run: the app as a user meets it. mt-update mode is active only in `/Applications/MeetingTranscriber-Dev.app`, which only mt-update installs. This branch is not in `branches.txt`, and the fork rules forbid quitting the installed app any other way. Pressing Install would start the real install, which is the owner's check (spec Verification).
- not run: CI's `swiftlint analyze` (`unused_declaration`) needs a clean xcodebuild. After this task the members task 3 named have production callers: `isMtUpdateMode`, `isInstalling` and `availableBuildSummary` (both views), `lastInstallError` (About), `AppState.updateInstallBlockedReason` and `AppState.installUpdate()` (`MeetingTranscriberApp`).

Error-case tests (R-IDs this task satisfies)
- R2 and R3, a failed or unsupported check shows its message and offers no install: `AboutSettingsViewTests.testMtUpdateStatusLineAndWhenInstallIsOffered` (the unsupported row shows "This mt-update cannot report updates to the app yet." with no Install button). The same test covers "Update available: <summary>" and "Up to date".
- R4, both controls disabled while blocked, while a check runs, or without a callback: `AboutSettingsViewTests.testInstallUpdateButtonIsDisabledWhileBlockedCheckingOrUnwired` (About names the reason) and `MenuBarViewTests.testInstallItemIsDisabledWhileBlockedCheckingOrUnwired`. No second install and no check while installing: `testWhileInstallingTheProgressTextReplacesTheButtonAndChecksAreOff` and `MenuBarViewTests.testInstallingShowsAnInertLineAndNoBuildOffersNoItem`. A launch that cannot start shows its cause through `lastInstallError`, the same path as R6.
- R6, a failure is shown in About and Install is offered again: `AboutSettingsViewTests.testTheLastInstallFailureIsShownWithInstallOfferedAgain`.
- R7, a running install shows as running: the two installing tests above. Install offered again after "did not finish": the R6 test, since task 3 keeps that text in `lastInstallError` and restores the summary (A9).
- Wiring, one test per control, located by its `A11yID` constant: `testInstallUpdateButtonCallsTheInstallCallback`, `testInstallItemNamesTheBuildAndCallsTheInstallCallback`.
- Neither identifier is on the `/ui/press` allowlist: `testNeitherInstallControlIsPressableThroughTheAutomationAPI` (`#if !APPSTORE`). GitHub mode unchanged: every existing About, menu and Settings test passed unchanged, plus `testGitHubModeOffersTheReleaseDownloadAndNoInstall`.

Choices
1. Rule 1 (task Approach "a disabled Installing Update… item"; surrounding code). The menu's installing line is a plain `Label`, not a button. That matches the menu's existing disabled line, the "No Microphone" entry in `microphoneSection`. Test: `testInstallingShowsAnInertLineAndNoBuildOffersNoItem` asserts it renders and is no button.
2. Rule 4 (copy placement). The caption "Updates are built on this Mac by mt-update." takes the place of "Include Pre-Releases" right under "Check for Updates". It shows whether or not the check switch is on. flip at: `AboutSettingsView.swift:updatesSection(updateChecker:)`, the `isMtUpdateMode` branch. test: `AboutSettingsViewTests.testMtUpdateModeShowsItsCaptionInsteadOfPreReleases`.
3. Rule 4 (disabled-state wording). While a check runs and no gate reason is set, the disabled About button keeps its caption "Builds the new version (about 5–10 minutes), then restarts Meeting Transcriber.". The spinner on "Check Now" is then the only sign of the check. The task Approach separates "a reason is set" from "a check runs" and shows "the reason or" the caption, and `UpdateInstallGate` has no check input. R4 can also be read as asking About to name the running check. flip at: `AboutSettingsView.swift:mtUpdateInstallRows(updateChecker:)`, the caption `Text`. test: `AboutSettingsViewTests.testInstallUpdateButtonIsDisabledWhileBlockedCheckingOrUnwired` (the "checking" row).
4. Rule 4 (icons). About's "Install Update" uses `arrow.down.to.line`, the icon of GitHub mode's Download button. The menu item uses `arrow.down.circle.fill`, the icon of GitHub mode's menu item. The installing line uses `arrow.triangle.2.circlepath`. flip at: the `systemImage` of each `Label` in `AboutSettingsView.mtUpdateInstallRows` and `MenuBarView.mtUpdateItem`. test: none pins icons (CLAUDE.md GUI Testing keeps visual appearance manual). `testInstallItemNamesTheBuildAndCallsTheInstallCallback` covers the item that carries one.
5. Rule 1 (R4 "About naming the reason"). The menu item names no reason and has no tooltip. Only About names it.
6. Rule 1 (spec Edge Cases, "About keeps a live failure on screen until the next check or install"; R6). `lastInstallError` shows below the install rows, also while the build is offered again. Test: `testTheLastInstallFailureIsShownWithInstallOfferedAgain`.
7. Rule 6. The `/ui/press` exclusion is pinned by a test rather than a do-not-add comment. The `A11yID` doc names that test.
8. Rule 6. Round 1 ran one reviewer. The diff is one feature's UI plus its wiring, and it touches no persisted or shared state, concurrency, security or data layout (impl-review SKILL.md panel rule).
9. Rule 6. The About status line reads the name through `availableUpdateName(_:)` (`availableUpdate?.tagName ?? availableBuildSummary`), so GitHub mode's text stays the same. Tests: `testGitHubModeOffersTheReleaseDownloadAndNoInstall`, `testMtUpdateStatusLineAndWhenInstallIsOffered`.
10. Rule 6. The new inputs are optional `var`s with implicit nil on `AboutSettingsView`, `MenuBarView` and `SettingsView`, so existing memberwise call sites compile unchanged. Each view's test helper gained two defaulted parameters. The tests pass a named no-op closure (`wiredInstall`) instead of `{}` to satisfy SwiftLint's `trailing_closure` rule.

Follow-ups: none. No feature map exists (`.flow/features/` absent), so no route changed there.

stage: plan-sync - skipped(config: planSync.enabled != true)
Conductor fix after the task's SHIP, before the completion review (11a1c74e): About now names the running check as the reason Install Update is disabled (R4, rule 1), with the test row `checking` in `testInstallUpdateButtonIsDisabledWhileBlockedCheckingOrUnwired` expecting "Not available while checking for updates."; task 4's Choice 3 (the caption kept during a check) is withdrawn.

## Evidence
- Commits: 260dcc1c508d53b11cbe902ab2e02628caa4bfda, 11a1c74e7e65b82d56156b1c25d734c7a376ae28
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh-8-test-home swift test --parallel --filter 'MtUpdate|UpdateInstall|UpdateChecker|AboutSettingsView|MenuBarView|SettingsViewTests' (229 tests, rc 0), cd app/MeetingTranscriber && swift build --build-tests -Xswiftc -DAPPSTORE (rc 0), ./scripts/pre-push.sh --all (rc 0), PATH=$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH ./scripts/lint.sh (0 violations, 0/812 need formatting)
- PRs: