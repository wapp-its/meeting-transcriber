---
satisfies: [R10]
---
# gh-2-protocol-templates-and-background-info.5 Template choice in the pending recording prompt (after gh-49)

## Description
Adds "Record with Options…" to the pending-prompt menu section that spec `gh-49-show-a-pending-recording-prompt-on-the` builds (spec "Recording prompt (after spec gh-49)", R10, D2). It is last because it needs gh-49's code on `wapp/main` (the coordinator sets the spec-level dependency) and task 3's options form, and it edits the same menu and scene files as task 4.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/WatchLoop+Consent.swift`, `Sources/WatchLoop.swift` (+ new `Sources/WatchLoop+ConsentOptions.swift` if the file-length limit asks for it), new `Sources/ConsentOptionsView.swift`, `Sources/MenuBarView.swift`, `Sources/MeetingTranscriberApp.swift`, `Sources/AppState.swift`, `Sources/AppState+ConsentPrompt.swift`, `Sources/A11yID.swift`, tests
**Touches:** [app/MeetingTranscriber/Sources/WatchLoop+Consent.swift, app/MeetingTranscriber/Sources/WatchLoop+ConsentOptions.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/ConsentOptionsView.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/AppState+ConsentPrompt.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/WatchLoopConsentOptionsTests.swift, app/MeetingTranscriber/Tests/ConsentOptionsViewTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift, app/MeetingTranscriber/Tests/MenuBarViewConsentPromptTests.swift, app/MeetingTranscriber/Tests/AppStateConsentPromptTests.swift, app/MeetingTranscriber/Tests/WatchLoopAskBeforeRecordingTests+Menu.swift]

### Approach
- gh-49 is merged (PR #109, checked 2026-10-13 against `wapp/main` 557170da): `ConsentQuestion` (`Sources/ConsentQuestion.swift`: `id: UUID`, `app`, `title`, `body`; equality includes `id`), `WatchLoop.pendingConsentQuestion` (set at `WatchLoop+Consent.swift:67`; `pendingConsentApp` is derived from it at `:79`), `answerParkedConsent(_:granted:) -> Bool` at `WatchLoop+Consent.swift:116` (`guard pendingConsentQuestion == question`, then `return notifier.answerConsentPrompt(id: question.id, granted:)`, not `resolveBrowserConsent`; `finishConsent` at `:123` runs later from the awaiting `consentTask` and sets `approvedConsentMeeting` at `:179`), `takeApprovedConsentMeeting()` at `:93` (called from `WatchLoop.swift:347`; it returns only the meeting, so the options need a field taken with it), `clearConsentState()` at `WatchLoop.swift:131-136`, and the `MenuBarView` consent section `consentPrompt` at `MenuBarView.swift:109-136` (inputs `consentQuestion` `:38`, `onAnswerConsent` `:42`; `A11yID.consentPromptRecord` / `consentPromptIgnore`), wired at `MeetingTranscriberApp.swift:171-174` to `appState.pendingConsentQuestion` and `appState.answerConsentQuestion(_:granted:)` in `Sources/AppState+ConsentPrompt.swift`, which discards the Bool (`_ =`); this task's window needs it, so change that accessor. `startManualRecording` (`WatchLoop.swift:259`) calls `declineParkedConsent()`, which is one of the dropped grants.
- Loop (tests first, pattern `Tests/WatchLoopAskBeforeRecordingTests.swift` / `Tests/WatchLoopBrowserConsentTests.swift`): `answerParkedConsent(_:granted:protocolOptions:)` (default nil) stores the options in `pendingConsentProtocolOptions` before resolving; `finishConsent` reads them before `clearConsentState()` and, only when it sets `approvedConsentMeeting`, sets `approvedConsentProtocolOptions`; `clearConsentState()` clears both new fields; the poll loop takes the options together with the approved meeting and passes them through `runMeeting`/`handleMeeting` to `enqueueRecording(…, protocolOptions:)` (task 3 added that parameter). Every dropped grant (watching stopped, another recording running, the call ended) drops the options with it.
- `ConsentOptionsView` (window id `record-meeting-options`, title "Record Meeting"): the question's title and body as posted, the `ProtocolOptionsForm` with a fresh draft, Record (`A11yID.consentOptionsRecordButton`) and Cancel. Record calls `AppState`'s answer with the question it displays; on `false` (question no longer open) it shows "This question is no longer open, so nothing was recorded." and stays open; on success it closes. Cancel only closes. `AppState` keeps the question the window was opened for.
- Menu: a third button "Record with Options…" in gh-49's consent section, handing back the displayed question; it opens the window via `bringWindowToFront(id:)`.
- Never add `record-meeting-options` to the `/screenshot`, `/ui/tree` or `/ui/press` allowlists.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/WatchLoop+Consent.swift` — gate, answer path and `finishConsent` (as merged by gh-49)
- `app/MeetingTranscriber/Sources/WatchLoop.swift:86-117,310-430` — consent state fields, `clearConsentState`, poll loop, `runMeeting`, `handleMeeting`
- `app/MeetingTranscriber/Sources/MenuBarView.swift` — gh-49's consent section

