---
satisfies: [R4]
---
# gh-58-notices-for-the-remaining-automatic.2 Pulse the menu bar icon while a meeting-end countdown runs

## Description
Makes a running gh-54 countdown visible on the menu bar icon (R4): the loop publishes the countdown's deadline, `AppState` turns it into one flag, and `MenuBarIcon` draws the whole icon faded on frames 3 to 5 of its 6-frame cycle while the flag is set. An overlay, not a new `BadgeKind` case, so `/v1` `badge` values do not change.

**Depends on spec gh-54 being merged into this branch** (same check as the previous task: `grep -rn 'func waitForMeetingEnd\|meetingEndCountdown\|askBeforeEndingRecording' app/MeetingTranscriber/Sources`). If gh-54 already publishes the countdown as observable state on `WatchLoop` (a deadline, the open question's id, or the pending phase), use that and skip the new property.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchLoop.swift`, gh-54's meeting-end file (where `waitForMeetingEnd` lives), `app/MeetingTranscriber/Sources/MenuBarIcon.swift`, `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, `app/MeetingTranscriber/Sources/AppState.swift` or a new `app/MeetingTranscriber/Sources/AppState+MenuBarIcon.swift`, `docs/architecture-macos.md`, tests `app/MeetingTranscriber/Tests/MenuBarIconCountdownTests.swift`, `app/MeetingTranscriber/Tests/WatchLoopMeetingEndDeadlineTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/WatchLoop+*.swift, app/MeetingTranscriber/Sources/MenuBarIcon.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/AppState*.swift, docs/architecture-macos.md, app/MeetingTranscriber/Tests/MenuBarIconCountdownTests.swift, app/MeetingTranscriber/Tests/WatchLoopMeetingEndDeadlineTests.swift]

### Approach
- **Loop state.** Add `var meetingEndDeadline: Date?` to `WatchLoop` (stored, so it is `@Observable`), internal setter with a doc comment saying only the meeting-end wait writes it, the way `pendingConsentApp` is documented (`WatchLoop.swift:89-94`; `private(set)` would not reach an extension in another file). In `waitForMeetingEnd`: set it to the pending end's deadline on the poll gh-54 opens its question (`.askToEnd`), set it to nil on the poll that withdraws the question or stops, and clear it in a `defer` at the top of the wait so a throw or cancellation (Stop Watching) cannot leave it set.
- **Icon.** `MenuBarIcon.image(...)` (`MenuBarIcon.swift:139-166`) gains `meetingEndCountdownOverlay: Bool = false` after `watchingOverlay`. Add it to the condition that bypasses the cache (`:148`) and pass it to `renderImage`. Add a pure `nonisolated static func isCountdownFadedFrame(_ frame: Int) -> Bool` (`frame % frameCount >= 3`). In `renderImage` (`:170-231`), when the flag is set and the frame is a faded one, draw everything (body, tints, watching dot, badges) inside one transparency layer at alpha 0.3 (`cgContext.setAlpha` + `beginTransparencyLayer`/`endTransparencyLayer`), so the ring the watching dot clears still clears only inside the layer. `isTemplate` stays as today (alpha only, no colour), so a plain recording icon remains a template.
- **App wiring.** `AnimatedMenuBarIcon` (`MeetingTranscriberApp.swift:20-52`) gets `let meetingEndCountdownOverlay: Bool` and passes it on; `menuBarLabel` (`:162-177`) passes `appState.meetingEndCountdownOverlay`. Add that property to `AppState` as a single-member accessor beside `hasPermissionProblem` (`AppState.swift` "Derived properties"): `watching.watchLoop?.meetingEndDeadline != nil`. `AppState.swift` is near the 600-line cap: if it would pass it, put the property in a new `AppState+MenuBarIcon.swift` extension.
- Leave `BadgeKind`, `BadgeKind.compute`, `WatchStatusDTO` and `RecordStatusDTO` untouched.
- **Docs.** In `docs/architecture-macos.md`, add the countdown pulse to the `MenuBarIcon.swift` row (`:97`, "watching dot, permission, …") and one short paragraph next to the other overlay paragraphs (`:381-395`): what it shows, that it is alpha-only, and that `badge` stays `recording`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/MenuBarIcon.swift:103-231` — caches, the overlay bypass and the drawing order
- `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:14-52`, `:162-177` — the icon view and the label
- gh-54's `waitForMeetingEnd` and its decision cases (`.askToEnd`, `.withdrawQuestion`, `.stop`)
- `app/MeetingTranscriber/Tests/MenuBarIconWatchingTests.swift` — rendering an icon to a bitmap and reading alpha

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/AppStateTests.swift:120-165` — wiring a test `WatchLoop` into `AppState`
- gh-54's `WatchLoopMeetingEndTests` — the harness to reuse for driving and answering the countdown

### Key context
- `MenuBarIcon.nextFrame` only advances animated badges, so the pulse needs an animated badge; a countdown only runs while a detected meeting records, which is `.recording`. Do not special-case static badges.
- The animation timer runs in `.default` run-loop mode (`MenuBarIcon.animationRunLoopMode`), so the pulse pauses while the menu is open; that is accepted and needs no change.
- `MenuBarIconSnapshotTests` are dev-only (`XCTSkipIf(isCI)`); the existing images must not change when the flag is false.
- Tests: `MenuBarIconCountdownTests` sums the alpha of all pixels of a 1x render (the bitmap helper in `MenuBarIconWatchingTests.swift:11-22`): frames 0 to 2 with the overlay equal the same frames without it, frames 3 to 5 carry less than half the alpha, the image stays a template without red overlays, and the default (flag false) is unchanged. `WatchLoopMeetingEndDeadlineTests` drives `waitForMeetingEnd` on `TestClock` with a short end grace and an injected short gh-54 countdown: nil while the signal is there, set during the countdown, nil again after each way out: a returning signal, "Keep recording", "Stop now", expiry, the maximum length reached during the countdown, cancellation of the wait task, and a non-cancellation error thrown by an injected `sleepProvider` while the countdown is open. Build on gh-54's `WatchLoopMeetingEndTests` harness (its scripted signal, notifier double and `answerFirstQuestion`) rather than writing a new one. One `AppState` test (in that file or `AppStateTests`) shows `meetingEndCountdownOverlay` follows the loop's deadline. A test that checks the `/v1` badge is not needed: `BadgeKind.compute` is untouched.
- Lint tools: fetch the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 per `scripts/tool-versions.sh` into a scratch dir and put it on PATH; `swiftlint --strict` makes the 600-line cap an error.

### Verification
- `mkdir -p /private/tmp/mt-gh58/home && cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh58/home swift test --parallel --filter 'MenuBarIconCountdownTests|WatchLoopMeetingEndDeadlineTests|MenuBarIconTests|MenuBarIconWatchingTests|MenuBarIconNextFrameTests|BadgeKindComputeTests|AppStateTests|WatchLoopMeetingEndTests|NotificationManagerMeetingEndTests' > /private/tmp/mt-gh58/t2-tests.log 2>&1`, then read the log. The last two are gh-54's test classes as named on its branch; if they were renamed, find them with `grep -rln 'waitForMeetingEnd\|askBeforeEndingRecording' app/MeetingTranscriber/Tests` and run all of them.
- `cd app/MeetingTranscriber && swift build --build-tests -Xswiftc -DAPPSTORE > /private/tmp/mt-gh58/t2-appstore.log 2>&1`.
- `./scripts/lint.sh` with the pinned tools on PATH.
## Acceptance
- [ ] `WatchLoopMeetingEndDeadlineTests` passes: the loop's countdown deadline is nil before a countdown, set while it runs, and nil again after a returning signal, "Keep recording", "Stop now", expiry, the maximum length during the countdown, cancellation of the wait and a thrown error.
- [ ] `MenuBarIconCountdownTests` passes: frames 0 to 2 with the overlay equal those without it, frames 3 to 5 carry less than half their alpha, the plain recording icon stays a template, and with the flag false every badge renders as before.
- [ ] `AppState.meetingEndCountdownOverlay` follows the loop's deadline (one test), and `menuBarLabel` passes it to the icon.
- [ ] `BadgeKind`, `BadgeKind.compute`, `WatchStatusDTO` and `RecordStatusDTO` are unchanged in the diff; `MenuBarIconTests`, `MenuBarIconWatchingTests`, `MenuBarIconNextFrameTests`, `BadgeKindComputeTests`, `AppStateTests` and gh-54's tests (`WatchLoopMeetingEndTests`, `NotificationManagerMeetingEndTests` or their renamed successors) pass.
- [ ] `docs/architecture-macos.md` names the countdown pulse in the `MenuBarIcon.swift` row and the overlay paragraphs.
- [ ] `swift build --build-tests -Xswiftc -DAPPSTORE` succeeds and `./scripts/lint.sh` (pinned tools) is clean; no Swift file passes 600 lines.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
