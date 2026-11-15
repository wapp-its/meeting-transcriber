---
satisfies: [R8, R9]
---
# gh-99-show-recording-prompts-in-a-window.1 Never-key prompt panel placed below the menu bar icon, proven first

## Description
Builds the window's AppKit shell without its content: the panel type, the lookup of the menu bar icon's frame, and the pure placement. It comes first because both of the spec's prove-it-first gates live here (Architecture & Data Models, "The window" and "Placement"), and task .4 builds the questions on it. No setting, no question and no wiring into the app in this task. Split from the window's content because together they are a new subsystem of about ten files; this part has no dependency and can run beside .2 and .3.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/PromptPanel.swift` (new), `app/MeetingTranscriber/Sources/MenuBarIconFrame.swift` (new), `app/MeetingTranscriber/Sources/PromptWindowPlacement.swift` (new), `app/MeetingTranscriber/Tests/PromptPanelTests.swift` (new), `app/MeetingTranscriber/Tests/PromptWindowPlacementTests.swift` (new), `app/MeetingTranscriber/Tests/MenuBarIconFrameTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/PromptPanel.swift, app/MeetingTranscriber/Sources/MenuBarIconFrame.swift, app/MeetingTranscriber/Sources/PromptWindowPlacement.swift, app/MeetingTranscriber/Tests/PromptPanelTests.swift, app/MeetingTranscriber/Tests/PromptWindowPlacementTests.swift, app/MeetingTranscriber/Tests/MenuBarIconFrameTests.swift]

All paths below are relative to `app/MeetingTranscriber/`.

### Approach
0. **Gates first**, as throwaway probes in the running Homebrew dev build, before any code below is kept. Follow the fork rules for the installed app (never quit, kill or replace the installed dev app yourself) and read `docs/architecture/gui-testing.md` first.
   - **0a, icon frame:** from `NSApp.windows`, find the window AppKit creates for the `MenuBarExtra` item (`Sources/MeetingTranscriberApp.swift:116`; nothing in the app reads it today) and log its class, level and frame. Try: icon visible; icon pushed into the notch overflow (many menu bar items, or a narrow screen); icon hidden by a menu bar manager if one is available. Record what the lookup returned in each case in the done summary. Every case that gives no usable frame must reach the fallback in step 3.
   - **0b, first click:** show a bare `PromptPanel` (step 1) with one SwiftUI button through `orderFrontRegardless` while another app is frontmost, and post one real mouse click at the button's screen point from outside the app (a CGEvent-level click from a helper, or the Cua driver), never `MouseInjection.click`, which activates the app first (`Sources/MouseInjection.swift:69-80`). Pass: the button's action runs on that one click, the other app stays frontmost, and the panel never becomes key. If only a key panel takes the click, stop the task: that changes R8 and goes to the owner. If the runner cannot post such a click, write "blocked from verification" with the reason in the done summary and carry on; the click then joins the owner checks after merge.
1. `PromptPanel`: an `NSPanel` subclass whose `canBecomeKey` and `canBecomeMain` return false. Style `[.borderless, .nonactivatingPanel]`, `level = .statusBar`, `hidesOnDeactivate = false`, `isFloatingPanel = true`, `sharingType = .none` (D4), clear background with a shadow, and the collection behaviour the naming window gets: clear the exclusive groups, then add `.canJoinAllSpaces` and `.fullScreenAuxiliary` (`Sources/NamingWindowPolicy.swift:29-41`). Unlike the caption panel (`Sources/LiveCaptionsWindowController.swift:195-217`) it takes mouse events and has no `.stationary`. A static window identifier, set as the caption panel sets `panelIdentifier`, so `/state.windows` lists it (`Sources/AppState+RPC.swift:261-270`). Its content is an `NSHostingView` subclass whose `acceptsFirstMouse(for:)` returns true, with a way to replace the root view.
2. `MenuBarIconFrame`: reads the icon window's frame from an injected window list (production: `NSApp.windows`, empty when `NSApp` is nil as in xctest). Identify the window by what probe 0a showed (class name and level), not by a guess. Nil when no such window exists or its frame is empty.
3. `PromptWindowPlacement`: a pure enum after `CaptionBarPlacement` and its `CaptionScreen` (`Sources/CaptionBarPlacement.swift:8-70`). Inputs: the optional icon frame, the screens (frame and visible frame, first = the screen with the menu bar), the window size and the menu bar height (injected; `NSStatusBar.system.thickness` in production). With an icon frame on a screen: top edge about 6 pt below the icon frame's bottom (D6), centred under its midpoint, clamped inside that screen's frame. Without one, or when the frame lies on no screen: top right of the first screen, its top edge the same gap below the menu bar (`frame.maxY` minus the menu bar height), so a full-screen app that hides the menu bar does not move it.

### Investigation targets
**Required** (read before coding):
- `Sources/LiveCaptionsWindowController.swift:190-220` — panel creation, identifier, flags to copy and to leave out
- `Sources/NamingWindowPolicy.swift:20-41` — exclusive collection-behaviour groups
- `Sources/CaptionBarPlacement.swift` — pure placement and screen model to mirror
- `Sources/MeetingTranscriberApp.swift:105-130` — the `MenuBarExtra` scene
- `Tests/NamingWindowPolicyTests.swift` — headless window test pattern

**Optional** (reference as needed):
- `Sources/MouseInjection.swift:60-90` — why it cannot prove the first click
- `docs/architecture/gui-testing.md` — live assertions (`isVisible` only; `fullScreenAuxiliary` is unstable on the CI runner)

### Key context
- Tests share an xctest process with `NSApp` nil: inject the window list and the screens, and never assert on a state only a fresh process has (`scripts/ci/test-shards.sh` header).
- AppKit screen coordinates grow upwards from the bottom left of the first screen, so "below the menu bar" means a smaller y.
- No new log line may carry a question's text (spec Edge Cases, Privacy); a probe line in step 0 logs only class, level and frame and is removed with the probe.
## Acceptance
- [ ] Gate 0a ran in the running dev build and the done summary records what the lookup returned for each case tried.
- [ ] Gate 0b ran with a real click from outside the app, or the done summary says it is blocked from verification and why; a result where only a key panel takes the click stopped the task for the owner.
- [ ] A test on a built `PromptPanel` checks: non-activating style, `canBecomeKey` and `canBecomeMain` false, `.statusBar` level, `canJoinAllSpaces` + `fullScreenAuxiliary`, not hidden on deactivate, sharing type none, the window identifier, and a content view that accepts the first mouse.
- [ ] Placement tests: icon in the middle of the menu bar (centred, top edge 6 pt below the icon frame), icon near the right edge (kept inside the screen), no icon frame (top right fallback), an icon frame on no screen (fallback), two screens with the icon on the second (window on the second).
- [ ] Icon-frame lookup tests with an injected window list: found, no such window, empty frame.
- [ ] Quick commands green; `./scripts/lint.sh` clean with the pinned tools.

## Done summary
Task .4 can now build the prompt window on three tested pieces. `PromptPanel` is a never-key, non-activating panel at status-bar level on every Space with sharing type none. `MenuBarIconFrame` reads the menu bar icon's frame from the app's own windows. `PromptWindowPlacement` puts the window 6 pt below the icon, or at the top right below the menu bar when the icon cannot be read. Nothing is wired into the app yet, as the task says.

Both prove-it-first gates ran in a throwaway helper app with its own bundle id and a SwiftUI `MenuBarExtra`, on macOS 26, not in the installed dev app (it cannot run probe code). The helper quit on its own and was removed afterwards.

Gate 0a (icon frame lookup), per case tried:
- Icon visible: the item got one window per display that shows a menu bar, class `NSStatusBarWindow` (content `NSStatusBarContentView`), level 25 (`.statusBar`), as wide as the icon (32 pt) and as tall as that display's menu bar (33 pt on the notched display, 30 pt on the second display). Both windows were occlusion-visible.
- Notch overflow (set up with five items in the helper): the icon's window on the notched display kept a non-empty on-screen frame behind the notch, `isVisible` true and occlusion not visible. Items pushed further left, over the app menus, behaved the same. The copies on the second display stayed visible. The lookup therefore takes only occlusion-visible windows, so this case reaches the fallback when no other display shows the icon.
- Item not inserted (`isInserted` false): its window had an empty frame (height 0), or a frame off every screen. Both reach the fallback.
- Hidden by a menu bar manager: not set up. No menu bar manager was available to the probe. The occlusion and empty-frame rules above are the expected route to the fallback, unverified.

Gate 0b (first click): passed. A bare panel of the `PromptPanel` shape with one SwiftUI button was shown through `orderFrontRegardless` while another app was frontmost. One CGEvent-level click (one down, one up) was posted from a separate process at the button's centre, after `CGWindowListCopyWindowInfo` confirmed that the topmost window at that point was the helper's own. The button's action ran on that one click. The helper stayed inactive, the panel never became key (no `didBecomeKey`, `keyWindow` nil) and the other app stayed frontmost before, during and after the click. A control run with a plain `NSHostingView` (no `acceptsFirstMouse` override) also ran the action on the first click. The override stays because the spec asks for it, and a plain `NSHostingView` answers false to `acceptsFirstMouse(for:)`.

The first 0b run caught a real trap. Setting `isFloatingPanel = true` resets a panel's level to `.floating` (3), so a panel that sets the level first ends below the Dock's layer-20 window and the click check refused to post. `PromptPanel` sets `isFloatingPanel` before `.statusBar`, and the panel test pins the order.

Tests by acceptance criterion:
- Panel set-up: `PromptPanelTests.testPanelTakesClicksWithoutEverBecomingKeyOrActivatingTheApp` checks the non-activating style, `canBecomeKey` and `canBecomeMain` false, `.statusBar` level, `canJoinAllSpaces` and `fullScreenAuxiliary`, not hidden on deactivate, sharing type none, the window identifier, and a content view that accepts the first mouse.
- Placement: `PromptWindowPlacementTests` covers the icon in the middle (centred, top edge 6 pt below the icon), the icon near the right edge (kept inside the screen), no icon frame (top right), an icon frame on no screen (top right), and the icon on the second of two screens. A sixth test covers non-finite screens and icon frames (ignored) and no usable screen (nil).
- Lookup: `MenuBarIconFrameTests` covers found (preferring the menu bar screen), no such window (real `NSPanel` adapter, wrong class, wrong level, empty list, nil app), empty frame, and an icon window that is not visible (the notch case).
- Mutation check: moving `isFloatingPanel` after the level turned the panel test red (level 3 instead of 25). Dropping the occlusion filter turned both notch assertions red. Both files were restored before the commit.

baseline: green via handoff (verified at e128491d by the conductor, the spec's Quick command with -j 6, 191 tests, 0 failures); lint green at base (ran, exit 0)

Gates on the task head: the spec's Quick command, run with `-j 6` in both places, exited 0 (202 tests, 0 failures). `./scripts/lint.sh` with the pinned tools exited 0 (0 violations in 1274 files). The App Store variant was not built. The task does not ask for it, and nothing here is behind `#if`.

Choices:
- Screen model reuses `CaptionScreen` instead of a copy (rule 6).
- The icon window is identified by class `NSStatusBarWindow`, `.statusBar` level, occlusion-visible and a non-empty frame (rule 1, task step 2 and the spec's edge case that a notch-overflow icon uses the fallback).
- With the icon visible on two displays, the lookup prefers the window on the screen with the menu bar (rule 4, switch point `MenuBarIconFrame.frame(among:menuBarScreen:)`, test `testFindsTheIconWindowPreferringTheOneOnTheMenuBarScreen`).
- The 6 pt gap also keeps the window off a screen's side edges, in the clamp and in the top-right fallback (rule 4, switch point `PromptWindowPlacement.gap` in `clamped` and the fallback x, tests `testIconNearTheRightEdgeKeepsTheWindowInsideTheScreen` and `testNoIconFramePutsTheWindowAtTheTopRightBelowTheMenuBar`).
- The placement ignores non-finite or empty screens and icon frames and returns nil when no screen is usable (rule 1, the display-reconfiguration note in `CaptionBarPlacement`).
- Window identifier `recording-prompts` (rule 6).
- Content is a `PromptHostingView` over `AnyView`, replaced through `panel.host.rootView`. The panel size comes from the caller through `init(size:)`, so the 340 pt width of D6 stays with task .4 (rule 6).

Follow-ups and findings for the conductor:
- `NSStatusBar.system.thickness` read 22 pt, while the notched display's menu bar is 33 pt. Task .4 must not pass it unchanged as `menuBarHeight`, or the fallback window's top edge sits 5 pt inside the menu bar on exactly the screens where the notch overflow forces the fallback. Details are in the run notes.
- Pre-existing, not fixed (outside this spec): `LiveCaptionsWindowController.ensurePanel` sets `level = .statusBar` before `isFloatingPanel = true`, so the caption panel actually runs at `.floating`.

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

Integrated verify on the spec branch: the spec's Quick command with -j 6 at e18f56c0, exit 0, 202 tests, 0 failures

stage: impl-review - ran [2026-11-15T16:27:51Z..2026-11-15T16:32:30Z] SHIP, one correctness draw, no findings (model: gpt-6.1-sol at xhigh)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: e18f56c0bffe8b0d970b0ea55616a1f56d0f97f7
- Tests: cd app/MeetingTranscriber && mkdir -p .build/test-home && swift build --build-tests -j 6 && CFFIXED_USER_HOME="$PWD/.build/test-home" swift test -j 6 --filter 'PromptWindow|PromptPanel|MenuBarIconFrame|MeetingEndQuestion|WatchLoopMeetingEnd|NotificationManagerMeetingEndTests|NotificationManagerSchedulingTests|ConsentPromptCoordinatorTests|WatchLoopAskBeforeRecordingTests|WatchLoopBrowserConsentTests|AppStateConsentPromptTests|NamingWindowPolicyTests|GeneralSettings|AppSettingsTests|MenuBarIconCountdownTests' (exit 0: 202 tests, 0 failures), ./scripts/lint.sh with pinned SwiftFormat 0.64.6 / SwiftLint 0.65.1 (exit 0: 0 violations in 1274 files), integrated verify: the spec's Quick command with -j 6 at e18f56c0, exit 0, 202 tests, 0 failures
- PRs: