---
satisfies: [R1, R2]
---
# gh-49-show-a-pending-recording-prompt-on-the.3 Show a question mark on the menu bar icon while a prompt is open

## Description
Draw a question mark at the top right of the menu bar icon, in place of the watching dot, while a recording prompt is open, driven by one `AppState` input (spec "Architecture & Data Models" bullets 1-2; R1, R2).

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/MenuBarIcon.swift`, `Sources/MeetingTranscriberApp.swift`, `Sources/AppState+ConsentPrompt.swift`, `docs/architecture-macos.md`, `Tests/MenuBarIconQuestionTests.swift` (new), `Tests/AppStateConsentPromptTests.swift`, `Tests/MenuBarIconSnapshotTests.swift`, new reference PNGs under `Tests/__Snapshots__/MenuBarIconSnapshotTests/`
**Touches:** [app/MeetingTranscriber/Sources/MenuBarIcon.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/AppState+ConsentPrompt.swift, docs/architecture-macos.md, app/MeetingTranscriber/Tests/MenuBarIconQuestionTests.swift, app/MeetingTranscriber/Tests/AppStateConsentPromptTests.swift, app/MeetingTranscriber/Tests/MenuBarIconSnapshotTests.swift, app/MeetingTranscriber/Tests/__Snapshots__/MenuBarIconSnapshotTests/**]

All source and test paths below are relative to `app/MeetingTranscriber/`.

### Approach
Write the render and accessor tests first (the contract is clear), then draw.

1. `Sources/MenuBarIcon.swift` `image(…)` (`:139-166`): add `questionOverlay: Bool = false` right after `watchingOverlay`, and a doc paragraph after the watching one (`:135-138`): drawn in the icon's colour at the top right in place of the dot, keeps the template path, never touches the bottom half.
2. Cache (`:103-121`): `renderAllFrames` gains `questionOverlay`; add `questionCache` beside `watchingCache`; the lookup (`:162`) picks the question cache when the flag is set, else watching, else plain. The red-overlay branch (`:148-161`) passes the flag on to `renderImage`.
3. `renderImage` (`:170-231`): at the dot (`:215-217`) draw the question mark when `questionOverlay`, else the dot when `watchingOverlay`.
4. `drawQuestionMark(in:color:)` next to `drawWatchingDot` (`:400-420`) and built the same way: first clear a margin around the mark (`.clear` compositing, so it reads as a badge of its own), then draw a bold "?" in `color`, legible at 18 pt (about 8-9 pt). Everything it clears or draws stays in the top half of the 18×18 rect, so the bottom-right badges are untouched. The drawing handler can run off the main thread (note at `:188-194`), so it reads no app state; `NSFont` and `NSAttributedString` drawing are fine there.
5. `Sources/AppState+ConsentPrompt.swift` (from task .1): `var awaitingUserAnswer: Bool { pendingConsentQuestion != nil }`, commented as the single input for "a question awaits the user's answer" that issue #58 can feed later.
6. `Sources/MeetingTranscriberApp.swift`: `AnimatedMenuBarIcon` (`:20-52`) gains `let questionOverlay: Bool` and passes it to `MenuBarIcon.image`; `menuBarLabel` (`:162-176`) passes `questionOverlay: appState.awaitingUserAnswer`.
7. `docs/architecture-macos.md`: the `MenuBarIcon.swift` row (`:97`) lists the question mark among the overlays, and one short paragraph in the "Menu Bar Icon Animations" section (around `:363-405`) says what it shows and that it replaces the watching dot. Do not edit `CLAUDE.md` (fork rule).

Tests:
- `Tests/MenuBarIconQuestionTests.swift` (`@MainActor`), rendering at 1x into an 18×18 bitmap as `Tests/MenuBarIconWatchingTests.swift` does (bitmap rows run top-down). For every `BadgeKind.allCases` at frame 0, compare `image(badge:, watchingOverlay: true, questionOverlay: true)` with `image(badge:, watchingOverlay: true)`: the top half differs and the bottom half (rows 9-17) is pixel-identical. Also: the question image is a template for `.inactive` and for `.recording`; with `permissionOverlay: true` the same top-differs / bottom-identical holds; `.recording` frames 0 and 3 with the question differ (still animates).
- `Tests/AppStateConsentPromptTests.swift` (from task .1): `awaitingUserAnswer` is false without a loop, true while `loop.pendingConsentQuestion` is set, and false again after `state.watching.watchLoop = nil` and after replacing the loop with one that has no open question.
- `Tests/MenuBarIconSnapshotTests.swift` (dev-only, skipped on CI): one test with the question for `.inactive` and `.recording` frame 0 (watching on). Record the references locally (`record: .missing` writes them on the first run), run again to confirm they pass, and commit the PNGs. Run the snapshot suite alone and without `--parallel`: its "error" badge flakes in dark mode when another test in the same worker initialised `NSApp`.

### Investigation targets
**Required** (read before coding):
- `Sources/MenuBarIcon.swift:100-232, 400-420` — caches, `image`, `renderImage`, `drawWatchingDot`
- `Sources/MeetingTranscriberApp.swift:15-52, 162-176` — `AnimatedMenuBarIcon` and `menuBarLabel`
- `Tests/MenuBarIconWatchingTests.swift` — bitmap test pattern

**Optional:**
- `Tests/MenuBarIconSnapshotTests.swift` — snapshot strategy and tolerance
- `docs/architecture-macos.md:360-410` — icon section to extend

### Key context
- Keep `BadgeKind` and `BadgeKind.compute` unchanged: the `badge` value is part of the `/v1` stability contract, and spec gh-58 adds its own overlay flag next to this one later.
- Existing tests that call `MenuBarIcon.image` without the new flag must stay green unchanged (`MenuBarIconTests`, `MenuBarIconWatchingTests`, `MenuBarIconNextFrameTests`).
- Verification:
  - `mkdir -p /private/tmp/mt-gh49/home`
  - `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh49/home swift test --parallel --filter 'MenuBarIconQuestionTests|MenuBarIconWatchingTests|MenuBarIconTests|MenuBarIconNextFrameTests|AppStateConsentPromptTests' > /private/tmp/mt-gh49/t3.log 2>&1` and read the log.
  - `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh49/home swift test --filter MenuBarIconSnapshotTests > /private/tmp/mt-gh49/t3-snap.log 2>&1` (twice: record, then confirm).
  - `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (fetch them into a temp dir if missing, never `brew install`).
  - `./scripts/pre-push.sh --with-appstore`.

## Acceptance
- [ ] For every badge, the icon with `questionOverlay` differs from the watching-dot icon in its top half and is pixel-identical in its bottom half, also with the permission overlay (R1).
- [ ] The question icon stays a template image without red overlays, and animated badges still animate under it (R1).
- [ ] `AppState.awaitingUserAnswer` follows the current loop's open question, including when the loop is replaced or removed, and drives `AnimatedMenuBarIcon` (R1, R2).
- [ ] `BadgeKind`, `BadgeKind.compute` and existing icon tests are unchanged and green.
- [ ] Dev-only snapshot references for the question mark are recorded and committed.
- [ ] `docs/architecture-macos.md` describes the question mark; `CLAUDE.md` untouched.
- [ ] `./scripts/lint.sh` and `./scripts/pre-push.sh --with-appstore` pass.


## Done summary
Whoever misses the "Record <App> meeting?" notification now sees a question mark at the top right of the menu bar icon, in place of the watching dot, for as long as the prompt is open; once it is answered, expires or is declined, the dot is back. `MenuBarIcon.image` gained `questionOverlay` (default false) with its own pre-rendered template cache, and the menu-bar label feeds it from `AppState.awaitingUserAnswer`, which is true while the current watch loop has an open question. `BadgeKind`, `BadgeKind.compute` and the `badge` value are unchanged.

The mark is the bold system font's "?" glyph outline (CoreText) at 9 pt, with a 1 pt margin cleared around it the way the dot clears its ring. Measured with a throwaway probe, it spans y 11.18 to 17.70 of the 18 pt icon, and its cleared margin stops at y 10.18, 1.18 pt above the midline. The bottom-right badges are therefore drawn exactly as without the prompt.

Tests per acceptance item:
- Top half differs, bottom half pixel-identical, for every badge with and without the permission overlay. The same test also checks that something is drawn where the dot was and that the dot is not drawn underneath: `MenuBarIconQuestionTests.testEveryBadgeShowsTheQuestionInTheTopHalfAndLeavesTheBottomHalfAlone`.
- Template image without red overlays: `testTheQuestionKeepsTheIconATemplate`. Animated badges still animate: `testAnimatedBadgesKeepAnimatingUnderTheQuestion`.
- `awaitingUserAnswer` is checked with no loop, without a question, with an open question, after the question ends, after the loop is removed and after it is replaced by a loop without a question: `AppStateConsentPromptTests.testAwaitingUserAnswerFollowsTheCurrentLoopsOpenQuestion`. The label wiring itself (`menuBarLabel` passing `questionOverlay: appState.awaitingUserAnswer`) is covered only by the release build, because the scene's private `AnimatedMenuBarIcon` has no test seam.
- Snapshot references `testQuestionMarkSnapshots.inactive.png` and `testQuestionMarkSnapshots.recording.png` were recorded on a first run and passed on a second, with the suite run alone and without `--parallel`.
- Red first, observed: with the flag plumbed through and no drawing, the render test failed on both paths. The cached path drew nothing in place of the dot, and the red-overlay path still drew the dot.

Gates:
- Baseline green: task filter, 58 tests.
- Final task filter: 62 tests, rc 0.
- Spec Quick command: 77 tests, rc 0.
- Snapshot suite run alone: 7 tests, rc 0 on the confirm run.
- `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1: 0 violations in 717 files.
- `./scripts/pre-push.sh --with-appstore`: rc 0, both release variants, 148 s.
- Line budgets: `MenuBarIcon.swift` 559 lines, `TestHelpers.swift` 600 lines (untouched). `CLAUDE.md` is untouched, and `docs/architecture-macos.md` describes the mark.

Decisions:
- The mark is a CoreText glyph outline rather than an `NSAttributedString` draw. The outline's bounding box is exact, so placing it inside the top half does not depend on the font's ascender and line-height metrics. The bold system font, 9 pt and the 1 pt cleared margin are the defaults the task allowed ("bold, legible at 18 pt, top half only").
- The comment on `awaitingUserAnswer` names the later feeder generically (the "meeting seems to have ended" question). It does not name the fork issue number, because no fork issue ids appear in `Sources/` and code travels to the original unchanged.
- `questionCache` renders with the watching flag off, because the question mark replaces the dot whatever the watching flag says. The render test checks that the image with watching on equals the image with watching off.
- One reviewer (correctness draw) per the impl-review panel rule. The diff stays in one area (the icon and its single input) and touches no persisted or shared state, concurrency, security or data layout.
- The review ran with `CODEX_SANDBOX=workspace-write`, the owner's standing setting the conductor named, and the reviewer left no files in the tree. `--validate` was armed but had nothing to validate on SHIP.
- The reviewer reported that the snapshot suite crashed in its sandbox (`NSScreen.main == nil`, SnapshotTesting's diff renderer) on unchanged references as well as the new ones. That crash is environmental, and the local runs above passed.

Tier: session (jev-unavailable(no_key)); project routing block: implementer opus at xhigh

stage: impl-review - ran [..2026-10-09T05:09:36Z] (codex:gpt-5.6-sol:xhigh, 1 draw correctness, SHIP, 0 findings; --validate had nothing to validate)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 10206073e54b70d8b498fa7ba5f07fc6f40792f4, 773f031d8934ad0799b92e45394ea61cbd61fd37, 6f9cfc8062b2e1cabac41e22453ce81e6967b63c, 9db3074e6ada07244966d542ff35bc703907c0f3
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh49/home swift test --parallel --filter 'MenuBarIconQuestionTests|MenuBarIconWatchingTests|MenuBarIconTests|MenuBarIconNextFrameTests|AppStateConsentPromptTests' (62 tests, rc 0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh49/home swift test --filter MenuBarIconSnapshotTests (run alone, record then confirm: 7 tests, rc 0 on the confirm run), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh49/home swift test --parallel --filter 'WatchLoopAskBeforeRecordingTests|MenuBarViewConsentPromptTests|MenuBarIconQuestionTests|AppStateConsentPromptTests|NotificationManagerSchedulingTests|ConsentPromptCoordinatorTests|MenuBarIconWatchingTests|WatchLoopBrowserConsentTests' (spec quick command, 77 tests, rc 0), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (0 violations, rc 0), ./scripts/pre-push.sh --with-appstore (rc 0, both release variants)
- PRs: