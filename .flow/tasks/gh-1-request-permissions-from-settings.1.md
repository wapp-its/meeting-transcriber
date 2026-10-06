---
satisfies: [R1, R2, R3, R5, R6]
---
# gh-1-request-permissions-from-settings.1 Permission request decision, executor and deliberate Screen Recording request

## Description
Builds the pure decision and the small executor behind the new Settings buttons (spec "Architecture & Data Models", new contracts), plus the deliberate Screen Recording request. No UI in this task: it proves the core approach (Early proof point) with tests that never touch TCC, so task 2 only wires views onto checked ground.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/PermissionAccessRequest.swift` (new), `app/MeetingTranscriber/Sources/Permissions.swift`, `app/MeetingTranscriber/Tests/PermissionAccessRequestTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/PermissionAccessRequest.swift, app/MeetingTranscriber/Sources/Permissions.swift, app/MeetingTranscriber/Tests/PermissionAccessRequestTests.swift]

### Approach

- **Tests first** (the contract is fully stated in the spec): write `PermissionAccessRequestTests` covering the whole decision table (3 kinds × 3 states, accessibility with `canRequestAccessibility` true and false), `PermissionAccessState(microphone:)` for `.authorized`, `.notDetermined`, `.denied`, `.restricted`, the three `settingsURL` strings, both `buttonTitle`s, and the executor. Add the types with a trivial body (e.g. `decide` always returning `.openSettings`, `run` doing nothing), run the tests, see the table and executor cases fail for that reason, then implement.
- Pure decision functions follow the shape of `PermissionHealthCheck.checkAccessibility(trusted:probe:)` (`app/MeetingTranscriber/Sources/PermissionHealthCheck.swift:473-482`, with `checkMicrophone(authStatus:probeSucceeds:)` at `:244-261` as the closest analogue for the microphone status mapping): a static function over plain values, no I/O, the I/O wrapper separate.
- The executor's injected effects follow the closure-seam style of `WatchingController.init` (`app/MeetingTranscriber/Sources/WatchingController.swift:123-137`): plain closures with production defaults bound in one place (`static var live`), tests pass their own.
- Executor tests record effects in an array (e.g. `["request(microphone)", "open(<url>)"]`): `requestThenOpenSettings` gives request then exactly one open of that kind's URL; a granted state gives exactly one open and no request (the "no extra dialog" proof); make the `request` closure `await Task.yield()` before recording, so the test also proves `run` awaits it before opening; build the requester while the state closure reads `.notDetermined`, change the captured value to `.granted`, then call `run`, and assert no request happened (state read at click time).
- `live`: state from `CGPreflightScreenCaptureAccess()`, `AVCaptureDevice.authorizationStatus(for: .audio)` (through `PermissionAccessState(microphone:)`) and `AXIsProcessTrusted()`; request from `Permissions.requestScreenRecordingAccess()`, `_ = await Permissions.ensureMicrophoneAccess()`, and `Permissions.ensureAccessibilityAccess()` wrapped in `#if !APPSTORE` exactly like `WatchingController.swift:133-136`; `canRequestAccessibility` from `#if APPSTORE false #else true`; `openURL` via `NSWorkspace.shared.open`.
- `Permissions.requestScreenRecordingAccess()` goes next to `ensureScreenRecordingAccess()` (`app/MeetingTranscriber/Sources/Permissions.swift:39-62`): guard on `CGPreflightScreenCaptureAccess()`, then `_ = CGRequestScreenCaptureAccess()`. It must not touch `screenRecordingPromptLock` or call `claimFirst`, and must not log the `false` return as a denial (see the reasoning at `Permissions.swift:91-96`). A doc comment says why it exists beside its once-per-session sibling. Leave `ensureScreenRecordingAccess()` byte-for-byte unchanged.

### Investigation targets

**Required** (read before coding):
- `app/MeetingTranscriber/Sources/Permissions.swift:11-105` — the three existing request calls and why each behaves as it does
- `app/MeetingTranscriber/Sources/Settings/AdvancedSettingsView.swift:10-18` — `PrivacyPane`, the three deep-link strings to copy into `PermissionKind.settingsURL` (task 2 deletes `PrivacyPane`)
- `app/MeetingTranscriber/Sources/WatchingController.swift:123-137` — seam style and the `#if !APPSTORE` Accessibility default

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/PermissionHealthCheckTests.swift` — style of pure permission-decision tests
- `app/MeetingTranscriber/Tests/WatchingControllerTests.swift:28-70` — injecting request closures and asserting they ran

### Key context

- **No test may call `PermissionAccessRequester.live.run`, `Permissions.requestScreenRecordingAccess()` or any TCC request**: a real prompt in xctest hangs or pollutes the machine's TCC state.
- `CGRequestScreenCaptureAccess()` may return before the person answers; do not wrap it in a detached task or wait on it.
- `PermissionAccessRequester` is `@MainActor` (it opens URLs and is called from a view). `Permissions.ensureMicrophoneAccess()` is a nonisolated `async` function; awaiting it from the main actor is fine. Run `./scripts/pre-push.sh --with-appstore` (release builds of both variants) if a Sendable diagnostic is suspected, since release mode surfaces some that debug tolerates.
- The App Store variant must compile: `ensureAccessibilityAccess` exists in both variants, but the live binding must not call it under `APPSTORE`.

### Verification

Run each command from the repository root (each is its own subshell).

```bash
mkdir -p /private/tmp/mt-gh-1-home
(cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh-1-home swift test --parallel --filter 'PermissionAccessRequestTests|WatchingControllerTests' > /private/tmp/mt-gh-1-t1-tests.log 2>&1; echo "exit=$?")
(cd app/MeetingTranscriber && swift build --build-path /private/tmp/mt-gh-1-appstore-build -Xswiftc -DAPPSTORE > /private/tmp/mt-gh-1-t1-appstore.log 2>&1; echo "exit=$?")
```

Do not add `PermissionsTests` to the filter: it calls the live microphone request. Read the log files, never pipe the run into `tail`/`grep`. Lint with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 from `scripts/tool-versions.sh`: they are not installed globally, so fetch the pinned release assets (verify the SHA-256 from that file) into a scratch dir and run `PATH=<that dir>:$PATH ./scripts/lint.sh`; never `brew install` them.
## Acceptance
- [ ] `PermissionKind`, `PermissionAccessState` (with `init(microphone:)`), `PermissionAccessStep` (with `decide(kind:state:canRequestAccessibility:)` and `buttonTitle`) and `@MainActor PermissionAccessRequester` (with `run(_:)` and `static var live`) exist with the signatures the spec names, in `Sources/PermissionAccessRequest.swift`.
- [ ] `PermissionAccessRequestTests` covers every decision-table cell including accessibility with `canRequestAccessibility` false, the four microphone status mappings, the three deep-link strings, both button titles, and the executor's effects: request before exactly one open for `requestThenOpenSettings`, exactly one open and no request for a granted state, `run` awaiting the request before opening, and state read when `run` is called. The tests were seen failing against the trivial stub before the implementation.
- [ ] `Permissions.requestScreenRecordingAccess()` exists, does not reference `screenRecordingPromptLock`/`claimFirst`, does not log a denial, and `ensureScreenRecordingAccess()` is unchanged (`git diff` shows no edit inside it).
- [ ] The live requester never requests Accessibility in the App Store build (`#if !APPSTORE` around the call, `canRequestAccessibility` false there).
- [ ] No test calls the live requester or any TCC request API.
- [ ] Focused tests pass (`exit=0` in the log), the App Store variant builds, and lint is clean with the pinned tools.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
