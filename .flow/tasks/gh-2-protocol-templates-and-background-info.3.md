---
satisfies: [R4, R5, R6]
---
# gh-2-protocol-templates-and-background-info.3 Start dialog with template and background info

## Description
Turns the app picker into the one "Start with options…" dialog and carries its choices to the job (spec "Starting with options"): the shared options form and its value types, the "Microphone only" row, the renamed menu item, and the plumbing from the dialog through `WatchingController`/`WatchLoop` into `PipelineJob`. The form built here is reused by tasks 4 and 5. It follows task 2 only because both add `A11yID` constants.

**Size:** M (adapts the existing picker; the new types are small)
**Files:** new `app/MeetingTranscriber/Sources/MeetingProtocolOptions.swift` (`MeetingProtocolOptions`, `ProtocolOptionsDraft`, `ProtocolDestination`, `ProtocolOptionsContext`), new `Sources/ProtocolOptionsForm.swift`, `Sources/AppPickerView.swift`, `Sources/AppPickerStartState.swift`, `Sources/MenuBarView.swift`, `Sources/MeetingTranscriberApp.swift`, `Sources/AppState.swift`, `Sources/ManualRecordingInfo.swift`, `Sources/WatchingController.swift` (+ new `Sources/WatchingController+ProtocolOptions.swift` if the file-length limit asks for it), `Sources/WatchLoop.swift` (+ new `Sources/WatchLoop+ProtocolOptions.swift`, same reason), `Sources/A11yID.swift`, tests
**Touches:** [app/MeetingTranscriber/Sources/MeetingProtocolOptions.swift, app/MeetingTranscriber/Sources/ProtocolOptionsForm.swift, app/MeetingTranscriber/Sources/AppPickerView.swift, app/MeetingTranscriber/Sources/AppPickerStartState.swift, app/MeetingTranscriber/Sources/MenuBarView.swift, app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift, app/MeetingTranscriber/Sources/AppState.swift, app/MeetingTranscriber/Sources/ManualRecordingInfo.swift, app/MeetingTranscriber/Sources/WatchingController.swift, app/MeetingTranscriber/Sources/WatchingController+ProtocolOptions.swift, app/MeetingTranscriber/Sources/WatchLoop.swift, app/MeetingTranscriber/Sources/WatchLoop+ProtocolOptions.swift, app/MeetingTranscriber/Sources/A11yID.swift, app/MeetingTranscriber/Tests/MeetingProtocolOptionsTests.swift, app/MeetingTranscriber/Tests/ProtocolDestinationTests.swift, app/MeetingTranscriber/Tests/ProtocolOptionsFormTests.swift, app/MeetingTranscriber/Tests/AppPickerViewTests.swift, app/MeetingTranscriber/Tests/AppPickerStartStateTests.swift, app/MeetingTranscriber/Tests/MenuBarViewTests.swift, app/MeetingTranscriber/Tests/MenuBarJobMenuTests.swift, app/MeetingTranscriber/Tests/MenuBarViewSessionControlsTests.swift, app/MeetingTranscriber/Tests/MenuBarViewConsentPromptTests.swift, app/MeetingTranscriber/Tests/MenuBarMicrophoneTests.swift, app/MeetingTranscriber/Tests/ManualRecordingTests.swift, app/MeetingTranscriber/Tests/WatchingControllerManualRecordingTests.swift]

### Approach
- Pure types first, tests first: `MeetingProtocolOptions(template:rawBackground:)` trims and turns blank into nil; `ProtocolDestination.resolve(provider:openAIEndpoint:)` and its `notice` with the spec's exact sentences (`ProtocolProvider` has five cases since gh-7: `.claudeCLI`, `.codexCLI`, `.customCommand` under `#if !APPSTORE`, `.openAICompatible`, `.none`, `AppSettings.swift:98-123`; `PipelineController.makeProtocolGenerator` at `PipelineController.swift:334-368`; spec A9: Codex CLI → `.remote("OpenAI (Codex)")`, custom command → `.remote("the custom command set in Settings → Output")`; switch without a default so a new case fails to compile); `ProtocolOptionsContext` (templates incl. built-in first, effective default, destination, recordOnly) built by a new `AppState.protocolOptionsContext()` from settings and `ProtocolTemplateStore.production`.
- `ProtocolOptionsDraft` (`@Observable`: `template`, `background`) with `options` and `reset(to:)`; `ProtocolOptionsForm(context:draft:)` renders the picker (`A11yID.protocolOptionsTemplatePicker`), the `TextEditor` (`protocolOptionsBackgroundEditor`) with an overlay hint while empty, the notice (`protocolOptionsDestinationNotice`) and the record-only note, dimmed with `.recordOnlyDisabled` (`Sources/Settings/View+RecordOnly.swift`).
- `AppPickerView` (`Sources/AppPickerView.swift:37-149`): keep the type and the window id `record-app`; header and window title "Start Recording"; a `StartRecordingDraft` (`@Observable`: `source` = `.microphone` or `.app(RunningApp)`, `title`, `protocolOptions: ProtocolOptionsDraft`) replaces the `@State` selection/title so tests can preset a selection and assert what Start hands over; a first list row "Microphone only"; the title field disabled for it; the noMic caption; `.onAppear` resets the draft (default template, empty background, no selection) as well as reloading the apps. New inputs: `noMic`, `optionsContext`, and the draft (default a fresh one). `onStartRecording` becomes `(ManualRecordingRequest, MeetingProtocolOptions) -> Void`.
- `AppPickerStartState.resolve` gains the selection kind and `noMic`: refused start outranks everything (existing reason), then no selection, then "Microphone only" with noMic (explanation `MicrophoneRecordingAvailability.blockedByNoMicSetting.disabledReason`).
- Scene (`MeetingTranscriberApp.swift:280-297`): route `.app` to `watching.startManualRecording(pid:appName:title:protocolOptions:)` and `.microphone` to `watching.startMicrophoneRecording(protocolOptions:)`, never `beginManualRecording` directly, because the noMic refusal lives in `startMicrophoneRecording` (`WatchingController.swift:377-395`). Window frame grows to fit the form.
- Menu (`MenuBarView.swift:152-157`): the item becomes "Start Recording with Options…" (shortcut R kept); `recordAppLabel(noMic:)` goes away with its tests (`Tests/MenuBarJobMenuTests.swift:40-52`, `Tests/MenuBarViewTests.swift:680-720,840-855` move to the new label). "Record Microphone Only" stays as is.
- Plumbing: `WatchingController.startManualRecording(…, protocolOptions:)`, `startMicrophoneRecording(protocolOptions:)`, `beginManualRecording(_:protocolOptions: = nil)` → `performManualRecording` → `WatchLoop.startManualRecording(pid:appName:title:protocolOptions:)` / `startMicrophoneRecording(protocolOptions:)` (`WatchLoop.swift:211-279`) → `ManualRecordingInfo.protocolOptions` (optional, default nil) → `stopManualRecording` → `enqueueRecording(…, protocolOptions:)` (`WatchLoop.swift:468-516`) → `PipelineJob(protocolTemplate:protocolBackground:)`. `/v1/record` (`WatchingController+RecordControl.swift:78`) and auto-detected meetings pass nil. Record-only writes no options.
- Never add the `record-app` window to the `/screenshot`, `/ui/tree` or `/ui/press` allowlists; it now shows background text.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/AppPickerView.swift:37-149` — the dialog to extend
- `app/MeetingTranscriber/Sources/AppPickerStartState.swift` — start-state decision to extend
- `app/MeetingTranscriber/Sources/WatchingController.swift:374-504` — manual start entry points and their guards
- `app/MeetingTranscriber/Sources/WatchLoop.swift:211-302,468-516` — manual start/stop and job construction
- `app/MeetingTranscriber/Sources/MenuBarView.swift:123-175,240-246` — menu items and the label helper

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/AppPickerViewTests.swift`, `Tests/AppPickerStartStateTests.swift` — existing picker tests
- `app/MeetingTranscriber/Tests/ManualRecordingTests.swift:72-84` — fake-recorder test that a stop enqueues a job
- `app/MeetingTranscriber/Tests/WatchingControllerManualRecordingTests.swift:26-66` — controller-level start tests
- `app/MeetingTranscriber/Sources/MicrophoneRecordingAvailability.swift` — noMic reason text

### Key context
- `MenuBarView` and `MeetingTranscriberApp` bodies sit near the 300 ms type-check budget; add the new inputs as plain stored properties and read `AppState` through single-member accessors (pattern `AppState.swift:413-445`: `pipelineQueue`, `isManualRecording`, `canStopRecording`).
- Checked 2026-10-13 against `wapp/main` 557170da (fit check): `MenuBarView` gained `sessionControls` (gh-94: while `onStopManualRecording != nil` the manual-start items are hidden and Stop Recording shows, `MenuBarView.swift:182-216`), `microphoneSection` (gh-43) and `allTranscriptionsItem` (gh-13), plus the inputs `history`, `onShowAllTranscriptions`, `onRemoveFailedJob`, `consentQuestion`, `onAnswerConsent`, `onSelectMicrophone`, `microphoneMenu`; shortcuts `.`, `m`, `r`, `n`, `p`, `t`, `o` are taken. `recordAppLabel(noMic:)` is at `:374-376` (call site `:213`), the record-app item at `:210-216`, the scene's `record-app` window at `MeetingTranscriberApp.swift:305-322`, `bringWindowToFront(id:)` at `:428`; `WatchingController.startManualRecording` at `:380`, `startMicrophoneRecording` at `:392`, `beginManualRecording` at `:407`; `WatchLoop.startManualRecording` at `:235`/`:259`, `ManualRecordingInfo` built at `:292`, `stopManualRecording` at `:305`, `enqueueRecording(title:appName:recording:trigger:participants:)` at `:465` with `PipelineJob(` at `:501`. `AppPickerView`, `AppPickerStartState`, `ManualRecordingInfo` are unchanged.
- SwiftLint `file_length` warns at 600 and errors at 1000 lines, `type_body_length` at 400/600; `WatchLoop.swift` is at 594, `WatchingController.swift` 592, `MeetingTranscriberApp.swift` 531, `MenuBarView.swift` 479, `AppState.swift` 488, none with an exception. Put the new plumbing into extension files (`WatchLoop+ProtocolOptions.swift`, `WatchingController+ProtocolOptions.swift`) the way `+Consent`, `+RecordControl` and `+StopRecording` do.
- `List(selection:)` is hard to drive in ViewInspector; preset `StartRecordingDraft.source` in tests and tap Start (found by its label, as today) to assert the closure arguments.
- Return in a multi-line `TextEditor` next to a `.defaultAction` button: note in the done summary whether it was checked live; it is an owner check otherwise.
- Do not edit `CLAUDE.md` or `AGENTS.md`.
## Acceptance
- [ ] `MeetingProtocolOptions` normalisation and `ProtocolDestination` (Claude CLI, `localhost`, `127.0.0.1`, `::1`, a remote host, an unparseable endpoint, None) covered with the spec's notice sentences (R6).
- [ ] `AppPickerStartState` covers: refused start, no selection, "Microphone only" with noMic, ready for an app and for the microphone (R5).
- [ ] ViewInspector: the template picker and the background editor write the draft; with a preset app selection Start hands over `.app(pid:appName:title:)` with the draft's options; with "Microphone only" it hands over `.microphone`; the destination notice and the record-only note render from the context; "Start Recording with Options…" calls its closure and "Record Microphone Only" still starts at once (R4, R5, R6).
- [ ] A manual app recording and a microphone recording started with options enqueue a job carrying that template and background; started without options (immediate item, `/v1/record`) the job gets the stamped default and no background (R4, R5).
- [ ] The "Microphone only" start from the dialog is refused with the existing notification while No Microphone is set (R5).
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<scratch> swift test --parallel --filter "AppPicker|MenuBar|ManualRecording|WatchingController|MeetingProtocolOptions|ProtocolDestination|ProtocolOptions|RPCManualRecording" > /private/tmp/<scratch>/t3.log 2>&1` passes (read the log file).
- [ ] `./scripts/lint.sh` passes with the pinned tools, and `swift build -c release -Xswiftc -DAPPSTORE` compiles.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
