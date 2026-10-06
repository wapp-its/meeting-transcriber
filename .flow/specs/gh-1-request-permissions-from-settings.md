# Request permissions from Settings

## Conversation Evidence

> issue #1 (Problem, translated): "Under **Settings → Advanced → Permissions**, 'Open Settings' leads to the right page of macOS System Settings, but the app is not in the list there yet. macOS only adds it once the app has asked for the permission once, and today that only happens at the first meeting or the first recording (`Permissions.swift`: Screen Recording when meeting detection starts, Microphone 'Will prompt on first recording'). Anyone who wants to set the app up beforehand has to start a meeting first."
> issue #1 (Wish, translated): "Per permission (Screen Recording, Microphone, Accessibility) a button **'Request and open System Settings'** that 1. requests the permission (`CGRequestScreenCaptureAccess()`, `AVCaptureDevice.requestAccess(for: .audio)`, `AXIsProcessTrustedWithOptions` with prompt) and thereby lists the app, 2. then opens the matching page (the links already exist: `PrivacyPane` in `AdvancedSettingsView.swift`). Optionally the same as a step at first launch."
> issue #1 (Notes, translated): "Screen Recording only takes effect after a restart of the app; point this out in the UI." · "`ensureScreenRecordingAccess()` asks only once per session (`claimFirst`); the button needs its own, deliberately triggered path."
> issue #1 (Acceptance, translated): "Fresh install, no meeting yet: click the button → the app appears in the respective list in System Settings and can be switched on there." · "Permission already granted: the button only opens the page, no additional dialog."
> coordinator triage 2026-10-06: "prio:now. Per permission in Settings → Advanced → Permissions a button that requests the permission (so macOS lists the app in System Settings) and then opens the matching System Settings page; already granted → only opens the page, no extra dialog. Screen Recording takes effect only after an app restart: say so in the UI."
> coordinator triage 2026-10-06: "Check which permissions the section shows today […] and cover each one the section shows. `ensureScreenRecordingAccess()` asks once per session (`claimFirst`): the button needs its own deliberate path." · "The optional 'same as a first-launch step' from the issue is out of scope (Boundaries, follow-up)." · "TCC prompts are manual-QA-only […]: plan pure-logic tests for the decision (granted → open page only; not determined → request then open) and one wiring test per button; the real prompt is a human check."

## Goal & Context

<!-- Source: 10% user / 50% [paraphrase] / 40% [inferred] -->

macOS lists an app under Privacy & Security only after the app has asked for that permission once. The Permissions section in Settings → Advanced shows three rows (Screen Recording, Microphone, Accessibility), each with a "?" popover whose "Open System Settings" button opens the right page, but on a fresh install the app is not in that page's list, so there is nothing to switch on. The person setting the app up wants one button per permission that makes macOS list the app and then opens the page, so the whole setup can be done from Settings before the first meeting. [paraphrase]

Checked against the code on 2026-10-06, the issue's description is partly outdated: Microphone and Screen Recording are requested at every watch start (Start Watching in the menu, auto-watch at launch and the automation API's watch start all go through the same start path), not only at the first meeting, and Accessibility only on a deliberate Start Watching with Teams watching on. So "press Start Watching once" is an existing workaround for two of the three, but nobody would guess it, it does not cover Accessibility without Teams, and the Microphone row's "Will prompt on first recording" text is wrong today. The issue's ask stands. [inferred]

Must-first slice: one button per existing row and the restart note for Screen Recording, nothing else. [inferred]

## Architecture & Data Models

**Today:** the Permissions section builds three `PermissionRow`s (status icon, label, detail, a "?" popover with help text and an "Open System Settings" button) plus a "Refresh" button, and keeps the three statuses in view-local state filled on appear and on Refresh. The three System Settings deep links live in a private `PrivacyPane` enum inside the Advanced settings view. The request calls live in `Permissions`: `ensureScreenRecordingAccess()` (preflight, then a once-per-session flag, then `CGRequestScreenCaptureAccess()`), `ensureMicrophoneAccess()` (requests only while the status is not determined, logs a real denial) and `ensureAccessibilityAccess()` (prompting `AXIsProcessTrustedWithOptions`, no one-shot flag, deliberately silent). Their only caller is the watch start, which compiles the Accessibility request out of the App Store build. [inferred]

**New contracts:** [inferred]
- `enum PermissionKind: String, CaseIterable { case screenRecording, microphone, accessibility }` with `var settingsURL: URL`: the three existing deep links (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`, `…?Privacy_Microphone`, `…?Privacy_Accessibility`), moved from `PrivacyPane`, which goes away.
- `enum PermissionAccessState: Equatable { case granted, notDetermined, notGranted }` with `init(microphone: AVAuthorizationStatus)`: `.authorized` → granted, `.notDetermined` → notDetermined, `.denied`/`.restricted`/unknown → notGranted. Screen Recording and Accessibility only ever report granted or notGranted: macOS has no public "not yet asked" state for them.
- `enum PermissionAccessStep: Equatable { case openSettings, requestThenOpenSettings }` with `static func decide(kind: PermissionKind, state: PermissionAccessState, canRequestAccessibility: Bool) -> PermissionAccessStep` and `var buttonTitle: String` ("Request & Open System Settings" for `requestThenOpenSettings`, "Open System Settings" for `openSettings`). Decision table:

| kind | granted | notDetermined | notGranted |
|---|---|---|---|
| screenRecording | openSettings | requestThenOpenSettings | requestThenOpenSettings |
| microphone | openSettings | requestThenOpenSettings | openSettings |
| accessibility | openSettings | requestThenOpenSettings if `canRequestAccessibility`, else openSettings | same as notDetermined |

- `@MainActor struct PermissionAccessRequester` with injected effects `currentState: (PermissionKind) -> PermissionAccessState`, `request: (PermissionKind) async -> Void`, `openURL: (URL) -> Void` and a `canRequestAccessibility: Bool`. `func run(_ kind: PermissionKind) async` reads `currentState(kind)` when called, decides, awaits `request(kind)` only for `requestThenOpenSettings`, then calls `openURL(kind.settingsURL)` exactly once. `static var live` binds the real calls: state from `CGPreflightScreenCaptureAccess()`, `AVCaptureDevice.authorizationStatus(for: .audio)` and `AXIsProcessTrusted()`; requests to `Permissions.requestScreenRecordingAccess()` (new), `Permissions.ensureMicrophoneAccess()` and, outside the App Store build only, `Permissions.ensureAccessibilityAccess()`; `canRequestAccessibility` is false in the App Store build and true otherwise; `openURL` opens the URL with `NSWorkspace`.
- `Permissions.requestScreenRecordingAccess()`: the deliberate path. It returns at once when `CGPreflightScreenCaptureAccess()` is true, otherwise calls `CGRequestScreenCaptureAccess()`. It neither reads nor sets the once-per-session flag of `ensureScreenRecordingAccess()`, which stays unchanged, and it does not log the call's `false` return as a denial (the call can return before the person answers, the reason `ensureAccessibilityAccess` is silent). [paraphrase]
- `PermissionRow` gains an optional trailing action button (title, accessibility identifier, action). Its "?" popover keeps the help text and loses its own "Open System Settings" button and the `settingsURL` parameter. [inferred]
- The Advanced settings view gains an injectable `requestAccess: @MainActor (PermissionKind) async -> Void`, defaulting to the live requester, so its existing call site compiles unchanged. Each row's button title is `PermissionAccessStep.decide(…).buttonTitle` over the row's current status; its action runs `requestAccess(kind)` in a `Task` and then re-reads the three statuses. The Permissions section moves out of `body` into a named view property, because `AdvancedSettingsView.body` is already listed among the slowest type-checks against the build's 300 ms limit (issue #20) and must not grow.
- `A11yID.permissionRequestButton(_ kind: PermissionKind) -> String` (`"permissionRequestButton.<rawValue>"`) and `A11yID.screenRecordingRestartNote`. Neither joins the `/ui/press` allowlist.

## Edge Cases & Constraints

- **Status is read at click time, not from the row.** The row's status can be stale (granted in System Settings while the Settings window stayed open); `run` asks macOS again, so a permission granted in the meantime gets the page only and no dialog, even if the button still reads "Request & Open System Settings". [inferred]
- **Screen Recording and Accessibility requests can return before the person answers.** Their system alert (offering "Open System Settings" / "Deny") may still be on screen when the page opens. Accepted: the issue asks for both steps, and the app is already listed when the page opens. [inferred]
- **Screen Recording asked before** (denied, or dismissed at an earlier watch start): whether macOS shows its alert again is up to macOS; either way the app is already listed and the page opens. [inferred]
- **Microphone:** `requestAccess` waits for the answer, so the page opens after the dialog is closed. Denied or restricted: macOS never asks twice, so the click only opens the page, where the person can switch it on. [inferred]
- **Accessibility asked before but not granted:** the prompting call shows its alert again on each click (it has no one-shot flag, by design). Accepted: each click is deliberate. [inferred]
- **Screen Recording takes effect only after the app restarts;** until then the row may still read not granted, which the restart note explains. [paraphrase]
- **App Store build:** Screen Recording and Microphone behave as in the native build; the Accessibility button only opens the page, matching the watch start, which never requests Accessibility in the sandboxed build. [inferred]
- **Double click while the Microphone dialog is open:** macOS shows one dialog; the page may open twice, which is harmless. [inferred]
- **Watch start unchanged:** its permission requests and the Screen Recording once-per-session flag keep their behaviour. [paraphrase]
- **No test may raise a real TCC prompt or open System Settings:** every test injects `currentState`/`request`/`openURL` or `requestAccess`; no test runs the live requester. [inferred]

### Verification

- Pure logic: the whole decision table (every kind × state, both values of `canRequestAccessibility`), the microphone status mapping, the three deep links, both button titles, and the executor with recorded effects: `requestThenOpenSettings` awaits `request(kind)` before `openURL(kind.settingsURL)`; `openSettings` (granted) calls `openURL` once and never `request`, which proves "no extra dialog" at the logic layer; the state is read when `run` is called, not when the requester is built. [inferred]
- View wiring (ViewInspector): one test per button that finds it by `A11yID.permissionRequestButton(kind)`, taps it, awaits the injected `requestAccess` and asserts it received that kind; one test that the restart note is present in the view's default (not granted) state. Existing `PermissionRowTests` and the Settings view tests stay green. [inferred]
- Both variants build (`swift build` and `swift build -Xswiftc -DAPPSTORE`), lint is clean with the pinned tools, and `AdvancedSettingsView.body`'s local type-check time is not above its reading before the change. [inferred]
- Human check (TCC prompts are manual-QA-only per CLAUDE.md "GUI Testing"): with the three grants reset for the installed dev build, each button lists the app in its System Settings page; with a grant in place, a click opens the page with no dialog. [paraphrase]

## Acceptance Criteria

- **R1:** Each of the three rows in Settings → Advanced → Permissions (Screen Recording, Microphone, Accessibility) shows a button. When the permission is not granted and macOS can still be asked, the button reads "Request & Open System Settings"; a click asks macOS for that permission, which adds the app to that permission's list in System Settings, and then opens that permission's System Settings page. After the action finishes, the section re-reads all three statuses. Errors: a refused or dismissed request still opens the page; a refused Microphone request is logged as today (`permission_denied resource=microphone`), and the status re-read keeps logging its existing `permission_denied resource=screen_recording` warning while Screen Recording is not granted, exactly as the Refresh button does today; nothing else is reported as an error. [paraphrase]
- **R2:** When the permission is already granted at the moment of the click (read from macOS then, not from the row's last refresh), the click only opens that permission's page and no system dialog appears; the button reads "Open System Settings" while the row shows the permission as granted. Errors: none beyond R1. [paraphrase]
- **R3:** Microphone: if macOS has not asked yet, the macOS microphone dialog appears and the page opens after it has been answered; if the microphone was denied or is restricted, the click only opens the page. The row's detail for "not asked yet" reads "Not requested yet" instead of "Will prompt on first recording". Errors: none beyond R1. [inferred]
- **R4:** While Screen Recording is not granted, the Screen Recording row shows the note "Screen Recording takes effect only after you quit and reopen Meeting Transcriber." Errors: none. [paraphrase]
- **R5:** The button's Screen Recording request is its own deliberate path: it does not use or consume the once-per-session flag of `ensureScreenRecordingAccess()`, and the permission requests at watch start behave exactly as before. Errors: none. [paraphrase]
- **R6:** In the App Store build the Accessibility button only opens the Accessibility page and never asks macOS for Accessibility; Screen Recording and Microphone behave as in R1–R3. Both build variants compile. Errors: none. [inferred]
- **R7:** The "?" popover of each row keeps its help text but no longer has its own "Open System Settings" button; the row's button is the one way to open the page from the section. Errors: none. [inferred]

## Early proof point

Task gh-1-request-permissions-from-settings.1 validates the core approach (the decision table and the executor's order of effects, with no TCC call in any test). If it fails, re-evaluate the request-then-open design before continuing with gh-1-request-permissions-from-settings.2.

## Quick commands

```bash
mkdir -p /private/tmp/mt-gh-1-home && cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh-1-home swift test --parallel --filter 'PermissionAccessRequestTests|AdvancedSettingsPermissionsTests|PermissionRowTests|SettingsViewTests' > /private/tmp/mt-gh-1-quick.log 2>&1; echo "exit=$?"
```

## Boundaries

- A first-launch step that asks for the permissions (the issue's optional item) is a follow-up spec. [paraphrase]
- No button for the "Audio Recording" grant (`NSAudioCaptureUsageDescription`, the app-audio tap's other sufficient grant) or for notifications: the section does not show them today, the former has no public request or preflight API, and notifications already have their own warning and System Settings link in Settings → General. Follow-up if wanted. [inferred]
- Refreshing the rows automatically when the app becomes active again (after the person returns from System Settings) is a follow-up; the Refresh button stays. [inferred]
- The outdated row descriptions ("Required for meeting detection" on Screen Recording, which detection no longer needs; "enables mute detection" on Accessibility, which does not exist) are not rewritten here; follow-up. [inferred]
- The new buttons are not added to the `/ui/press` allowlist: their action raises system dialogs and opens another app. [inferred]
- No change to the permission health check, the menu-bar badge, the permission notification or the watch-start requests. [inferred]

## Decision Context

- **D1 · Each permission row gets one button that asks macOS for that permission and then opens its System Settings page.** why: issue #1 asks for exactly this per permission (Screen Recording, Microphone, Accessibility), so a fresh install can be set up before the first meeting · status: active [owner-stated 2026-10-06]
- **D2 · An already granted permission only opens the page, with no extra dialog.** why: issue #1 acceptance "Bereits erteilte Berechtigung: Knopf öffnet nur die Seite, kein zusätzlicher Dialog" · status: active [owner-stated 2026-10-06]
- **D3 · The Screen Recording row says the grant takes effect only after the app is restarted.** why: issue #1 note "Bildschirmaufnahme wirkt erst nach einem Neustart der App — im UI darauf hinweisen" · status: active [owner-stated 2026-10-06]
- **D4 · The button uses its own deliberate request path and leaves the watch start's once-per-session Screen Recording flag alone.** why: issue #1 note "der Knopf braucht einen eigenen, bewusst ausgelösten Weg" · status: active [owner-stated 2026-10-06]
- **A1 · The optional first-launch step is out of scope and becomes a follow-up (the issue marks it optional; coordinator triage 2026-10-06 put it out).** flip at: the owner wants onboarding in this spec · test: this spec's diff adds no first-launch UI · status: active [agent-inferred 2026-10-06]
- **A2 · Only the three rows the section shows get a button; Audio Recording (no public request API) and notifications (own warning in Settings → General) do not.** flip at: the owner wants those grants in the section · test: the section still has exactly three rows · status: active [agent-inferred 2026-10-06]
- **A3 · A denied or restricted microphone only opens the page, without a request, because macOS asks for the microphone only while the status is not determined.** flip at: macOS starts asking twice · test: decision-table case microphone/notGranted → openSettings · status: active [agent-inferred 2026-10-06]
- **A4 · For the microphone, the page opens after the macOS dialog has been answered, even after "Allow".** flip at: the owner finds the page after an Allow superfluous · test: executor test that request completes before openURL · status: active [agent-assumed 2026-10-06]
- **A5 · The "?" popover loses its own "Open System Settings" button, so no control opens the page without first asking.** flip at: the owner wants the popover link back · test: PermissionRow no longer takes a settings URL, so no popover button can open one · status: active [agent-assumed 2026-10-06]
- **A6 · In the App Store build the Accessibility button only opens the page, as the watch start compiles the Accessibility request out of the sandboxed build.** flip at: the sandboxed build starts requesting Accessibility at watch start · test: decision-table case accessibility/notGranted with canRequestAccessibility false → openSettings · status: active [agent-inferred 2026-10-06]
- **A7 · The button title says what a click will do: "Request & Open System Settings" when it will ask, "Open System Settings" when it only opens.** flip at: the owner wants one fixed label · test: button-title cases in the pure tests · status: active [agent-assumed 2026-10-06]
- **A8 · The Microphone row's "not asked yet" detail changes from "Will prompt on first recording" to "Not requested yet", since the microphone is in fact asked at every watch start.** flip at: the owner wants the old wording · test: the detail string in the Advanced settings view · status: active [agent-inferred 2026-10-06]

Maintainability (plan review): duplication - the new deliberate Screen Recording request repeats the preflight/request sequence of the watch-start request, deliberately (D4), advisory only; structure - none identified

## Requirement coverage

| Req | Description | Task(s) | Gap justification |
| --- | --- | --- | --- |
| R1 | Each of the three rows in Settings → Advanced → Permissions (Screen Recording, Microphone, Accessibility) shows a button. When the permission is not granted and macOS can still be asked, the button reads "Request & Open System Settings"; a click asks macOS for that permission, which adds the app to that permission's list in System Settings, and then opens that permission's System Settings page. After the action finishes, the section re-reads all three statuses. Errors: a refused or dismissed request still opens the page; a refused Microphone request is logged as today (`permission_denied resource=microphone`), and the status re-read keeps logging its existing `permission_denied resource=screen_recording` warning while Screen Recording is not granted, exactly as the Refresh button does today; nothing else is reported as an error. | gh-1-request-permissions-from-settings.1, gh-1-request-permissions-from-settings.2 | — |
| R2 | When the permission is already granted at the moment of the click (read from macOS then, not from the row's last refresh), the click only opens that permission's page and no system dialog appears; the button reads "Open System Settings" while the row shows the permission as granted. Errors: none beyond R1. | gh-1-request-permissions-from-settings.1, gh-1-request-permissions-from-settings.2 | — |
| R3 | Microphone: if macOS has not asked yet, the macOS microphone dialog appears and the page opens after it has been answered; if the microphone was denied or is restricted, the click only opens the page. The row's detail for "not asked yet" reads "Not requested yet" instead of "Will prompt on first recording". Errors: none beyond R1. | gh-1-request-permissions-from-settings.1, gh-1-request-permissions-from-settings.2 | — |
| R4 | While Screen Recording is not granted, the Screen Recording row shows the note "Screen Recording takes effect only after you quit and reopen Meeting Transcriber." Errors: none. | gh-1-request-permissions-from-settings.2 | — |
| R5 | The button's Screen Recording request is its own deliberate path: it does not use or consume the once-per-session flag of `ensureScreenRecordingAccess()`, and the permission requests at watch start behave exactly as before. Errors: none. | gh-1-request-permissions-from-settings.1 | — |
| R6 | In the App Store build the Accessibility button only opens the Accessibility page and never asks macOS for Accessibility; Screen Recording and Microphone behave as in R1–R3. Both build variants compile. Errors: none. | gh-1-request-permissions-from-settings.1, gh-1-request-permissions-from-settings.2 | — |
| R7 | The "?" popover of each row keeps its help text but no longer has its own "Open System Settings" button; the row's button is the one way to open the page from the section. Errors: none. | gh-1-request-permissions-from-settings.2 | — |
