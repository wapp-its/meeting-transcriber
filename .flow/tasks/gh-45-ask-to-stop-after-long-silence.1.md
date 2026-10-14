---
satisfies: [R1, R2, R3, R4, R7]
---
# gh-45-ask-to-stop-after-long-silence.1 Silence clock and stop-question policy

Touches: app/MeetingTranscriber/Sources/SilencePromptPolicy.swift, app/MeetingTranscriber/Sources/ChannelHealthController.swift, app/MeetingTranscriber/Tests/SilencePromptPolicyTests.swift, app/MeetingTranscriber/Tests/ChannelHealthSpeechActivityTests.swift

## Description
Builds the two pure pieces the feature decides with, before anything is wired: a "when was speech last heard" accessor on the channel-health controller, and the per-poll decision type `SilencePromptPolicy`. Nothing in the running app changes yet. The policy's contract is fully stated in the spec (R1–R4, R7, Edge Cases), so write `SilencePromptPolicyTests` first and see them fail for the right reason.

Prerequisite: spec gh-54 (ask before auto-stopping a meeting) is merged into `wapp/main`; this task reuses its answer type `MeetingEndAnswer`. If it is not there, stop and report.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/SilencePromptPolicy.swift` (new), `app/MeetingTranscriber/Sources/ChannelHealthController.swift`, `app/MeetingTranscriber/Tests/SilencePromptPolicyTests.swift` (new), `app/MeetingTranscriber/Tests/ChannelHealthSpeechActivityTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/SilencePromptPolicy.swift, app/MeetingTranscriber/Sources/ChannelHealthController.swift, app/MeetingTranscriber/Tests/SilencePromptPolicyTests.swift, app/MeetingTranscriber/Tests/ChannelHealthSpeechActivityTests.swift]

### Approach
- `SpeechActivity` (value type, in `SilencePromptPolicy.swift`): `observedSince: Date` (the first channel-health tick of this recording), `lastSpeechAt: Date?` (the latest tick at or above the speech threshold on a channel the recording opened; nil while none). Derived `silentSince = lastSpeechAt ?? observedSince`.
- `ChannelHealthController.speechActivity: SpeechActivity?`: computed from the existing `firstTickAt` and `lastSpeechAt` (stored at `ChannelHealthController.swift:109-114`, written in `applyTick` at `:284-295`), keeping only channels in `channels` (`:63`); nil before the first tick. The storage is `@ObservationIgnored` on purpose (written 10 times a second, see `:81-87`); the accessor must not add an observed dependency. `stop()` already clears both via `resetPerRecordingState()` (`:258-269`), so no new reset is needed.
- `SilencePromptPolicy`: a caseless enum with static members, pure, no I/O, in the style of `WatchLoopEndPolicy` (gh-54's version). Interface (signatures only):
  - `struct SilencePromptState: Equatable { var open: OpenSilenceQuestion?; var countFrom: Date? }`
  - `struct OpenSilenceQuestion: Equatable { let askedAt: Date; let silentSince: Date }`
  - `enum SilencePromptWithdrawReason: String { case speech, kept, held, off, replaced, ended }` (`replaced` and `ended` are for the loop's log lines; the policy never returns them)
  - `enum SilencePromptAction: Equatable { case none; case ask(silentFor: TimeInterval); case withdraw(SilencePromptWithdrawReason); case stop(cutAt: Date?, silentFor: TimeInterval) }`
  - `static let cutMargin: TimeInterval = 10`
  - `static func step(after: TimeInterval?, now: Date, activity: SpeechActivity?, held: Bool, answer: MeetingEndAnswer?, state: SilencePromptState) -> (action: SilencePromptAction, state: SilencePromptState)`
  - `static func questionTitle(silentFor: TimeInterval) -> String` ("Nothing heard for 5 minutes", "Nothing heard for 1 minute"; whole minutes rounded down, at least 1) and `static let questionBody = "Stop the recording? Without an answer, it keeps recording."`
- Rules of `step`, in this order, the first that applies decides:
  1. `answer == .stopNow` with a question open: `.stop(cutAt:silentFor: now − silentSince)`, state reset. `cutAt` is `activity.lastSpeechAt + cutMargin` only when that is earlier than `now`; it is nil when there is no speech stamp, and nil when last speech + 10 s is not earlier than `now` (speech came back moments before the answer), because a cut point at or past the stop would make gh-54's `cutBack` report audio the files do not hold (its record-only sidecar would claim a stop time after the real end). An explicit answer wins over held, off and returning speech; the cut is taken from the current activity, so speech heard after the question went up is kept.
  2. `answer == .keepRecording`: `.withdraw(.kept)`, `open = nil`, `countFrom = now`.
  3. `after == nil` (switched off): `.withdraw(.off)` when open, else `.none`.
  4. `held`: `.withdraw(.held)` when open, else `.none`; in both cases `countFrom = now`, so the count restarts when the hold ends.
  5. `activity == nil`: `.none`.
  6. open and `activity.silentSince != open.silentSince` (speech since the ask): `.withdraw(.speech)`, `open = nil`.
  7. `now − max(silentSince, countFrom ?? .distantPast) >= after`: `.ask(silentFor: now − silentSince)`, `open = (now, silentSince)`, `countFrom = now`. With a question already open this is the replacement of R4; the loop withdraws the old one before posting.
  8. otherwise `.none`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/ChannelHealthController.swift:60-114, 245-296` — channels, firstTickAt, lastSpeechAt, the tick that writes them
- `app/MeetingTranscriber/Sources/SilentRecordingMonitor.swift` — the sibling pure monitor and its thresholds
- gh-54's `app/MeetingTranscriber/Sources/WatchLoopEndPolicy.swift` — `MeetingEndAnswer` and the pure-policy style

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/ChannelHealthHarness.swift:28-48` — bare controller plus `MockRecorder` for `applyTick` tests
- `app/MeetingTranscriber/Tests/SilentRecordingMonitorTests.swift` — explicit-date test style

### Key context
- Do not build on `SilentRecordingMonitor`: it opens an episode only when both channels are at or below -60 dBFS, so a room whose noise sits between -60 and -50 dBFS would never count as silent. The spec (A1) counts "no tick at or above -50 dBFS", read through `channelHealthMonitor.speechThresholdDBFS`, not a second constant.
- Filter by opened channels even though an unopened channel reads -120 dBFS in production: `MockRecorder` levels are whatever a test sets.
- `Tests/TestHelpers.swift` is at the 600-line `file_length` cap (lint runs `--strict`); put new helpers in the new test files.
## Acceptance
- [ ] `SilencePromptPolicyTests`, written first and seen failing, cover: no question before `after`, one at exactly `after`; title minutes rounded down and the singular; withdraw on speech and the next question a full `after` after the new last speech; keep → withdraw, next question at answer + `after`, `silentFor` counted from the real start of the silence; unanswered → replaced at askedAt + `after`; stop → `cutAt` = last speech + 10 s; stop when no speech was ever heard → `cutAt` nil; stop after speech returned → cut from the newer last speech; stop less than 10 s after the last speech → `cutAt` nil (boundary: exactly 10 s after is also nil, 10.1 s after cuts); off → withdraws and never asks; held → withdraws, never asks, and the count restarts at the last held poll.
- [ ] `ChannelHealthSpeechActivityTests`, driving `applyTick`: nil before the first tick; `observedSince` is the first tick; `lastSpeechAt` follows the latest speech tick on either channel of a dual recording; a mic-only recording ignores app-channel speech and an app-only one ignores mic speech; `stop()` clears it.
- [ ] Focused run green: `cd app/MeetingTranscriber && CFFIXED_USER_HOME=<scratch dir> swift test --parallel --filter "SilencePromptPolicyTests|ChannelHealth" > <log file> 2>&1`, result read from the log file.
- [ ] `./scripts/lint.sh` reports no violations with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1 (`scripts/tool-versions.sh`; if they are not installed, fetch the pinned release assets into a temp dir, check the SHA-256, and put that dir first on `PATH`; no global install).
## Done summary
Added the two pure pieces the long-silence question decides with. `ChannelHealthController.speechActivity` gives the silence clock: the first tick of the recording, and the latest tick at or above the speech threshold on a channel the recording opened. `SilencePromptPolicy` holds the per-poll decision (ask / withdraw / stop with a cut point), the question title and body, and the 10 s cut margin. Nothing in the running app calls them yet; task .3 wires them.

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

stage: impl-review - skipped(policy: parallel-wave - conductor owns the gate)

Baseline: green via handoff (77dc12cc, `.flow/`-only since). Lint re-run at 77dc12cc: rc=0.

Tests (R1, R2, R3, R4, R7):
- `SilencePromptPolicyTests` (9 tests). Seen red before the implementation: compile failure on the missing types, log `/tmp/gh45-tick/t1-tests-red.log`. Covers: no question before `after` and one at exactly `after`, plus none before the first tick; title minutes rounded down and the singular, plus the body text; speech withdraws and the next question comes a full `after` after the new speech; keep withdraws and the next question comes at answer + `after`, with `silentFor` from the real start of the silence; an unanswered question is replaced at askedAt + `after`; one stop table (cut at last speech + 10 s, nil without speech, cut from the newer speech after speech returned, nil under 10 s, nil at exactly 10 s, a cut at 10.1 s, stop wins over held and over off); off withdraws and never asks; held withdraws, never asks, and restarts the count at the last held poll; an answer with no open question changes nothing (the policy's part of the R3/R4 error clauses).
- `ChannelHealthSpeechActivityTests` (5 tests) drive `applyTick`: nil before the first tick; `observedSince` is the first tick; `lastSpeechAt` follows the latest speech tick on either channel of a dual recording, -50 dBFS counting as speech and -50.1 not; mic-only and app-only recordings ignore the unopened channel; `stop()` clears it.

Gates (measured, on 585acc0a):
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/mt-gh45-home-t1 swift test --parallel --filter "SilencePromptPolicyTests|ChannelHealth"`: rc=0, 76 tests including the 14 new ones. Log: `/tmp/gh45-tick/t1-tests-final.log`.
- `PATH="/tmp/gh45-tick/lint-tools/bin:$PATH" ./scripts/lint.sh`: rc=0, 0 violations in 768 files.
- Extra: clean `xcodebuild build-for-testing` plus `swiftlint analyze --strict`. No findings in this task's files. Two `unused_declaration` errors that predate this spec, in `Sources/RecordingProvider.swift:144` and `:146` (gh-60's protocol-extension defaults, commit 4ab0a4d9). Not fixed here; details in the run note `t1-analyzer-baseline.md`.

Decisions:
1. Rule 1 (R3/R4 error clauses). "Keep recording" counts only while a question is open, the same as "Stop now". An answer with no open question is treated as no answer. The task's rule 2 lists no open-question condition; without one, a stray answer would restart the count and return a withdraw with nothing open. Switch point: `SilencePromptPolicy.step`, first `if let open = state.open, let answer`. Test: `testAnAnswerWithNoOpenQuestionChangesNothing`.
2. Rule 6. On a stop, `silentFor` is measured from the current activity's `silentSince`, falling back to the open question's when there is no activity. So a stop after speech returned reports the current, shorter silence. Switch point: `SilencePromptPolicy.answered`. Test: the stop-table row "speech came back after the ask" (`silentFor: 30`).
3. Rule 5. `step` keeps the task's six-argument signature, which task .3 consumes. `function_parameter_count` is suppressed on that line (`// swiftlint:disable:this`), and the doc comment gives the reason. A probe without the suppression showed the rule fires at 6 parameters.
4. Rule 6. The tests were not committed on their own before the implementation. Their red state was a compile failure of the whole test target, and a commit that does not build breaks every checkout and bisect that lands on it. The red run is kept in `/tmp/gh45-tick/t1-tests-red.log`.
5. Rule 1 (`.claude/rules/wapp-fork.md`: write for the original's readers; gh-54's code cites no fork issue). The commit message has no `Task:` trailer and no fork issue or spec id. The code comments carry no "(issue #45)" either, because upstream #45 is a different issue.
6. Rule 1 (task rule 3 sets no `countFrom`). Switching the question off leaves `countFrom` as it was, and only a hold moves it. Switching back on during a long silence can therefore ask at the next poll. That fits R6 ("a change applies at its next poll"). Noted for task .3.

Feature map: no change to how a user reaches any feature.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 688d30c6a1c84f9edc953e050ea391a047057921
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/tmp/mt-gh45-home-t1 swift test --parallel --filter "SilencePromptPolicyTests|ChannelHealth" > /tmp/gh45-tick/t1-tests-final.log 2>&1 (rc=0, 76 tests incl. 14 new), PATH="/tmp/gh45-tick/lint-tools/bin:$PATH" ./scripts/lint.sh (rc=0, 0 violations in 768 files), swiftlint analyze --strict --compiler-log-path /tmp/gh45-tick/t1-xcodebuild.log (0 findings in task files; 2 pre-existing unused_declaration in Sources/RecordingProvider.swift:144,146)
- PRs: