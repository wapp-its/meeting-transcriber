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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
