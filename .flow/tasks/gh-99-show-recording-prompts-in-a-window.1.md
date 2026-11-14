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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
