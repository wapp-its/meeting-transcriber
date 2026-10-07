---
satisfies: [R1, R2, R3, R4, R6, R7]
---
# gh-1-request-permissions-from-settings.2 Request buttons, restart note and popover change in Settings → Advanced → Permissions

## Description
Wires task 1's requester into Settings → Advanced → Permissions: one button per row, the Screen Recording restart note, the new Microphone wording, and the popover without its own "Open System Settings" button. Split from task 1 so the views land on a decision and executor that are already tested.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/PermissionRow.swift`, `app/MeetingTranscriber/Sources/Settings/AdvancedSettingsView.swift`, `app/MeetingTranscriber/Sources/A11yID.swift`, `app/MeetingTranscriber/Tests/AdvancedSettingsPermissionsTests.swift` (new), `app/MeetingTranscriber/Tests/PermissionRowTests.swift` (only if a signature change requires it)
**Touches:** [app/MeetingTranscriber/Sources/PermissionRow.swift, app/MeetingTranscriber/Sources/Settings/AdvancedSettingsView.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/AdvancedSettingsPermissionsTests.swift, app/MeetingTranscriber/Tests/PermissionRowTests.swift]

### Approach

- **Measure first:** before editing, record `AdvancedSettingsView.body`'s type-check time (command under Verification) so the after-reading has a baseline.
- `PermissionRow` (`app/MeetingTranscriber/Sources/PermissionRow.swift`): drop `settingsURL` and the popover's "Open System Settings" button (`:50-57`); keep the help text popover and the `optional`/`warning` flags (`PermissionHealthCheck` documents that the Accessibility row is labelled optional through `PermissionRow(optional: true)`). Add an optional trailing action (title, accessibility identifier, closure), rendered as a small push button (`.controlSize(.small)`) before the "?" button, with `.accessibilityIdentifier` on the `Button` itself so `find(viewWithAccessibilityIdentifier:).button()` reaches it.
- `A11yID` (`app/MeetingTranscriber/Sources/A11yID.swift`): add `static func permissionRequestButton(_ kind: PermissionKind) -> String` returning `"permissionRequestButton.\(kind.rawValue)"` and `static let screenRecordingRestartNote = "screenRecordingRestartNote"`, next to the other Settings entries, each with a one-line doc comment. Do not add either to the `/ui/press` allowlist (`app/MeetingTranscriber/Sources/DebugRPCServer+UIPress.swift`): the action raises system dialogs and opens another app.
- `AdvancedSettingsView` (`app/MeetingTranscriber/Sources/Settings/AdvancedSettingsView.swift`):
  - delete `PrivacyPane` (`:10-18`); rows use `PermissionKind`;
  - add `var requestAccess: @MainActor (PermissionKind) async -> Void = { await PermissionAccessRequester.live.run($0) }`, so `SettingsView.swift:91` (`AdvancedSettingsView(settings: settings)`) and the tests' `makeAdvanced` keep compiling;
  - move the whole Permissions `Section` (`:36-67`) out of `body` into a named property, the way issue #17 split `TranscriptionSettingsView` (`app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift:38`, `private var transcriptionSection: some View`), so `body` gets cheaper rather than larger;
  - each row's button: title `PermissionAccessStep.decide(kind:state:canRequestAccessibility:).buttonTitle` over the row's current `@State` (map `micPermission` with `PermissionAccessState(microphone:)`, the two Bools to granted/notGranted, and take `canRequestAccessibility` from the live requester); action `Task { await requestAccess(kind); refreshPermissions() }`;
  - Microphone detail: `.notDetermined` reads "Not requested yet" (replacing "Will prompt on first recording"); the other two branches stay;
  - while `!screenRecordingOK`, a caption under the Screen Recording row: "Screen Recording takes effect only after you quit and reopen Meeting Transcriber." (`.font(.caption)`, `.foregroundStyle(.secondary)`, identifier `A11yID.screenRecordingRestartNote`), styled like the Diagnostics captions in the same file (`:72-80`).
- Tests in a new `AdvancedSettingsPermissionsTests` (`@MainActor`, isolated `UserDefaults` suite as in `app/MeetingTranscriber/Tests/GeneralSettingsConsentDenyListTests.swift:11-18`): one wiring test per button: build the view with an injected `requestAccess` that records the kind and fulfils an `XCTestExpectation`, `find(viewWithAccessibilityIdentifier: A11yID.permissionRequestButton(kind)).button().tap()` (pattern: `app/MeetingTranscriber/Tests/MenuBarViewTests.swift:606-613`), `await fulfillment(of:timeout:)`, assert the recorded kind equals the tapped row's kind (so a row wired to the wrong kind fails). One test that `A11yID.screenRecordingRestartNote` is present in the default view (the `@State` starts not granted and ViewInspector does not run `.onAppear`).

### Investigation targets

**Required** (read before coding):
- `app/MeetingTranscriber/Sources/Settings/AdvancedSettingsView.swift:10-67,138-142` — section, state, refresh
- `app/MeetingTranscriber/Sources/PermissionRow.swift` — the row to extend
- `app/MeetingTranscriber/Tests/SettingsViewTests.swift:90-92,492-498` — `makeAdvanced` and `testPermissionsSectionExists`, which must stay green
- `app/MeetingTranscriber/Tests/MenuBarViewTests.swift:599-613` — find-by-identifier, `.button().tap()`

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/Settings/TranscriptionSettingsView.swift` — named section properties used to keep `body` under the type-check budget
- `app/MeetingTranscriber/Tests/PermissionRowTests.swift` — row rendering tests

### Key context

- **GUI testing rule (CLAUDE.md "GUI Testing"):** logic states belong to task 1's pure tests; here exactly one wiring test per button. A tap that writes `@State` cannot be asserted through ViewInspector (it lands in a copy), so assert the injected callback, not the refreshed status. The real TCC prompt and System Settings are manual-QA-only; never call the live requester in a test.
- The button action runs in a `Task`, so the wiring test must await the expectation; a synchronous assert right after `tap()` would pass or fail by timing.
- After the injected callback, `refreshPermissions()` runs in the test process: it only reads statuses (`CGPreflightScreenCaptureAccess`, window list, `AVCaptureDevice.authorizationStatus`, `AXIsProcessTrusted`) and raises no prompt.
- Type-check budget: the build passes `-warn-long-function-bodies=300` (`app/MeetingTranscriber/Package.swift:68-70`), and issue #20 already lists `AdvancedSettingsView.body` at up to 118 ms on CI runners; a local reading only shows the direction.

### Verification

```bash
(cd app/MeetingTranscriber && swift build -Xswiftc -Xfrontend -Xswiftc -debug-time-function-bodies > /private/tmp/mt-gh-1-typecheck.log 2>&1; echo "exit=$?")
```

Run it once before editing (baseline) and once after, then read the `AdvancedSettingsView` lines from each log file (copy the log between runs; a no-op incremental build prints nothing for unchanged files).

Run each command from the repository root (each is its own subshell).

```bash
mkdir -p /private/tmp/mt-gh-1-home
(cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh-1-home swift test --parallel --filter 'AdvancedSettingsPermissionsTests|PermissionRowTests|SettingsViewTests|PermissionAccessRequestTests' > /private/tmp/mt-gh-1-t2-tests.log 2>&1; echo "exit=$?")
(cd app/MeetingTranscriber && swift build --build-path /private/tmp/mt-gh-1-appstore-build -Xswiftc -DAPPSTORE > /private/tmp/mt-gh-1-t2-appstore.log 2>&1; echo "exit=$?")
```

Read the log files, never pipe the runs into `tail`/`grep`. Lint with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 from `scripts/tool-versions.sh`, fetched with SHA-256 check into a scratch dir: `PATH=<that dir>:$PATH ./scripts/lint.sh`.
## Acceptance
- [ ] Each of the three rows shows a button with identifier `A11yID.permissionRequestButton(kind)`, titled by `PermissionAccessStep.decide(…).buttonTitle` for the row's current status; a click runs `requestAccess(kind)` and then re-reads the three statuses.
- [ ] `AdvancedSettingsView` has an injectable `requestAccess` defaulting to the live requester; `SettingsView` and the existing tests compile unchanged.
- [ ] `PrivacyPane` is gone; the deep links come only from `PermissionKind.settingsURL`.
- [ ] `PermissionRow` no longer takes `settingsURL` and its popover has no "Open System Settings" button; help text, icons and the `optional`/`warning` flags are unchanged.
- [ ] The Microphone row's not-determined detail reads "Not requested yet".
- [ ] While Screen Recording is not granted, the note "Screen Recording takes effect only after you quit and reopen Meeting Transcriber." is shown with identifier `A11yID.screenRecordingRestartNote`.
- [ ] The Permissions section lives in a named property outside `body`; the after-change local type-check reading of `AdvancedSettingsView.body` is not above the before-change reading (both numbers in the task's done summary).
- [ ] `AdvancedSettingsPermissionsTests` has one wiring test per button (asserting the received kind after awaiting the injected callback) and one restart-note test; they, `PermissionRowTests`, `SettingsViewTests` and `PermissionAccessRequestTests` pass; neither new identifier is on the `/ui/press` allowlist.
- [ ] The App Store variant builds and lint is clean with the pinned tools.
## Done summary
Someone setting the app up before their first meeting can now get Meeting Transcriber listed in System Settings from Settings → Advanced → Permissions. Each of the three rows (Screen Recording, Microphone, Accessibility) has its own button. It asks macOS where asking can still list the app, then opens that permission's page. A permission granted at the click only opens the page. Screen Recording shows a restart note while it is not granted.

- `PermissionRow` (`Sources/PermissionRow.swift`) takes an optional trailing `Action` (title, identifier, closure). The action renders as a small push button before the "?" button, with the identifier on the `Button`. The `settingsURL` parameter is gone, and so is the popover's "Open System Settings" button. The popover keeps its help text, and the icons and the `optional`/`warning` flags are unchanged (R7).
- `AdvancedSettingsView` (`Sources/Settings/AdvancedSettingsView.swift`) loses the private `PrivacyPane` enum, so the deep links now come only from `PermissionKind.settingsURL`. It gains `var requestAccess: @MainActor (PermissionKind) async -> Void`, which defaults to `PermissionAccessRequester.live.run`. `SettingsView.swift` and `SettingsViewTests.makeAdvanced` compile unchanged. Each row's button title is `PermissionAccessStep.decide(...).buttonTitle` over the row's current state, with `canRequestAccessibility` taken from the live requester. A click runs `Task { await requestAccess(kind); refreshPermissions() }` (R1, R2, R6). The Microphone row's not-determined detail reads "Not requested yet" (R3). While Screen Recording is not granted, a caption with identifier `screenRecordingRestartNote` says it takes effect only after the app is quit and reopened (R4).
- The Permissions `Section` moved out of `body` into `private var permissionsSection`. The local type-check reading of `AdvancedSettingsView.body` went from 51.04-51.61 ms (median 51.32 ms, 5 readings) to 42.29-43.59 ms (median 42.87 ms, 5 readings). Every after-reading is below every before-reading. The new `permissionsSection` getter reads about 10 ms. Method: each reading is an incremental single-file recompile. It ran `swift build --build-system native --build-path /private/tmp/mt-gh-1-t2-tc-native -Xswiftc -Xfrontend -Xswiftc -debug-time-function-bodies` after a `touch` of the file. The task's Verification command printed nothing, because the default `swiftbuild` build system drops the frontend's timing output. A fresh full native build read 27.69 ms before the change, so compare readings only within one method. Logs are `/private/tmp/mt-gh-1-t2-typecheck-before5.log`, `/private/tmp/mt-gh-1-t2-typecheck-before6.log`, `/private/tmp/mt-gh-1-t2-tc-b7.log` to `b10.log` (before), and `/private/tmp/mt-gh-1-t2-tc-a1.log` to `a5.log` (after).
- `A11yID` gains `permissionRequestButton(_:)` (`permissionRequestButton.<rawValue>`) and `screenRecordingRestartNote`. Neither is on the `/ui/press` allowlist.
- Tests. The new `AdvancedSettingsPermissionsTests` has one wiring test per button. Each asserts the button's title in the default state, taps it, awaits the injected `requestAccess` and asserts it received exactly that row's kind. The Accessibility title expectation is "Open System Settings" under `APPSTORE`. Two more tests check the restart note's identifier and wording, and the "Not requested yet" detail. No test runs the live requester. A disposable mutation that routed every click to `.microphone` turned the Screen Recording and Accessibility tests red, and the source was restored byte-identical afterwards. `PermissionRowTests` needed no change.
- Verification on HEAD 583ebcc2. `swift test --parallel --filter 'PermissionAccessRequestTests|AdvancedSettingsPermissionsTests|PermissionRowTests|SettingsViewTests'` exited 0 with 105 tests run, 5 of them new. The App Store build (`-Xswiftc -DAPPSTORE`) exited 0. `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 found 0 violations in 664 files. The two lint findings were a now-superfluous `closure_body_length` disable in `PermissionRow` and a 35-line `Section` closure in `permissionsSection`, which carries the same disable as the Diagnostics section. Both were fixed before the commit. CI's `swiftlint analyze` (`unused_declaration`) was not run locally; every new declaration has a caller.
- Decisions. The commit message carries no `Task:` trailer and no spec id, per the fork rule for the original's readers. The review ran one reviewer, the correctness lens. The panel rule allows one because the diff is one feature's Settings UI and touches no persisted or shared state, security or data layout.
- Feature map. The route to the Permissions rows is unchanged (Settings → Advanced → Permissions). The rows gain a button, and the "?" popover no longer opens System Settings.
- Human check still open. TCC prompts are manual-QA-only. With the three grants reset for the installed dev build, each button should list the app in its System Settings page. With a grant in place, a click should open the page with no dialog.

baseline: green via handoff (verified at 6804fe86 by gh-1-request-permissions-from-settings.1; only .flow/ changed since)
stage: impl-review - ran [..2026-10-07T03:50:37Z] (codex gpt-5.6-sol xhigh, 1 draw correctness, SHIP on round 1, 0 findings; validator not run because it runs only on NEEDS_WORK)
Tier: session (jev-unavailable(no_key)) - actual_model: claude-opus-5-5 (host metadata)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 583ebcc2c044e7436ee139789a4887e8d2caa825
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh-1-home swift test --parallel --filter 'PermissionAccessRequestTests|AdvancedSettingsPermissionsTests|PermissionRowTests|SettingsViewTests' (exit 0, 105 tests), cd app/MeetingTranscriber && swift build --build-path /private/tmp/mt-gh-1-appstore-build -Xswiftc -DAPPSTORE (exit 0), PATH=~/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH ./scripts/lint.sh (exit 0, 0 violations in 664 files)
- PRs: