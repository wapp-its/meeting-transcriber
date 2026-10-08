---
satisfies: [R6, R7]
---
# gh-94-stop-a-detected-meeting-recording-by.3 End any recording from the automation API with stop and scope any

## Description
Adds the owner's opt-in to the automation API (R7, decision D3): `POST /v1/record` with `{"action":"stop","scope":"any"}` ends whatever is recording, through the menu's stop path from task .2, while a plain `stop` keeps its documented microphone-only meaning (R6). One new controller seam, one new server closure, a stricter payload decoder, docs, tests. Depends on .2 so it reuses `WatchingController.stopRecording()` instead of branching on the recording kind a second time.

**Size:** S
**Files:** `app/MeetingTranscriber/Sources/RecordStatusDTO.swift`, `app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift`, `app/MeetingTranscriber/Sources/WatchingController.swift` (one access modifier), `app/MeetingTranscriber/Sources/WatchLoop.swift` (one line), `app/MeetingTranscriber/Sources/DebugRPCServer.swift`, `app/MeetingTranscriber/Sources/DebugRPCServer+V1.swift`, `app/MeetingTranscriber/Sources/AppState+RPC.swift`, `app/MeetingTranscriber/Sources/AppState.swift`, `docs/automation-api.md`, `docs/stream-deck.md`, new `app/MeetingTranscriber/Tests/RecordActionPayloadTests.swift`, `app/MeetingTranscriber/Tests/WatchingControllerStopRecordingTests.swift` (created by .2), `app/MeetingTranscriber/Tests/DebugRPCServerIntegrationTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/RecordStatusDTO.swift, app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift, app/MeetingTranscriber/Sources/WatchingController.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/DebugRPCServer.swift, app/MeetingTranscriber/Sources/DebugRPCServer+V1.swift, app/MeetingTranscriber/Sources/AppState+RPC.swift, app/MeetingTranscriber/Sources/AppState.swift, docs/automation-api.md, docs/stream-deck.md, app/MeetingTranscriber/Tests/RecordActionPayloadTests.swift, app/MeetingTranscriber/Tests/WatchingControllerStopRecordingTests.swift, app/MeetingTranscriber/Tests/DebugRPCServerIntegrationTests.swift]

### Approach
- **Tests first** for the payload and the controller seam (the contract is fixed by R7 and A6).
- **Payload** (`RecordStatusDTO.swift:112-117`): `enum RecordScope: String, Codable { case any }` and `let scope: RecordScope?` on `RecordActionPayload`, with a custom `init(from:)` that throws when `scope` is present and `action != .stop`. An unknown `scope` string already fails the enum decode. Both reach the route's existing "undecodable → 400" guard (`DebugRPCServer+V1.swift:209-211`), so nothing is ever treated as `any`. Keep `RecordAction` (`:76-82`) unchanged: `stopAny` must not become a wire verb, and the planned pause spec adds its verbs there.
- **Controller** (`WatchingController+RecordControl.swift`, beside `applyRecordStop` at `:106-128`): `func applyRecordStopAny() async -> RecordControlOutcome`:
  - `guard await joinStarts() else { return .failed }`, as `applyRecordAction` does (`:55-65`);
  - nothing recording (`watchLoop?.state != .recording`) → `.unchanged`;
  - capture the loop and its `lastError`, call `stopRecording()` (task .2);
  - a detected meeting: first wait until `loop.state != .recording` with the existing bounded join, by making `join(while:)` (`WatchingController.swift:362`) internal instead of private; timeout → `.failed`;
  - then one verdict for both kinds, extracted into a private helper that `applyRecordStop` (`:113-128`) also uses instead of its inline checks: the loop still recording → `.failed`; the loop in `.error` (a stop that threw: `WatchLoop` enqueues nothing) → `.failed`; `lastError` different from the captured value → `.failed` (a record-only write that failed); else `.changed`.
- **Per-recording error** (`WatchLoop.swift`, the `update` that starts a detected recording in `handleMeeting`, `:404-408`): also set `next.lastError = nil`. The detected loop outlives its recordings, so without this a second meeting failing its record-only write with the same message leaves `lastError` unchanged and the verdict answers 200 for lost output. Harmless elsewhere: the menu shows `lastError` only in the `.error` state, and manual loops are built fresh per recording.
- **Server**: `DebugRPCServer` gets `let recordStopAny: () async -> RecordControlOutcome` beside `recordControl` (`DebugRPCServer.swift:95, 125, 144`), with an init default `{ .failed }` so every existing construction compiles unchanged (`DebugRPCServer.swift` is at 578 lines; keep it under 600). In `recordControlResponse` (`DebugRPCServer+V1.swift:208-218`) call `recordStopAny()` when `payload.scope == .any`, else `recordControl(payload.action)` as today; the outcome-to-code switch stays one switch. Update the route doc lines (`:77-78`).
- **Wiring**: `recordRPCClosures()` (`AppState+RPC.swift:168-191`) returns a third closure, `stopAny`, calling `watching.applyRecordStopAny()` (no microphone health seed: a stop needs no microphone); pass it in `buildDebugRPCServer` (`AppState.swift:431-451`).
- **Docs** (`docs/automation-api.md`): endpoint table row (`:69`); in `POST /v1/record` (`:290-339`) a short paragraph next to the verbs on `scope: "any"` (ends any recording; a detected meeting ends as from the menu and its app is held until its call signal has gone; watching stays on; the response waits up to 20 s for a detected stop, since it takes effect at the next detection poll), the 200 bullet keeping "a plain `stop` only ever stops the recording it could have started", the 503 and 400 bullets; the `RecordStatusDTO` `recording` note (`:551-555`); the status-code table rows for 400 and 503 (`:582, 588`). `docs/stream-deck.md`: in "A key for meetings in the room" (`:124-148`) a short recipe for a key that ends any recording, with the body `{"action":"stop","scope":"any"}`, and a line that `mt-cli` has no flag for it yet.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/RecordStatusDTO.swift:72-117` — verbs, outcomes, payload
- `app/MeetingTranscriber/Sources/WatchingController+RecordControl.swift:49-128` — join-first rule and the stop verdict to mirror
- `app/MeetingTranscriber/Sources/DebugRPCServer+V1.swift:120-218` — control-resource routing and the outcome switch
- `app/MeetingTranscriber/Sources/AppState+RPC.swift:146-191` — status projection and the closure bundle
- `app/MeetingTranscriber/Tests/DebugRPCServerIntegrationTests.swift:32-75, 1206-1330` — `startServer` factory and the `/v1/record` cases

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/WatchingController.swift:300-370` — the joins and the private `join(while:)`
- `docs/automation-api.md:277-339, 536-588`, `docs/stream-deck.md:124-205`

### Key context
- `DebugRPCServerIntegrationTests` need real sockets and fail inside the Codex review sandbox (`.flow/memory` workflow note); run them locally and say so in the evidence. The file is `#if !APPSTORE` with `file_length` disabled: extend `startServer` with a defaulted `recordStopAny:` parameter rather than editing existing cases.
- A detected meeting's stop takes effect at the next detection poll (spec A2), so `applyRecordStopAny()` must await it before answering; reading the state right after `stopRecording()` would report it still recording.
- Write docs for the original project's readers: no fork issue numbers or spec ids.
## Acceptance
- [ ] `RecordActionPayloadTests`: `{"action":"stop","scope":"any"}` decodes with `scope == .any`; `{"action":"stop"}` decodes with `scope == nil`; `{"action":"stop","scope":"all"}`, `{"action":"start","scope":"any"}` and `{"action":"toggle","scope":"any"}` fail to decode.
- [ ] Controller (`WatchingControllerStopRecordingTests`): `applyRecordStopAny()` with nothing recording → `.unchanged`; with a microphone-only recording → `.changed`, loop gone, recording enqueued; with an app recording → `.changed`; with a detected meeting on an injected `makeTestWatchLoop(detector: FixedMeetingDetector(), …)` loop → `.changed` only after the loop has left `.recording`, watching still on, one job enqueued, and over the next 0.5 s no new recording; a detected meeting whose recorder throws on stop (`MockRecorder` without a mix path) → `.failed`; in record-only mode with output that cannot be written (a mix path that does not exist, destination a temp folder), two detected meetings on the same loop, each stopped with `applyRecordStopAny()`, both → `.failed` although their error messages are identical. `applyRecordStop` keeps its existing results (`WatchingControllerRecordControlTests` unchanged and green). Plain `applyRecordAction(.stop)` during a detected recording still returns `.unchanged` and the meeting keeps recording.
- [ ] Server (`DebugRPCServerIntegrationTests`, existing `startServer` pattern): a `scope: "any"` stop calls `recordStopAny` and never `recordControl`, answering 200 with the status body for `.changed` and `.unchanged` and 503 for `.failed`; `{"action":"stop","scope":"all"}` and `{"action":"start","scope":"any"}` answer 400 with an empty body and call neither closure; a plain `{"action":"stop"}` still calls `recordControl(.stop)` and never `recordStopAny`.
- [ ] `docs/automation-api.md` documents `scope: "any"` next to `stop` (behaviour, 200/400/503, the 20 s wait for a detected meeting) and still states that a plain `stop` only ends the recording it could have started; `docs/stream-deck.md` has the "end any recording" key recipe.
- [ ] Existing `/v1/record` tests (`WatchingControllerRecordControlTests`, `RPCRecordStatusTests`, the `/v1/record` cases in `DebugRPCServerIntegrationTests`) pass unchanged.
- [ ] Focused run green, read from the log file (locally: the integration cases need sockets): `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/mt-gh94-home swift test --parallel --filter "RecordActionPayload|WatchingController|RPCRecordStatus|DebugRPCServerIntegration|AppStateTests" > /private/tmp/mt-gh94-t3.log 2>&1; echo "exit=$?"` (never pipe the run into tail/head/grep).
- [ ] `PATH="$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH" ./scripts/lint.sh` reports 0 violations, and `./scripts/pre-push.sh --with-appstore` is clean (the server and its tests are `#if !APPSTORE`; the App Store build must still compile without them).
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
