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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