**Optional** (reference as needed):
- `.flow/specs/gh-49-show-a-pending-recording-prompt-on-the.md` (once merged) — the answer-path contract (its A1) and menu section
- `app/MeetingTranscriber/Tests/WatchLoopAskBeforeRecordingTests.swift` — consent answer tests with fake notifier and recorder

### Key context
- A notification answer, the menu's plain Record and `POST /action/confirmBrowserConsent` carry no options; only this window's Record does.
- gh-49's tests to extend rather than duplicate: `Tests/AppStateConsentPromptTests.swift`, `Tests/MenuBarViewConsentPromptTests.swift`, `Tests/WatchLoopAskBeforeRecordingTests+Menu.swift`. SwiftLint `file_length` warns at 600 lines: `WatchLoop.swift` is at 594, so new loop state and the poll-loop handoff go into `WatchLoop+ConsentOptions.swift` or `WatchLoop+Consent.swift`, not `WatchLoop.swift`.
- The options belong to one question: a stale or replaced question must never carry options into another meeting's recording.
- Do not edit `CLAUDE.md` or `AGENTS.md`.
## Acceptance
- [ ] Answering an open prompt with options starts the recording through the existing approval path and the enqueued job carries that template and background (R10).
- [ ] A notification answer and the menu's plain Record leave the job with the stamped default and no background (R10, R4).
- [ ] A stale or replaced question returns false, starts nothing and attaches no options to any later recording; a dropped grant (watching stopped, another recording running, call ended) drops the options (R10).
- [ ] ViewInspector: "Record with Options…" hands back the displayed question; the window shows the question's title and body; Record calls the answer with the draft's options; a false answer shows the no-longer-open text; Cancel does not answer (R10).
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<scratch> swift test --parallel --skip WatchLoopE2ETests --filter "WatchLoop|Consent|MenuBar|AppState" > /private/tmp/<scratch>/t5.log 2>&1` passes (read the log file).
- [ ] `./scripts/lint.sh` passes with the pinned tools, and `swift build -c release -Xswiftc -DAPPSTORE` compiles.
## Done summary
The open "Record <App> meeting?" prompt in the menu now offers "Record with Options…", which opens the "Record Meeting" window (id record-meeting-options) with the prompt's own title and body, the shared template and background form, Record and Cancel. Record answers the prompt through gh-49's single answer path (answerParkedConsent), so it starts the recording exactly as the menu's Record does, and that recording's job carries the chosen template and background; a question no longer open answers nothing and the window says so.

stage: impl-review - ran [..2026-10-13] (codex gpt-5.6-sol at xhigh, receipts effort xhigh; r1 NEEDS_WORK 1 finding, fixed; r2 SHIP 0 findings on 37377bdb; receipts /tmp/impl-review-receipt-gh2-gh-2-protocol-templates-and-background-info.5-r1.json, -r2.json)
Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

Baseline: green before any edit (456 tests, the task's acceptance filter "WatchLoop|Consent|MenuBar|AppState", rc=0).

Commits:
- 9e6fe367 feat(app): choose template and background from the recording prompt. New Sources/ConsentOptionsView.swift (ConsentOptionsDraft, ConsentOptionsView). answerParkedConsent(_:granted:protocolOptions:) keeps the options once its answer resolved the prompt; finishConsent takes them only from its own question before clearing; clearConsentState clears pendingConsentProtocolOptions and approvedConsentProtocolOptions; takeApprovedConsent() (replaces takeApprovedConsentMeeting, deleted) hands meeting and options to the poll loop, which passes them through runMeeting/handleMeeting to enqueueRecording. AppState.answerConsentQuestion returns the loop's Bool and forwards the options; AppState.consentOptionsQuestion keeps the question the window was opened for. Menu button, window scene, three A11yID constants.
- 55c861cc test(app): failing regression test for review r1's finding.
- 37377bdb fix(app): review r1 finding. declineParkedConsent (Stop Watching, manual start) returned early with no open question, so an approval already parked for the next poll survived and a restarted loop recorded on it with the options. It now always clears the consent state and resolves the notifier only while a prompt is open.

Acceptance evidence:
- AC1 (options reach the job): WatchLoopConsentOptionsTests.testRecordWithOptionsRecordsTheMeetingWithThem, through the real poll loop and a PipelineQueue whose default is not the built-in: job carries .file("Board") and the trimmed background. It also answers again with a plain Record from a stale menu, which returns false and leaves the options intact.
- AC2 (notification and plain Record get the default): testANotificationAnswerAndThePlainMenuRecordGetTheDefaultTemplateAndNoBackground (stamped default, nil background, both answers).
- AC3 (stale or replaced question): testAStaleOrReplacedQuestionAnswersNothingAndLeavesNoOptionsBehind (replaced question with the same text and an answer racing a notification tap: false, nothing started, the next recording has the default). Dropped grants: testAGrantDroppedBecauseWatchingStoppedDropsItsOptions, ...AnotherMeetingRecords..., ...TheCallEnded..., and testAnApprovalWaitingForThePollLoopIsDroppedWithItsOptionsWhenWatchingStops (review r1).
- AC4 (views): MenuBarViewConsentPromptTests.testRecordWithOptionsHandsBackTheDisplayedQuestion and the order test (text, text, Record, Record with Options…, Ignore, divider, status). ConsentOptionsViewTests: title and body shown, Record hands the displayed question and the draft's options and closes, a false answer shows "This question is no longer open, so nothing was recorded." and stays open, Cancel closes without answering, a window without a question has Record disabled. AppStateConsentPromptTests: the Bool comes back and the options reach the loop.
- Mutation checks, each restored from the commit afterwards, each turned its tests red: approvedConsentProtocolOptions never set; pendingConsentProtocolOptions not cleared in clearConsentState; options stored before the resolution; a false answer closing the window instead of saying so. The r1 regression test failed before the fix ("Board" and the background reached the restarted recording).

Gates on the committed tree 37377bdb:
- Acceptance filter "WatchLoop|Consent|MenuBar|AppState" (skip WatchLoopE2ETests): 469 tests, rc=0 (log /private/tmp/mt-gh2-home/t5-r1fix.log).
- ./scripts/lint.sh with the pinned SwiftFormat 0.63.0 and SwiftLint 0.65.1: rc=0, 0 violations.
- swift build -c release -Xswiftc -DAPPSTORE: rc=0.
- Not run: CI's swiftlint analyze (unused_declaration), which needs an xcodebuild build. Every new declaration is referenced from Sources, and takeApprovedConsentMeeting is deleted with no reference left in Swift code. Not run: the Homebrew release build.

DECIDED:
- The options are kept after the answer resolved the prompt, not before as the task's Approach words it. Kept before, a second answer to an already resolved prompt (a plain Record from a menu that has not caught up) would overwrite them with nil before finishConsent runs. The resolution never lands synchronously, so nothing reads them earlier. Pinned by the second answer in testRecordWithOptionsRecordsTheMeetingWithThem.
- No WatchLoop+ConsentOptions.swift. The two stored properties have to sit in the class body (WatchLoop.swift, now 598 lines); everything else fits WatchLoop+Consent.swift (201 lines).
- takeApprovedConsentMeeting is replaced by takeApprovedConsent(), returning the meeting and its options as a named pair, so the poll loop cannot take one without the other.
- Review r1 fix changes gh-49 behaviour: Stop Watching or a manual start within one poll interval after a Record answer now drops that approval. Before, it stayed parked and a later Start Watching recorded on it. This matches finishConsent's existing rule that an answer landing after watching stopped records nothing.
- When the window is reopened for a newer question while still open, the draft and the no-longer-open line start over (onChange of the question), because the options belong to one question.
- AppState.consentOptionsQuestion is set by the menu button and not cleared when the window closes; the next opening overwrites it.
- Record stays enabled with provider None and in record-only mode, because the spec says starting with options still records there (the form's notices explain).
- answerConsentQuestion is @discardableResult, so the menu's plain Record and Ignore keep ignoring the Bool.
- No new log lines. The background text reaches no log, notification, /state or /v1 response, and only constant accessibility identifiers are set. record-meeting-options is on none of the /screenshot, /ui/tree or /ui/press allowlists (explicit sets, untouched).

ASSUMED: menu order Record / Record with Options… / Ignore, with the icon slider.horizontal.3 · flip at: app/MeetingTranscriber/Sources/MenuBarView.swift:consentPrompt · test: MenuBarViewConsentPromptTests.testWithAQuestionTheMenuOpensWithItsTextThenItsAnswers
ASSUMED: a Record Meeting window macOS restores at launch shows "No recording prompt is open." with Record disabled · flip at: app/MeetingTranscriber/Sources/ConsentOptionsView.swift:ConsentOptionsView.noQuestion / questionSection · test: ConsentOptionsViewTests.testWithoutAQuestionRecordIsDisabled

BLOCKED: none.

Owner checks (not checked live here):
- Look of the Record Meeting window and the third menu button.
- Return inside the background editor next to Record's .keyboardShortcut(.defaultAction): if Return answers the prompt instead of adding a line, Record needs another key binding (the same open point as the start dialog and Regenerate Protocol).
- A real prompt answered from the window, on the owner's provider: the protocol follows the chosen template and uses the background.

Follow-ups (not fixed): none new. No .flow/features map exists; the new user route is the menu's "Record with Options…" in the open "Record <App> meeting?" section, opening the window "Record Meeting".

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 9e6fe3675d1c1ebcd9379408a40ced2e391b5235, 55c861cc34cdae4ac85b433a9e60fd5f747a4ea0, 37377bdbaffe65cf3999e2eca97dab76f0bb86da
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh2-home swift test --parallel --skip WatchLoopE2ETests --filter "WatchLoop|Consent|MenuBar|AppState" (469 tests, rc=0), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (rc=0, 0 violations), cd app/MeetingTranscriber && swift build -c release -Xswiftc -DAPPSTORE (rc=0)
- PRs: