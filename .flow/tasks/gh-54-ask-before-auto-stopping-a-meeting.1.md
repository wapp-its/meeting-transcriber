---
satisfies: [R1, R2, R3, R4, R5, R6, R7]
---
# gh-54-ask-before-auto-stopping-a-meeting.1 Implement Ask before auto-stopping a meeting recording

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
A detected meeting whose signal is gone for the end grace is no longer stopped silently: the recording keeps running and a time-sensitive "Meeting seems to have ended" notification offers Keep recording / Stop now; no answer within 2 minutes or Stop now ends it, processed as before but cut back on every track (and the record-only sidecar) to signal loss plus grace, a returning signal withdraws the question, Keep recording keeps it uncut until the signal returns or the 4-hour cap, and every automatic stop logs its reason (R1-R7).

Tier: implementer opus (explicit invocation) · actual: claude-opus-5-5

- Decisions: countdown fixed at 2 min (A3), injectable only for tests; only events before the deadline count, and a signal seen in time outranks Stop now; the cut point is the later of a start-anchored and an end-anchored (stop minus mix length) estimate, so it never cuts meeting audio; tracks are swapped by atomic rename over hard-linked originals, and an original that cannot be renamed back is processed from where it is.
- Tests: WatchLoopMeetingEndTests (R1-R7 flows on a virtual clock, incl. failed cut, Stop Watching, cap, stale answers), WatchLoopEndPolicyTests (every transition, deadline edges), RecordingCutTests (same-point cut, failed read, failed swap, failed rollback, cut-point estimates), NotificationManagerMeetingEndTests (category, answer mapping, withdraw incl. pending, undeliverable), RecordOnlyE2ETests (record-only cut + sidecar stop), WatchLoopMonitorTests (manual R7 lines).
- Existing tests adjusted: E2E/record-only tests that needed the whole fixture now end via the duration cap; tests where the meeting end is incidental inject a short countdown; the policy tests moved to the new state machine.
- baseline: red (5 WatchLoopE2ETests fail pre-edit: WhisperKit model unavailable under the scratch home); still red for the same reason after, unrelated to this change; every other focused suite green before and after.
- Not run: live check in the shipped app (notification appears, Keep/returning signal keep one recording, unanswered yields no longer than today). Needs a build beside the owner's installed app, which would also detect a simulated meeting; left for the conductor/owner (mt-update + meeting simulator).
- Memory capture skipped: .flow/memory is not initialized in this repo (flowctl memory init never run).
- Follow-up (not built, design gap): a crash or quit during the 2-minute countdown leaves the recording to crash recovery, which restores it uncut, so the countdown minutes reach the transcript in that case; closing it needs the pending cut point persisted next to the in-progress marker.
- Follow-up: no RPC hook answers the meeting-end question, so the e2e lanes cannot drive Keep/Stop now without a UI click.

stage: impl-review - ran [2026-10-06..2026-10-06T20:48:51Z] (codex gpt-5.6-sol xhigh; round 1 three draws NEEDS_WORK, 5 findings, validator kept 5, all fixed; re-review SHIP)

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 998fcc6603d6aaa8acd8abda4929c9e489a0f516, eb03caf7887af76bef1c7d90111cd0e4f77e5c9c
- Tests: CFFIXED_USER_HOME=<scratch> swift test --parallel --filter 'WatchLoop|RecordOnly|ManualRecording|NotificationManager|WatchingController|ConsentPromptCoordinator|RecordingSidecar|RecordingCut|AppState|DualSourceRecorder' --skip WatchLoopE2ETests (451 passed), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (0 violations), swift build --build-tests -Xswiftc -DAPPSTORE (App Store variant builds)
- PRs: