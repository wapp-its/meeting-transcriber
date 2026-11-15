---
satisfies: [R3, R5]
---
# gh-99-show-recording-prompts-in-a-window.2 Countdown question value and answer-by-id calls for both questions

## Description
Gives the "Meeting seems to have ended" countdown a question value on `WatchLoop`, and lets code outside a notification answer either question by its id through the paths a notification tap uses, "Never for this app" included (spec Architecture & Data Models, first two bullets; A2, A5; Verification, "Answer paths"). No UI in this task.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/MeetingEndQuestion.swift` (new), `Sources/WatchLoop.swift`, `Sources/WatchLoop+MeetingEnd.swift`, `Sources/WatchLoop+MeetingEndQuestion.swift` (new), `Sources/WatchLoop+Consent.swift`, `Sources/AppNotifying.swift`, `Sources/MeetingEndQuestions.swift`, `Sources/NotificationManager.swift`, `Sources/AppState+ConsentPrompt.swift`, `Sources/AppState+MeetingEndQuestion.swift` (new); tests and doubles: `Tests/ConsentLoopDoubles.swift`, `Tests/AppStateConsentPromptTests.swift`, `Tests/NotificationManagerSchedulingTests.swift`, `Tests/NotificationManagerMeetingEndTests.swift`, `Tests/WatchLoopMeetingEndQuestionTests.swift` (new), `Tests/WatchLoopBrowserConsentTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/MeetingEndQuestion.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/WatchLoop+MeetingEnd.swift, app/MeetingTranscriber/Sources/WatchLoop+MeetingEndQuestion.swift, app/MeetingTranscriber/Sources/WatchLoop+Consent.swift, app/MeetingTranscriber/Sources/AppNotifying.swift, app/MeetingTranscriber/Sources/MeetingEndQuestions.swift, app/MeetingTranscriber/Sources/NotificationManager.swift, app/MeetingTranscriber/Sources/AppState+ConsentPrompt.swift, app/MeetingTranscriber/Sources/AppState+MeetingEndQuestion.swift, app/MeetingTranscriber/Tests/ConsentLoopDoubles.swift, app/MeetingTranscriber/Tests/AppStateConsentPromptTests.swift, app/MeetingTranscriber/Tests/NotificationManagerSchedulingTests.swift, app/MeetingTranscriber/Tests/NotificationManagerMeetingEndTests.swift, app/MeetingTranscriber/Tests/WatchLoopMeetingEndQuestionTests.swift, app/MeetingTranscriber/Tests/WatchLoopBrowserConsentTests.swift]

All paths below are relative to `app/MeetingTranscriber/`.

### Approach
Test first: the contract is known (spec Verification, "Answer paths").
1. `MeetingEndQuestion: Equatable, Sendable` with `id: String`, the app label, `title`, `body` and `deadline: Date`, header comment in the style of `Sources/ConsentQuestion.swift:1-11`.
2. `Sources/WatchLoop.swift:101`: the stored `meetingEndQuestionID: String?` is replaced by a stored `meetingEndQuestion: MeetingEndQuestion?`. The file is at 600 of its 600 lines (2026-11-15), so it only replaces, line for line (its doc comment included); the read-only computed `meetingEndQuestionID` (`meetingEndQuestion?.id`) goes into `Sources/WatchLoop+MeetingEndQuestion.swift`, and its readers (`Sources/AppState+MenuBarIcon.swift:13`, the guard in `receiveMeetingEndAnswer`) stay as they are.
3. `askToEnd` (`Sources/WatchLoop+MeetingEnd.swift:356-371`) gets the `PendingMeetingEnd` of the `.askToEnd` decision (`:120-124`) and builds the question with that value's `deadline` (`Sources/WatchLoopEndPolicy.swift:256-260`), never with `nowProvider() + countdown`, so the window counts down to the deadline the loop enforces. It stores the question before posting and posts exactly its title and body. `withdrawMeetingEndQuestion` (`:390-395`) clears it.
4. Countdown answer by id: a new `@MainActor` requirement on `AppNotifying` that answers the meeting-end question with a given id and a `MeetingEndAnswer` and returns whether it answered, with a default returning false beside the other meeting-end defaults (`Sources/MeetingEndQuestions.swift:6-21`). Give it labels that do not clash with the tap entry `answerMeetingEndQuestion(id:actionIdentifier:)` (`Sources/NotificationManager.swift:483-490`). `NotificationManager` implements it with `meetingEndQuestions.take(id:)` and runs the taken handler at once (it is `@MainActor`); sharing `take` with the tap path is what answers each question at most once. A question that could not be posted registered no handler, so this answers nothing (R4 errors, gh-54 R5).
5. Consent answer with a full `ConsentAnswer`: the requirement `answerConsentPrompt(id:granted:)` (`Sources/AppNotifying.swift:42-48`, default `:155`) becomes `answerConsentPrompt(id: UUID, answer: ConsentAnswer) -> Bool` with a default of false; the `granted:` spelling stays as a plain extension method that maps to `.granted` or `.declined`. `NotificationManager` (`:377`) calls `consentCoordinator.resolve(id:answer:)` (`Sources/ConsentPromptCoordinator.swift:71`). Move every double that implements the `granted:` form to the new requirement (`Tests/ConsentLoopDoubles.swift:114`, `Tests/AppStateConsentPromptTests.swift:20`): a double left on the old spelling stops being the witness and answers false, the downgrade the `AppNotifying` doc comment warns of.
6. `WatchLoop.answerParkedConsent` (`Sources/WatchLoop+Consent.swift:143-149`) takes a `ConsentAnswer`; its `granted:` form stays as a wrapper for the menu and the Record Meeting window, with `protocolOptions` unchanged. `.never` then reaches `finishConsent`'s existing `.never` branch (`:178`), the one a notification Never takes.
7. In the new `WatchLoop` extension: answer the countdown with a question and a `MeetingEndAnswer`, false unless that question is still `meetingEndQuestion`, else the notifier call (as `answerParkedConsent`). The answer then reaches `receiveMeetingEndAnswer` and the loop applies it on its next poll, as for a tap.
8. `AppState`: the open countdown question and its answer call in `Sources/AppState+MeetingEndQuestion.swift`, and the consent answer with a `ConsentAnswer` in `Sources/AppState+ConsentPrompt.swift`, as single-member accessors (`Sources/AppState+ConsentPrompt.swift:1-30`). `AppState.swift` is not touched.

Tests (models: `Tests/WatchLoopMeetingEndTests.swift:263-356`, `Tests/NotificationManagerMeetingEndTests.swift:64-96`, `Tests/NotificationManagerSchedulingTests.swift:187-253`, `Tests/WatchLoopBrowserConsentTests.swift:168`):
- The question's title, body and deadline equal what was posted and the policy's deadline; the question is nil after every way out: signal back, Keep recording, Stop now, expiry, cap, a new call, a stop by hand, Stop Watching.
- Countdown answer by id against the real `NotificationManager` and registry: true and the handler runs once; a second call, or a tap after it, answers nothing; an unknown id and an unposted question return false.
- `WatchLoop`'s countdown answer with a question that is not the open one returns false and parks no answer.
- Consent against the real coordinator: Never puts the app on the "Never record these apps" list with no cooldown, as the notification's Never; Record and Ignore act as from the menu; a question that is no longer open returns false and changes nothing.

### Investigation targets
**Required** (read before coding):
- `Sources/WatchLoop+MeetingEnd.swift:76-140, 350-396` — the wait loop, `askToEnd`, answer and withdraw
- `Sources/WatchLoopEndPolicy.swift:20-40, 250-290` — `PendingMeetingEnd` and its deadline
- `Sources/AppNotifying.swift` — requirements and defaults
- `Sources/NotificationManager.swift:370-420, 446-490` — consent by id, meeting-end post, withdraw and tap
- `Sources/WatchLoop+Consent.swift:120-200` — `answerParkedConsent`, `finishConsent`

**Optional** (reference as needed):
- `Sources/ConsentPromptCoordinator.swift:60-90` — `resolve(id:answer:)`
- `Tests/ConsentLoopDoubles.swift` — `ParkingNotifier`, `AnsweringNotifier`

### Key context
- An answer to the prompt is parked for the poll loop, and Stop Watching must drop it both while the question is open and after the answer is parked (project memory, "Approval parked for the poll loop survived Stop Watching"). The new calls use the existing paths, so they add no handoff of their own; keep it that way.
- Every other `AppNotifying` double gets the new requirements through the defaults; override only in doubles a test must answer through.

## Acceptance
- [ ] The tests above were written first and seen failing for the stated reason, then pass.
- [ ] `meetingEndQuestionID` readers are unchanged; `WatchLoop.swift` stays at or below 600 lines and gains no stored state beyond `meetingEndQuestion`.
- [ ] No test double still implements only `answerConsentPrompt(id:granted:)`.
- [ ] Quick commands green; `./scripts/lint.sh` clean with the pinned tools; `./scripts/pre-push.sh --with-appstore` passes (both build variants).

## Done summary
The "Meeting seems to have ended" countdown is now a question value on `WatchLoop`: `MeetingEndQuestion` holds the id, app label, title, body and deadline, and `meetingEndQuestionID` is derived from it. Code outside a notification can now answer both questions by id through the paths a tap uses. The countdown goes through the `MeetingEndQuestions` registry and is answered at most once. The recording prompt goes through the coordinator with a full `ConsentAnswer`, so "Never for this app" lands as the notification's Never does. No UI in this task.

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)



### What changed (commits d785a733 test, d137f31c feat)

- New `Sources/MeetingEndQuestion.swift`. `askToEnd` builds the question before posting, from the deadline of the `PendingMeetingEnd` the wait enforces, and posts exactly its title and body. `withdrawMeetingEndQuestion` clears it.
- `WatchLoop.swift`: the stored `meetingEndQuestionID: String?` was swapped line for line for `meetingEndQuestion: MeetingEndQuestion?` (the file is still 600 lines). The derived `meetingEndQuestionID` and `answerMeetingEndQuestion(_:answer:)` live in the new `Sources/WatchLoop+MeetingEndQuestion.swift`. The readers of `meetingEndQuestionID` (`AppState+MenuBarIcon.swift:13`, the guard in `receiveMeetingEndAnswer`, the withdraw) are unchanged.
- `AppNotifying`:
  - New requirement `@MainActor answerMeetingEndQuestion(id:answer:) -> Bool`, with a default of false in `MeetingEndQuestions.swift`.
  - The requirement `answerConsentPrompt(id:granted:)` became `answerConsentPrompt(id:answer:)`, with a default of false. The `granted:` spelling stays as a plain extension method.
- `NotificationManager`: implements both answers. The countdown answer takes the handler from the registry (`meetingEndQuestions.take`) and runs it at once. The consent answer calls `consentCoordinator.resolve(id:answer:)`.
- `WatchLoop.answerParkedConsent(_:answer:protocolOptions:)` is new; the `granted:` form now wraps it for the menu and the Record Meeting window.
- New `AppState` accessors, each a single member:
  - `meetingEndQuestion` and `answerMeetingEndQuestion(_:answer:)` in the new `AppState+MeetingEndQuestion.swift`.
  - `answerConsentQuestion(_:answer:)` in `AppState+ConsentPrompt.swift`.
- Test doubles: `ParkingNotifier`, the `AppStateConsentPromptTests` notifier and the Record Again test notifier now implement the full-answer requirement. None is left on `granted:` only.

### Tests (each one written before the change)

- `WatchLoopMeetingEndQuestionTests` (new):
  - The question's title and body equal the posted notification, and its deadline is start + 45 s, where the recording ended.
  - The question is set while the countdown runs and nil after every way out: signal back, Keep recording, Stop now, expiry, cap, a new call, a stop by hand, Stop Watching. Keep recording and Stop now are answered through the loop's new call.
  - The loop answers only the open question.
  - `AppState` follows the current loop.
- `NotificationManagerMeetingEndTests`:
  - An answer by id is true and runs the handler once. A second answer and a tap after it answer nothing.
  - An unknown id and an unposted question return false.
- `NotificationManagerSchedulingTests`: `answerConsentPrompt(id:answer:)` resolves with exactly `.granted`, `.declined` or `.never`, once.
- `WatchLoopBrowserConsentTests`, against the real coordinator:
  - Never by id puts the app on the deny list with no cooldown, the same as the notification's Never.
  - Record by id starts the recording, and Ignore by id starts the decline cooldown.
  - A later Never to an answered prompt returns false and changes nothing.
- `AppStateConsentPromptTests`: the prompt window's answer reaches the open prompt with `.never`, and only that prompt.

Base and head observations:

- Base, red: the test commit failed to compile against the unchanged sources, for example `value of type 'WatchLoop' has no member 'meetingEndQuestion'`, `cannot find type 'MeetingEndQuestion' in scope`, `value of type 'AppState' has no member 'answerMeetingEndQuestion'` and, in `AppStateConsentPromptTests.swift:132`, `extra argument 'answer' in call`. Every test calls API that this task adds.
- Head, green: the Quick command ran 212 tests with 0 failures, against 202 tests with 0 failures at baseline. The caller classes outside the Quick filter (Record Again, consent options, stop by hand, added-app identity, pause icon, silence prompt, watching controller) ran 61 tests with 0 failures.
- Wiring-line check (CLAUDE.md, "check at the line that wires it"): seven mutations in two rounds, each restored from git afterwards. Every one failed by assertion for its own reason:
  - The manager's countdown answer returning false: `XCTAssertTrue failed`, and the Keep and Stop rows end at 45 instead of 61 and 20.
  - The manager's consent answer collapsed to yes or no: `("declined") is not equal to ("never")`, and the browser Never by id gets a cooldown.
  - The loop's identity guard removed: `XCTAssertFalse failed - another question`.
  - `AppState` dropping the full answer: `[declined]` instead of `[never]`.
  - A posted body that differs from the question: a body mismatch.
  - The withdraw not clearing the question: `XCTAssertNil failed` in every way out.
  - The loop collapsing Never to a decline: the browser Never by id fails.

