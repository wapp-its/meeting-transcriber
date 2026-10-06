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
- `MenuBarView` (`MenuBarView.swift:208-220`): same two new defaulted `var`s (existing memberwise call sites in the tests keep compiling). In mt-update mode: installing → a disabled "Installing Update…" item; a summary → "Install Update: <summary>" (`A11yID.menuInstallUpdateButton`), disabled when a reason is set, a check runs or the callback is nil. GitHub mode unchanged.
- `SettingsView`: forward both values to `AboutSettingsView` (pattern: the `namingDialogActive`/`pipelineBusy` pass-through).
- `MeetingTranscriberApp`: pass `appState.updateInstallBlockedReason` and `{ appState.installUpdate() }` to both `MenuBarView` (`:133-160`) and `SettingsView` (`:255-278`), read through single-member `AppState` accessors only (300 ms type-check limit on these bodies; see the note above `body`).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/Settings/AboutSettingsView.swift:59-113` — section to extend
- `app/MeetingTranscriber/Sources/MenuBarView.swift:1-70,208-220` — properties, body split, update item
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:111-160,255-278` — scene composition and the type-check note
- `app/MeetingTranscriber/Sources/A11yID.swift` — identifier conventions

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/AboutSettingsViewTests.swift:75-112` — update-section tests
- `app/MeetingTranscriber/Tests/MenuBarViewTests.swift:764-790` — update-item tests
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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