baseline: green (the Quick command run with -j 6: 202 tests, 0 failures)

### Gates

- Quick command with `-j 6` in both places, otherwise as written: exit 0, 212 tests, 0 failures.
- `./scripts/lint.sh` with the pinned tools (SwiftFormat 0.64.6, SwiftLint 0.65.1), run from the workspace root: exit 0, 0 violations.
- `./scripts/pre-push.sh --with-appstore`: exit 0. It built both variants in release mode, and built and tested the local model helper. The release logs show no diagnostic in the changed files.

### Choices

- The countdown requirement is named `answerMeetingEndQuestion(id:answer:)`. It mirrors `answerConsentPrompt(id:answer:)` and does not clash with the tap entry `(id:actionIdentifier:)` or with `RecordingNotifier`'s `(_:with:)`. Rule 6.
- `MeetingEndQuestion.app` holds the label the text uses: the pattern's `appName`, or the owner name when that is empty. The task says "the app label". Rule 1.
- `answerParkedConsent(_:answer:)` takes the optional `protocolOptions`, so the `granted:` wrapper delegates to it without a second guard. Rule 6.
- The manager's countdown answer does not withdraw the notification itself. The loop withdraws it at its next poll, as after a tap (R5: "no later than the loop's next poll"). Rule 1.
- I moved the Record Again test double in `Tests/WatchLoopRecordAgainTests.swift`, which is outside the declared Touches, to the full-answer requirement. This is a 4-line test-only change. Rule 1: the acceptance says "No test double still implements only `answerConsentPrompt(id:granted:)`". Left on `granted:`, the double stops being the witness, and `testTheNewRecordingIsItsOwnJobWithDefaultOptions` would fail.
- The test-first red is a compile failure, because the API did not exist. The proof at assertion level comes from the wiring-line mutations above. Rule 1 (CLAUDE.md cross-cutting rules).

### Follow-ups (not part of this task)

- After this change, `ConsentPromptCoordinator.resolve(id:granted:)` and the `AppNotifying.answerConsentPrompt(id:granted:)` extension are used only by tests. Production answers through the full-answer form. The task keeps the extension method on purpose.
- No user route to a mapped feature changed; there is no UI in this task.

Integrated verify on the spec branch: the spec's Quick command with -j 6 at 9abd8c08 (task commits d785a733 and d137f31c cherry-picked onto the spec branch as ecd0b14f and 9abd8c08), exit 0, 215 tests, 0 failures

stage: impl-review - ran [2026-11-15T16:57:11Z..2026-11-15T17:01:58Z] SHIP, three draws (correctness, contracts, integration), no findings (model: gpt-6.1-sol at xhigh)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: ecd0b14f101a06e00ba7137556ebabd40d40c60c, 9abd8c0855906b3d7275a724e7811417c11ee46a
- Tests: cd app/MeetingTranscriber && mkdir -p .build/test-home && swift build --build-tests -j 6 && CFFIXED_USER_HOME="$PWD/.build/test-home" swift test -j 6 --filter 'PromptWindow|PromptPanel|MenuBarIconFrame|MeetingEndQuestion|WatchLoopMeetingEnd|NotificationManagerMeetingEndTests|NotificationManagerSchedulingTests|ConsentPromptCoordinatorTests|WatchLoopAskBeforeRecordingTests|WatchLoopBrowserConsentTests|AppStateConsentPromptTests|NamingWindowPolicyTests|GeneralSettings|AppSettingsTests|MenuBarIconCountdownTests' (exit 0; 212 tests, 0 failures; baseline 202, 0 failures), cd app/MeetingTranscriber && CFFIXED_USER_HOME="$PWD/.build/test-home" swift test -j 6 --skip-build --filter 'WatchLoopRecordAgainTests|WatchLoopConsentOptionsTests|WatchLoopStopByHandTests|WatchLoopAddedAppIdentityTests|MenuBarIconPauseTests|WatchLoopSilencePrompt|WatchingControllerRecordAgainTests|WatchingControllerCallSplitTests' (exit 0; 61 tests, 0 failures), ./scripts/lint.sh with pinned SwiftFormat 0.64.6 and SwiftLint 0.65.1 (exit 0; 0 violations), ./scripts/pre-push.sh --with-appstore (exit 0; Homebrew and App Store release builds, local model helper build and tests), integrated verify: the spec's Quick command with -j 6 at 9abd8c08 (task commits d785a733 and d137f31c cherry-picked onto the spec branch as ecd0b14f and 9abd8c08), exit 0, 215 tests, 0 failures
- PRs: