# Meeting Transcriber — macOS Architecture

## Overview

Native SwiftUI menu bar application that orchestrates meeting detection, recording, transcription, diarization, and protocol generation. Runs a background watch loop (`WatchLoop`) polling for active meetings and implementing a complete end-to-end pipeline.

**Key pattern:** Observable state models (`@Observable`) with PipelineQueue for decoupled post-processing.

---

## Pipeline

```
                ┌──────────────────────────────────────────────────┐
                │           MeetingTranscriberApp (@main)          │
                │   SwiftUI: MenuBarExtra + Settings + Naming      │
                └──────────────────────────┬───────────────────────┘
                                           │ owns
                ┌──────────────────────────▼───────────────────────┐
                │            AppState (@Observable @MainActor)     │
                │   concern controllers, settings, engines         │
                └────────┬─────────────────────────────────┬───────┘
                         │                                 │ optional
                         │                                 │ (#if !APPSTORE
                         │                                 │  + toggle/env)
                         │                                 ▼
                         │                  ┌──────────────────────────┐
                         │                  │  DebugRPCServer          │
                         │                  │  127.0.0.1:9876          │
                         │                  │  /state /healthz /metrics│
                         │                  │  /screenshot             │
                         │                  │  /action/openSettings    │
                         │                  │  /action/closeSettings   │
                         │                  │  /v1/* (automation API)  │
                         │                  │  Bearer-token + Origin   │
                         │                  │  reject. Driven by mt-cli│
                         │                  └──────────────────────────┘
                         │
                         ▼
                ┌─────────────────────────────────────────────────┐
                │           WatchLoop (@MainActor)                │
                │   idle → watching → recording → watching        │
                └────┬───────────────┬────────────────────┬───────┘
                     │ polls         │ starts/stops       │ enqueues
                     ▼               ▼                    ▼
        ┌─────────────────────┐  ┌────────────────┐  ┌────────────────────┐
        │ MeetingDetecting    │  │ DualSource-    │  │   PipelineQueue    │
        │  • MeetingDetector  │  │   Recorder     │  │   (@MainActor)     │
        │    (CGWindowList +  │  │                │  │                    │
        │     regex)          │  │  AudioTapLib   │  │  Sequential job    │
        │  • PowerAssertion-  │  │  (CATap +      │  │  processing →      │
        │    Detector (IOKit, │  │   AVAudioEng.) │  │  see breakdown     │
        │    sandbox-safe)    │  │  + AudioMixer  │  │  below             │
        │  • MicInputDetector │  │                │  │                    │
        │    (CoreAudio proc) │  │                │  │                    │
        └─────────────────────┘  └────────────────┘  └─────────┬──────────┘
                                                               │
        PipelineQueue per-job processing:                      │
        ┌──────────────────────────────────────────────────────▼─────────┐
        │ 1. Resample to 16 kHz mono (AudioMixer; AVAsset / ffmpeg fb)   │
        │ 2. (opt) FluidVAD silence-trim + timeline remap                │
        │ 3. Transcribe via active engine                                │
        │      └─ TranscribingEngine: WhisperKit | Parakeet             │
        │         (dual-source: each track separately, then merge)       │
        │ 4. (opt) Diarize via FluidDiarizer                             │
        │      └─ Mode: .offline | .sortformer | .nemotron               │
        │      └─ Dual-source: app + mic diarized separately,            │
        │         IDs prefixed R_ (remote) / M_ (mic), then merged       │
        │ 5. SpeakerMatcher: cosine match against speakers.json          │
        │      (centroid + recent-FIFO, threshold 0.40, margin 0.10)     │
        │ 6. Speaker naming UI (suspended via CheckedContinuation)       │
        │ 7. Assign speakers to transcript by temporal overlap           │
        │ 8. Save transcript (.txt)                                      │
        │ 9. Protocol generation                                         │
        │      └─ ProtocolProvider: .claudeCLI | .codexCLI |             │
        │         .customCommand | .openAICompatible | .localModel |     │
        │         .none                                                  │
        │         (.localModel: a helper process per protocol)           │
        │ 10. Save protocol (.md, transcript appended)                   │
        │ 11. Job done; export to Notion in the background (optional)    │
        └────────────────────────────────────────────────────────────────┘
```

State writes to `AppPaths.dataDir`; IPC + queue snapshots to `ipcDir`.

---

## Source Files

### App Entry & UI

| File | Role |
|------|------|
| `AppLauncher.swift` | The actual `@main` — a process entry point that makes the one pre-launch diversion decision (e.g. `--localvqe-selftest`) before `MeetingTranscriberApp`/`AppState` construct, since a conforming `App` type cannot intercept its own launch |
| `MeetingTranscriberApp.swift` | UI shell — SwiftUI scenes, windows, NSOpenPanel, NSWorkspace. Observes `.showSettings` / `.closeSettings` / `.showSpeakerNaming` notifications for RPC- and pipeline-driven scene control; logs menu-triggered protocol-open and quit requests |
| `MeetingTranscriberApp+PureHelpers.swift` | Helpers split out of `MeetingTranscriberApp` at its line cap: the previous-exit report, whether watching starts at launch, opening the last notes file with its moved-or-deleted notice, a job line's Open (a file in the output folder's scope or a Notion page), and handing a Notion page to `ProtocolOpener` |
| `AppState.swift` | `@Observable @MainActor` composition root — wires the concern controllers (`engines`, `watching`, `pipeline`, `permissions`, `channelHealth`, `microphone`, `liveTranscription`, `rpcController`) and exposes the derived UI state (badge, status label) rather than owning it |
| `AppState+Microphone.swift` | The menu-bar body's accessors for the recording's microphone and app-audio channels (the two red tints, and the Microphone entry's `MicrophoneMenuState`), split out of `AppState.swift` at its line cap |
| `LivenessMarker.swift` | Process-lifetime marker (issue #703): written at launch, touched once a minute, removed by a clean AppKit quit; the next launch reads it as `PreviousExit` to tell a crash, kill or power loss from a quit, which the per-recording marker cannot do for an idle app |
| `PreviousExitNotice.swift` | Wording of the launch-time notification for a run that ended without a quit: the window in which nothing was watching for meetings |
| `MenuBarView.swift` | Menu bar dropdown (state, actions, meeting info, the Microphone entry: a submenu whose inline picker checks the chosen microphone and stores a choice in `AppSettings.micDeviceUID`; at the top, the open recording prompt with Record / Record with Options… / Ignore; the "Recordings" section with "All Recordings…") |
| `MenuBarView+LastRecording.swift` | The dropdown's "Last Recording" section: the newest finished job's name, a details line with its app and time ("Teams · Today at 10:30"), and "Open Notes", which opens its notes file or, while Notion export is on, its Notion page ("Open in Notion"), as `JobOpenTarget` resolves it; left out while no finished job has either |
| `MenuBarView+Jobs.swift` | The dropdown's job lines under "In progress" and "Needs you", one line per job with its actions in a submenu; a finished job whose Notion export runs or failed keeps a line there with "Retry Notion Export" and "Discard Notion Retry" |
| `JobMenuSummary.swift` | Status text and symbol of a job's single line in the menu bar dropdown |
| `TranscriptionsView.swift` | The All Recordings window: every job the app knows, searched by title and participant; each row's main button, "…" menu (repeated by its right-click menu) and audio line; several rows selected at once with one right-click menu for them; the footer; the Trash confirmations |
| `TranscriptionsView+RowLabels.swift` | A row's detail line and the titles and accessibility identifiers of its buttons and menu items |
| `TranscriptionsSelection.swift` | The window's selection and Trash-confirmation models, `TrashSelectionPlan` (which selected meetings a Trash action applies to, by each row's own rules) and the footer text |
| `TrashConfirmationText.swift` | Pure wording of the Trash confirmations for one meeting and for a selection, from the record less what the disk answered gone |
| `RecordingRowActions.swift` | Pure decision of a row's main button and menu items, Keep and the two Trash items included, and when they are disabled |
| `RecordingAudioLine.swift` | Pure wording of a row's audio line, its Keep badge and why a deletion stopped |
| `RowAvailability.swift` | The rows' files and audio on disk, read once per row and refresh, so a redraw never reads the disk |
| `AllRecordingsActions.swift` | What the window's controls do, handed to `TranscriptionsView` as one value |
| `RetentionPreview.swift` | What a retention value would delete now, shown before it is saved, and `RetentionChoice`, the picker's value on its way to the setting |
| `MicrophoneMenuState.swift` | Pure decision for the menu bar's Microphone entry: its title (the device a recording reports, otherwise the chosen device or `System Default (<name>)`, a chosen device that is not connected, no microphone available, the "No Microphone" off line), the items (`System Default (<name>)` then the Settings list) and the checked choice, and every string the entry shows |
| `ProtocolOpener.swift` | Opens local protocols with the default handler and prefers an already-running Notion desktop app for Notion pages, falling back to the default handler |
| `MenuBarIcon.swift` | Renders the animated waveform icon + badge overlays (watching dot, question mark while a recording prompt is open, pulse while a meeting-end countdown runs, permission, record-only, channel-silent) |
| `AppPickerView.swift` | App picker sheet for manual recording of any running app |
| `AudioImportTypes.swift` | File types offered by the batch-import and voice-enrollment `NSOpenPanel`s — single source of truth so the ffmpeg-gated vs. natively-decoded format lists stay pinned and testable |
| `A11yID.swift` | Shared accessibility-identifier namespace — one constant per control, referenced by the view modifier, ViewInspector tests, and the `/ui/press` allowlist |
| `SettingsView.swift` | Settings window — `NavigationSplitView` shell (sidebar of tabs) hosting seven topic-grouped sub-views in `Sources/Settings/` |
| `Settings/GeneralSettingsView.swift` | Startup (Launch at login, Start watching when the app opens = `AppSettings.autoWatch`) · Mode (Record-only) · Apps to Watch (Teams/Zoom/Webex/Browser/WeChat/Tencent Meeting/FaceTime/WhatsApp/Slack) · Record Without Asking (per native/mic-input app) · Detection (Poll Interval, Grace Period) |
| `Settings/AudioSettingsView.swift` | Microphone device (the `MicrophoneDevices` list the menu bar's Microphone entry also shows) · VAD (enabled + threshold) · Per-Channel Indicator |
| `Settings/TranscriptionSettingsView.swift` | ASR engine picker · engine-specific options · model status · Vocabulary section · Live transcription (PoC) toggle |
| `Settings/TranscriptionSettingsView+HuggingFaceToken.swift` | The optional Hugging Face token row below the WhisperKit model picker: a write-only field with Save and Remove that shows whether a token is saved, never the token; the token itself lives in the Keychain (`AppSettings+HuggingFaceToken.swift`) |
| `Settings/HuggingFaceModelBrowserView.swift` | Sheet opened by "From Hugging Face…" in the WhisperKit model picker: search field, results with download counts, and for a chosen repository its loadable variants with size, the license, a gated notice and the model-card link. "Use" and "Cancel" report to the presenter and write no setting |
| `HuggingFaceModelSearch.swift` | `@Observable` state of that sheet: the query (searched after a 0.35 s pause, at least 2 characters), the results, the chosen repository's listing and a one-line message. An answer for a query or repository that is no longer current is dropped. Reads the Hugging Face token for each request |
| `HuggingFaceModelCatalog.swift` | Client for the two Hub API calls behind the sheet (`/api/models?search=…&filter=whisperkit`, `/api/models/<repo>?blobs=true`). A variant is a folder with every file `WhisperKitLocalSnapshot` requires; also parses sizes, license and the gated flag. Sends the token as a bearer header only when one is set; logs no token, query or response body |
| `WhisperKitModelChoice.swift` | `@Observable` state of the WhisperKit model choice, owned by `SettingsView`: the open Hugging Face sheet and the "Load the new model now?" offer after a pick. "Use" writes the pick through `AppSettings.useHubModel` and holds the offer back until the sheet has closed; "Later" defers the model on the engine. `Settings/TranscriptionSettingsView+ModelChoice.swift` presents both |
| `WhisperKitStockModel.swift` | The six stock WhisperKit variants in picker order, each with its label and approximate download size (measured 2026-10-06) for the load offer |
| `Settings/VocabularySourceSettingsView.swift` | "Vocabulary source" picker (Local file / URL), shown in the Vocabulary section while "Use custom vocabulary" is on; for URL the address, the Keychain-backed access token, "Update now" and the status line from `RemoteVocabularyController` |
| `Settings/SpeakersSettingsView.swift` | Diarization · Speaker Naming (open the naming window automatically, how long unnamed meetings wait) · Mic Speaker Name · Known Voices · Recognition Stats · Experimental: Diarization Tuning |
| `Settings/OutputSettingsView.swift` | Output folder · Notion export · Meeting Notes (transcript options, AI-title file names, LLM provider, notes language) · Meeting Notes Templates and Template Rules sections |
| `Settings/LocalModelSettingsView.swift` | The local model provider's panel in Settings → Output: the model folder with Choose…, the status line with Check Model (runs the helper's `check` mode, no weights loaded), and the memory and recording notes (`#if !APPSTORE`) |
| `Settings/ProtocolTemplatesSettingsView.swift` | Meeting Notes Templates section: default template picker, Edit and Delete per template file, Create Template, Open Templates Folder; its state and writes live in the `@Observable` `ProtocolTemplatesModel` |
| `Settings/TemplateRulesSettingsView.swift` | Template Rules section: one row per rule (pattern, template, move up/down, delete), Add Rule and the "Try a title" field; its state and writes live in the `@Observable` `TemplateRulesModel`, which lists templates and reads the default through `ProtocolTemplatesModel` |
| `ProtocolTemplateRules.swift` | The template rules: `ProtocolTemplateRule` (pattern + template, stored in `AppSettings.protocolTemplateRules`), the pattern check Settings refuses an invalid pattern with, and `ProtocolTemplateRules.resolve`, which picks a title's template under a time limit per rule and per title |
| `Settings/CommandProviderSettingsView.swift` | Codex CLI note · custom command editor, model and placeholder notes (`#if !APPSTORE`) |
| `Settings/AdvancedSettingsView.swift` | Permissions · Diagnostics |
| `Settings/AboutSettingsView.swift` | Version · bundle identifier · build date · ffmpeg status · project link · Updates |
| `Settings/HelpBadge.swift` / `Settings/SettingsHelp.swift` | Reusable "?" help-popover badge + its shared copy, used across Settings sections |
| `Settings/View+RecordOnly.swift` | `recordOnlyDisabled(_:)` view modifier — dims + disables the Transcription/Protocol/VAD/Diarization sections when record-only mode is on |
| `SpeakerNamingView.swift` | Speaker naming dialog after diarization |
| `NamingJobPicker.swift` | Menu of the meetings waiting for names, above the naming dialog once more than one waits (a menu so the content-sized window stays narrow) |
| `NamingGraceKey.swift` | Identity of one keyboard-grace window in the naming dialog — what counts as "a new grace window" (data revision + pending-job count), so the gate re-locks when another job steals focus |
| `KnownVoicesView.swift` | Manage persisted speaker DB (rename, delete, merge) — embedded in `SpeakersSettingsView` |
| `RecognitionStatsView.swift` | Recognition stats display — aggregate counts from `recognition_log.jsonl` |
| `VoiceEnrollmentView.swift` | Voice enrollment sheet — seeds `speakers.json` from an existing audio file |
| `AppSettings.swift` | `@Observable` settings persisted to UserDefaults |
| `AppSettings+Computed.swift` | Values derived from stored `AppSettings` toggles, split out to keep `AppSettings.swift` under the line cap |
| `AppSettings+OutputDirectory.swift` | Everything derived from `customOutputDirBookmark`, split out to keep `AppSettings.swift` under the line cap |
| `AppSettings+LocalModel.swift` | The local model's folder: the plain path for display and the security-scoped bookmark reads go through, taken by value when a generator is made so a later change never reaches a running protocol (`#if !APPSTORE`) |
| `AppSettings+Vocabulary.swift` | Custom-vocabulary file selection, sandbox bookmark resolution, and validation state — shared by both ASR engines; `effectiveVocabularyPath` / `effectiveVocabularyBookmark` hand the engines the local file or the URL source's cached copy |
| `AppSettings+TerminologyRules.swift` | Optional terminology-rules file: selection, bookmark, per-job read and the Settings status; the text area remains the default source |
| `RemoteVocabularyController.swift` | Keeps the URL source's cached copy current (launch, 2 s after a change, "Update now", hourly), adopts only valid downloads, and publishes the `RemoteVocabularyStatus` Settings shows; owned by `AppState` as `remoteVocabulary` |
| `LegacyDefaultsMigration.swift` | One-shot carry-over of settings from the pre-rename bundle identifier, since `UserDefaults` is scoped per identifier |
| `LoginItemController.swift` | Launch at login via `SMAppService.mainApp`, behind `LoginItemRegistering` so tests use a fake; the status is read from macOS and never stored in `AppSettings` |
| `UpdateChecker.swift` | Checks GitHub releases for newer versions, drives the menu bar update badge |
| `Settings/PickerLanguages.swift` | Language picker entries for WhisperKit and Parakeet language selectors |
| `LiveCaptionsState.swift` | `@Observable` live-captions state (per-channel hypotheses + finalised utterances) + RPC-wire types |
| `LiveCaptionsOverlay.swift` | SwiftUI caption-bar content (recent finals + per-channel hypotheses) hosted in `LiveCaptionsWindow` |
| `LiveCaptionsWindowController.swift` | Borderless click-through NSPanel hosting the caption overlay; Option-drag moves it by screen-coordinate deltas, clamped to the screen visible frame (see `architecture/transcription.md`) |
| `LiveCaptionsSize.swift` | Caption-bar size presets (Small/Medium/Large): font size paired with the fixed panel dimensions that fit it; `AppSettings.liveCaptionsSize` |
| `ProcessingStatsView.swift` | Read-only average per-stage processing durations from `stage_timing.jsonl` (Settings → Speakers) |

### Core Pipeline

| File | Role |
|------|------|
| `WatchLoop.swift` | Main orchestrator: detect → record → enqueue PipelineJob |
| `WatchLoop+ManualRecording.swift` | The poll loop that decides when a manually started recording ends, split out of `WatchLoop` |
| `WatchLoop+StopByHand.swift` | "Stop Recording" for a detected meeting: parks a request the meeting-end wait takes at its next poll, so the recording ends through the same stop, cut and enqueue as every other meeting end; split out of `WatchLoop` |
| `WatchLoop+RedetectionHold.swift` | Keeps an app out of detection after its recording was ended while its call signal stayed, until the first watching poll finds that signal gone; split out of `WatchLoop` |
| `WatchLoop+ResumeHold.swift` | When watching resumes after a manual recording, puts every meeting the detector reports signalling (`MeetingDetecting.signallingMeetings()`) under the re-detection hold, so a call that ran through the recording is not recorded or asked about from its middle; split out of `WatchLoop` |
| `RedetectionHolds.swift` | Pure per-app hold set behind `WatchLoop+RedetectionHold`, keyed by the detector identity (`AppMeetingPattern.appName`) |
| `WatchLoopEndPolicy.swift` | Pure decision logic for `waitForMeetingEnd` (grace-period / max-duration) |
| `PendingRecordingCut.swift` | The meeting-end cut of one in-progress recording, stored while the "meeting seems to have ended" question is open in an owner-only `<stem>_pending_cut.json` beside the recording's in-progress marker, so a crash while asking does not lose it; every change is synced to disk, and a process-wide hold keeps recovery off a cut a live stop still owns |
| `WatchLoopState.swift` | Value-type snapshot of `WatchLoop`'s observable fields (for tests and RPC) |
| `ManualRecordingMonitorPolicy.swift` | Pure decision logic for manual recording stop conditions (process-died vs max-duration) |
| `MeetingDetecting.swift` | `MeetingDetecting` protocol + `DetectedMeeting` model |
| `MeetingDetector.swift` | Window title polling, pattern matching, confirmation counting, cooldown. Not the production detector (that is `CompositeMeetingDetector` over `PowerAssertionDetector` + `MicInputDetector`); production uses only its `systemWindowList` to look up meeting titles |
| `MeetingTitleMatcher.swift` | Compiled idle/meeting title regex semantics for one `AppMeetingPattern` |
| `PowerAssertionDetector.swift` | IOKit power assertion–based meeting detection (sandbox-safe); carries the Chrome WebRTC pattern for browser meetings (issue #503) |
| `PowerAssertionDetector+Diagnostics.swift` | "Saw something that looks like a meeting and did not act on it" diagnostic, split out of `PowerAssertionDetector` (line-cap) |
| `MicInputDetector.swift` | Third `MeetingDetecting` strategy: watches which processes hold `kAudioProcessPropertyIsRunningInput` via the Core Audio process-object API — covers call apps (WeChat, Tencent Meeting, FaceTime, WhatsApp, Slack Huddles) with no reliable power-assertion signal; each app opt-in and off by default |
| `MeetingPatterns.swift` | Regex patterns for Teams, Zoom, Webex, browser (Chrome WebRTC) |
| `BrowserConsentPolicy.swift` | Pure decision logic for the browser-meeting "ask before recording" prompt — decline cooldown (issue #503) |
| `ConsentAnswer.swift` | Three-way outcome of a consent prompt (yes / no / unanswered) — kept distinct from a `Bool` so a decline and a timeout get different re-prompt cooldowns (issue #543) |
| `BrowserConsentReadiness.swift` | Whether the recording consent prompt can actually reach the user while any watched app asks first — polls `NotificationVisibility` since the prompt is itself a notification and a broken notification channel can't report its own brokenness |
| `ConsentPromptCoordinator.swift` | Coordinates an async yes/no recording-consent prompt: register pending decision by id, resolve once via answer or timeout |
| `WatchLoop+Consent.swift` | Recording consent gate, split out of `WatchLoop`: every detected meeting asks unless its app is set to record without asking (`AppMeetingPattern.asksBeforeRecording`); browser meetings always ask |
| `DualSourceRecorder.swift` | Orchestrates AudioTapLib capture + mic, mixes tracks |
| `RecordingProvider.swift` | Protocol abstraction over `DualSourceRecorder` for mock injection in `WatchLoop` tests |
| `WatchLoop+RecordOnly.swift` | Record-only output branch (moves WAVs + writes `RecordingSidecar`), split out of `WatchLoop` |
| `ProtocolResumePolicy.swift` | Decides what the snapshot restore does with a job interrupted mid-run: resume from the saved transcript, just finish, or run in full. Keys on the interrupted stage, never on "a transcript exists", because stage 1 writes a draft without speaker labels |
| `AudioPersistencePolicy.swift` | Decides per finished-job source file whether to relocate it into the output folder or leave it in place (staging-dir recording vs. user-picked import) |
| `TranscribingEngine.swift` | `TranscribingEngine` protocol + `mergeDualSourceSegments` default impl |
| `WhisperKitEngine.swift` | WhisperKit transcription engine (99+ languages, ~1 GB model) |
| `WhisperDecodingClient.swift` | Narrow decode boundary used by `WhisperKitEngine` — production forwards to WhisperKit, tests capture the exact options passed |
| `WhisperVocabularyPrompt.swift` | Converts the shared custom-vocabulary file into a bounded WhisperKit decoder prompt (experimental, off by default) |
| `ParakeetEngine.swift` | NVIDIA Parakeet TDT v3 via FluidAudio (25 EU languages, ~50 MB, ~10× faster) |
| `ParakeetTokenGrouping.swift` | Pure token-grouping logic extracted from `ParakeetEngine` (testable) |
| `ParakeetVocabularyConfiguration.swift` | Identity of one Parakeet CTC vocabulary configuration (path + bookmark + file revision) and its preparation lifecycle |
| `VocabularyFileAccess.swift` | Resolves persisted sandbox access for the shared custom-vocabulary/terminology files, brackets reads with the matching security scope |
| `RemoteVocabulary.swift` | URL vocabulary source types: `VocabularySource`, address validation (https with a host), validators, failures and the Settings status sentences |
| `RemoteVocabularyFetcher.swift` | One conditional GET (ETag / Last-Modified, optional `Authorization: Bearer`) over its own uncached `URLSession`: refuses redirects to http and, with a token, to another host; caps the body and the total time |
| `RemoteVocabularyCache.swift` | One cached copy plus JSON sidecar per address and bundle identifier in `AppPaths.remoteVocabularyCacheDirectory`; atomic replace, sidecar trusted only when it matches the text |
| `TerminologyNormalizer.swift` | Opt-in post-ASR canonical-spelling rules (`Canonical => variant \| variant`), engine-independent |
| `StreamingTranscriber.swift` | Per-channel live transcription actor (FluidVAD streaming → `engine.transcribeSamples` → partial/final captions) |
| `PipelineQueue.swift` | Decouples recording from post-processing, sequential job pipeline |
| `PipelineQueue+Stages.swift` | Per-stage job processing (transcribe → diarize → naming → protocol), split out of `PipelineQueue` (line-cap) |
| `PipelineQueue+Notion.swift` | Optional Notion export step and page tracking for protocol retries and re-exports |
| `NotionClient.swift` | Notion API client: page create and re-export, schema checks, request batching within Notion's limits, 429 backoff |
| `NotionModels.swift` | Request and response types for the Notion API |
| `MarkdownToNotionBlocks.swift` | Converts protocol Markdown and the transcript into Notion blocks |
| `JobOpenTarget.swift` | Decides what a finished job's Open action opens: the Notion page or a local file |
| `ProtocolOpener.swift` | Opens a job's target, preferring a running Notion desktop app |
| `Settings/NotionExportSettingsView.swift`, `Settings/NotionExportSettingsModel.swift` | Notion settings UI and its connection and schema state |
| `PipelineQueue+Recovery.swift` | Snapshot restore for `PipelineQueue` |
| `PipelineQueue+OrphanRecovery.swift` | Orphaned-recording recovery for `PipelineQueue`: the staging scan and the jobs it creates |
| `RecoveredCut.swift` | Applies a stored meeting-end cut when launch recovery brings back a recording the app died with while asking: collects the stored cuts before headers are repaired, places the cut by the live cut's rule (or applies one already resolved), refuses a recording that ran on past the countdown's deadline, and logs one line per stored cut it settles; the orphan scan passes over a recording whose cut is not settled yet (its stem held by a live stop of this process, or a stored cut beside it that recovery could still apply), so it is never queued before it is cut |
| `PipelineQueue+EchoBleed.swift` | Warns when a dual-source recording carries the same speech on both tracks (loudspeaker bleeding into the microphone) — measurement half of the echo mitigation (issue #581) |
| `PipelineQueue+EchoCancellation.swift` | Removes the far end from the microphone track before anything reads it — cancellation half of the echo mitigation, the other branch of `EchoRemedy` |
| `EchoBleedDetector.swift` | Decides `.notMeasured` / `.clean` / `.affected` for a dual-source recording, from per-10s-window envelope correlation between the two tracks |
| `EchoSegmentClassifier.swift` | Per microphone segment, decides whether the app track's energy explains it (`.echoOnly`, suppressed from the transcript) or the local speaker also spoke (`.mixed`/`.ownVoice`, kept) |
| `EchoEmbeddingQuarantine.swift` | Holds mic-track speaker embeddings back from `speakers.json` on an echo-affected recording, so a voice learned from contaminated audio is never folded into a stored centroid |
| `EchoRemedy.swift` | Decides which of the two echo remedies (cancellation vs. transcript dedup) a recording gets — they do not compose |
| `EchoCancelling.swift` | Abstraction seam for acoustic echo cancellation; `LocalVQECanceller` is the concrete implementation |
| `EchoCancellationSelfCheck.swift` | Judges a cancellation run from the canceller's own per-window report — a difference between far-end and no-far-end windows, not a level, so a run that quietly removed nothing is caught |
| `EchoFrameChunking.swift` | Pure hop arithmetic for streaming a signal through LocalVQE's fixed-256-sample-hop frame API |
| `LocalVQECanceller.swift` | `EchoCancelling` implementation over the vendored LocalVQE static library (`CLocalVQE`) — owns the C context lifecycle, drives the streaming frame API hop by hop |
| `LocalVQECanceller+File.swift` | File-to-file half of `LocalVQECanceller` — the shape the pipeline calls |
| `LocalVQEModel.swift` | Resolves the bundled LocalVQE AEC model (`localvqe-*.gguf`) the canceller runs against; refuses to silently fall back when an override path is missing |
| `LocalVQESelftest.swift` | Hidden `--localvqe-selftest` CLI probe proving the statically linked library resolves its compute backend from inside a signed `.app` bundle (`#if !APPSTORE`) |
| `PipelineJob.swift` | Pipeline job model (waiting → transcribing → diarizing → generatingProtocol → done) |
| `PipelineSnapshot.swift` | Pure I/O helpers for persisting `PipelineQueue` jobs to disk (atomic rename) |
| `PipelineEventLog.swift` | Append-only JSONL log of `PipelineQueue` job state transitions |
| `StageTimingStats.swift` | Per-stage wall-clock duration tracking, backs `ProcessingStatsView` |
| `ProcessedRecordingsLedger.swift` | File-backed ledger of mix-file paths that completed the pipeline (dedupes recovery re-processing) |
| `InFlightRunRegistry.swift` | Process-wide record of currently-executing pipeline runs, so a second `PipelineQueue` built while the first is still working can't double-start the same job/audio (issue #558) |
| `SnapshotWriterActor.swift` | Actor isolating pipeline queue snapshot writes (prevents main-actor stalls on macOS 26 rename deadlock) |
| `SpeakerNamingSession.swift` | Collaborator `PipelineQueue` calls for the speaker-naming work still owned by the queue, split out for size |
| `SpeakerNamingSession+Late.swift` | Late-confirm and late re-diarization paths for speaker naming |
| `SpeakerNamingData.swift` | `PipelineQueue.SpeakerNamingData`/`.Segment`/`SpeakerNamingResult` value types, nested under `PipelineQueue` for source compat |
| `StaleNamingTimeout.swift` | How long a meeting may wait for speaker names before the launch-time cleanup accepts the automatic names (1 day · 7 days · never) |
| `SpeakerNamingStore.swift` | Disk persistence for a job's speaker-naming sidecars, keyed by per-job slug; pure I/O, no queue state |
| `SpeakerKey.swift` | Speaker identity in the dual-track pipeline: raw diarizer id + track; single home for the `R_`/`M_` prefix convention |
| `NamingWindowPolicy.swift` | Pins the "Name Speakers" window so it stays available while the user works in other apps (issue #504) |
| `LiveTranscriptionController.swift` | Wires the per-channel live-caption pipeline (streaming or re-transcribe) to both `DualSourceRecorder` sinks (mic + app), feeds `LiveCaptionsState` |
| `LiveTranscriptionController+Nemotron.swift` | Nemotron streaming-pipeline construction, split out for size; injectable factory for testing the build + model-load-failure fallback |
| `LiveTranscriptionCoordinator.swift` | `@Observable` coordinator: builds + arms `LiveTranscriptionController`, feeds `LiveCaptionsState` |
| `LiveCaptionPipeline.swift` | Per-channel live captioning strategy protocol (English EOU streaming \| Nemotron streaming \| WhisperKit/Parakeet re-transcribe) |
| `LiveCaptionsGate.swift` | Pure decision logic for live captions routing: master toggle + explicit engine language (`en` → English EOU streaming, a language in `LiveCaptionLanguages` → Nemotron streaming, auto-detect or any other language → re-transcribe or none) — shared by `AppState`, coordinator, and controller. Overlay visibility is a separate UI AND (`overlayVisible`); it is not a strategy input |
| `EouStreamingCaptionSession.swift` | English low-latency streaming caption session via FluidAudio Parakeet EOU, backed by `UtteranceRingBuffer` |
| `NemotronStreamingCaptionSession.swift` | Multilingual (non-English) low-latency streaming caption session via FluidAudio Nemotron |
| `NemotronAsrManager.swift` | Production seam wrapping FluidAudio's Nemotron model + Silero VAD for `NemotronStreamingCaptionSession` |
| `UtteranceRingBuffer.swift` | Rolling 16 kHz sample buffer addressable by absolute ms timestamp (feeds streaming caption sessions) |
| `AsyncSerialGate.swift` | First-come-first-served async mutual exclusion that suspends waiters instead of blocking a thread; serialises Nemotron 3 runs and model loads |
| `ModelWarmupQueue.swift` | Serial FIFO gate for model warm-up loads — avoids compiling/loading the ASR engine and live-caption models concurrently at launch |
| `EngineModelState.swift` | App-owned model lifecycle state for a `TranscribingEngine`, decoupled from any ASR vendor's own enum |
| `EngineController.swift` | `@Observable @MainActor` engine selection + model lifecycle controller (language/vocabulary sync, preload) |
| `PipelineController.swift` | `@Observable` controller owning `PipelineQueue` lifecycle (wired by `AppState`) |
| `OutputDirectoryResolver.swift` | Decides a recording's output folder at the two seams that capture it (queue build, record-only write); notifies once per episode when the chosen folder cannot be reached and the default stands in |
| `WatchingController.swift` | `@Observable` controller owning `WatchLoop` lifecycle (wired by `AppState`) |
| `WatchingController+Detectors.swift` | Which detection strategies auto-watch runs, and how the "Apps to Watch" toggles filter them — line-cap split, pure and settings-driven |
| `WatchingController+WatchControl.swift` | The `/v1/watch` control surface: meeting watching as an idempotent resource a remote caller can drive |
| `WatchingController+RecordControl.swift` | The `/v1/record` control surface: microphone-only recording as an idempotent resource a remote caller can drive |
| `WatchingController+StopRecording.swift` | The menu's "Stop Recording": ends whatever records, a manual recording as before and a detected meeting through its loop, which keeps watching |
| `WatchingController+ResumeWatching.swift` | Turns meeting watching back on after a manual recording that took it over, however it ended (a refused or failed start included): one pending intent, consumed when the resumed loop is installed and cancelled by a `/v1/watch` stop; the resume asks for no permission and holds the calls already running |
| `WatchingController+LoopFactory.swift` | Builds the two watch loops the controller runs, the one that watches for meetings and the one a manual recording runs on — line-cap split |
| `WatchStatusDTO.swift` | Wire shape for `GET`/`POST /v1/watch` — the meeting-watching lifecycle as a small, stable projection |
| `RecordStatusDTO.swift` | Wire shape for `GET`/`POST /v1/record` — the microphone-recording lifecycle, same audience as `WatchStatusDTO` (Stream Deck key, Shortcut, shell script) |
| `WavHeaderRepair.swift` | Repairs unfinalized WAV files from crash-interrupted recordings (RIFF/data chunk size fix). Runs in the launch recovery of the staging folder, which also applies a stored meeting-end cut (`RecoveredCut`) before a recovered recording is queued |
| `FluidDiarizer.swift` | On-device speaker diarization via FluidAudio CoreML/ANE |
| `FluidDiarizer+SortformerEmbeddings.swift` | Post-hoc WeSpeaker embedding extraction for the Sortformer and Nemotron 3 modes — overlap-excluded masks feed `SpeakerMatcher` (DiariZen-style hybrid) |
| `FluidDiarizer+Nemotron.swift` | Nemotron 3 mode: the streaming loop that feeds a recording through `Nemotron3Diarizer` in 60 s pieces, one run at a time per instance; the model load sits behind an injectable seam and a process-wide load gate |
| `FluidDiarizer+NemotronModelLoad.swift` | The real Nemotron 3 model load (HuggingFace download, CoreML load on CPU + Neural Engine), the default of that seam |
| `SpeakerMatcher.swift` | Speaker embedding DB + cosine similarity matching |
| `SpeakerMatcher+Logging.swift` | Forensic match-decision logging (pseudonymized speaker names via `String.pseudonymized`) |
| `LiveSpeakerMatcher.swift` | Actor for real-time speaker matching per finalized live-caption utterance; same WeSpeaker CoreML model as batch path; caches mask frame count in `UserDefaults` for fast cold start |
| `StoredSpeaker.swift` | Codable speaker DB entry model (centroid + FIFO embeddings + metadata) |
| `DiarizationProcess.swift` | Diarization result types, DiarizationProvider protocol, speaker assignment (standard + dual-track) |
| `ProtocolGenerator.swift` | Shared protocol utilities: `ProtocolGenerating` protocol, prompts, file I/O, `ProtocolError` |
| `ClaudeCLIProtocolGenerator.swift` | Claude CLI subprocess protocol generation (`#if !APPSTORE`) |
| `CommandProtocolGenerator.swift` | Codex CLI preset and custom command protocol generation (`#if !APPSTORE`) |
| `CommandTemplate.swift` | The custom command's placeholder rules: `{model}`, `{prompt_file}`, `{transcript_file}`, `{output_file}` (`#if !APPSTORE`) |
| `CLIProcessRunner.swift` | Shared runner for every CLI provider: no shell, private run folder, wall-clock timeout, output cap (`#if !APPSTORE`) |
| `OpenAIProtocolGenerator.swift` | OpenAI-compatible API protocol generation (Ollama, LM Studio, etc.) |
| `LocalModel/LocalModelProtocolGenerator.swift` | Local model protocol generation: sends the same prompt as the other providers to the bundled helper through `LocalModelGate`; also holds `LocalModelLimits`, every fixed limit of a local run (`#if !APPSTORE`) |
| `LocalModel/LocalModelGate.swift` | The one way into the local model for the whole app, owned by `PipelineController`: admits one helper at a time in arrival order, runs the memory guard's admission check and watchdog, holds every start while a recording runs and ends a running helper when one starts (`#if !APPSTORE`) |
| `LocalModel/LocalModelMemoryGuard.swift` | Pure memory decisions and the system probe behind them: start only at normal pressure with free plus inactive memory of at least the weights plus 6 GB, end a running helper at warning pressure or below 4 GB; an unreadable figure fails closed (`#if !APPSTORE`) |
| `LocalModel/LocalModelHelperRunner.swift` | One helper process from start to confirmed exit: fixed argument vector (no shell), request file on stdin, private run directory as working directory, stderr read for progress lines; ends it with SIGTERM, then SIGKILL, on a deadline or when asked (`#if !APPSTORE`) |
| `LocalModel/LocalModelHelperLocator.swift` | Finds the helper in the app bundle, `Contents/Helpers` first (`#if !APPSTORE`) |
| `LocalModel/LocalModelRunDirectory.swift` | The owner-only directory one helper run works in (request and protocol), removed after the helper exited; a launch removes leftovers whose process is gone (`#if !APPSTORE`) |
| `LocalModel/LocalModelOutcome.swift` | The helper's exit statuses (the app's copy of the helper README's table, kept in step by a test) and every way a local generation ends other than a written protocol (`#if !APPSTORE`) |
| `LocalModel/LocalModelCheck.swift` | Settings' Check Model: runs the helper's `check` mode on a folder and decodes its one-line JSON report (`#if !APPSTORE`) |
| `PipelineQueue+LocalModel.swift` | Where the queue meets the gate: the job a generation runs under, waiting out a recording that ended the helper and then generating again, and a job cancel that reaches its helper |
| `WatchingController+LocalModel.swift` | Composes the one recording-activity signal (detected meeting, manual recording) and pushes it to the gate whenever an input changes, so a recording never waits for the model |
| `RecordingSidecar.swift` | Metadata sidecar written next to recordings in record-only mode |
| `RecordingFileSuffix.swift` | Filename suffix constants for dual-source recordings (`_app.wav`, `_mic.wav`, `_mix.wav`) |
| `SilentRecordingMonitor.swift` | Pure state machine detecting fully-silent recordings (both channels below threshold) |
| `ChannelHealthMonitor.swift` | Pure state machine for per-channel asymmetric silence detection (one channel live, other dead) — levels + hysteresis, drives the menu-bar tint |
| `ChannelHealthController.swift` | `@Observable` controller polling channel dBFS levels and driving `ChannelHealthMonitor` |
| `ChannelFaultMonitor.swift` | Pure state machine deciding whether a channel has stopped delivering, from per-buffer ages rather than levels (issue #614) — drives the "Capture Channel Silent" notification, deliberately separate from the level-based tint |
| `PairedImportPanelDelegate.swift` | `NSOpenPanel` delegate + accessory view for paired dual-source file import |
| `PairedRecordingResolver.swift` | Groups recording URLs into dual-source groups (app + mic pairs, singletons) for reimport |
| `AudioCapturing.swift` | The part of `AudioTapLib.AudioCaptureSession` one recording drives — the consumer-side protocol `DualSourceRecorder` depends on |
| `DualSourceRecorder+BuildRecording.swift` | Turning a finished capture session into the files the pipeline consumes, split out of `DualSourceRecorder` |
| `DualSourceRecorder+Microphone.swift` | The running recording's microphone device, whether a microphone track is being captured, and switching it to another device, forwarded to the capture session; the tapped process ids it reports beside them are stored in `DualSourceRecorder` for the recording's lifetime |
| `MicrophoneController.swift` | `@Observable @MainActor` owner of "which microphone" state: attached to each recording on the same transitions as `ChannelHealthController`, it hands a changed `AppSettings.micDeviceUID` to the running recording (empty as System Default) and publishes the device the recording reports it captures from, refreshed once a second; also holds the microphone list and the macOS default input's name for the menu, refreshed at launch, at each recording start, when a device connects or disconnects and when the default input changes |
| `MicrophoneController+MeetingProbe.swift` | Runs the meeting-app microphone probe while a recording taps a meeting app and its microphone track is running: every fifth tick one read on the controller's own serial queue (a probe due while one is out is skipped and counted), the result back by a main-actor hop and dropped unless its recording is still attached, then the verdict, the log lines (the `[debug]` names line only with Verbose Audio Logging), the one time-sensitive notification and the menu hint |
| `MeetingMicrophoneProbe.swift` | Hardware side of the probe: maps the tapped process ids to Core Audio process objects and reads, per process, whether it runs input and its input devices (input scope), per device UID, name and transport type; every read keeps its `OSStatus`, and the four raw reads are injectable for tests |
| `MeetingMicrophoneVerdict.swift` | Pure decision: match, mismatch (with the meeting app's devices) or undetermined with its reason (`noProcessCapturingInput`, `unidentifiableDevice`, `unreadableProperty`, `recordedMicrophoneUnknown`); transports judged by an allow-list of physical kinds |
| `MeetingMicrophoneWarningPolicy.swift` | Pure policy and log-line builders for the probe: two consecutive mismatches before the one notification per recording, the menu hint while the latest verdict is a mismatch, log entries on the first probe and on changes (at most 20 per recording), the stop summary, and the notification and hint wording; no device name outside the `[debug]` line and no device UID in any line |
| `MicrophoneDevices.swift` | The microphone list Settings → Audio and the menu bar share (AVFoundation discovery, in its order) and the macOS default input's name, read from Core Audio rather than from AVFoundation's default device |
| `RecordingSource.swift` | What a single recording captures (app PID + mic on/off), replacing an untyped tuple |
| `ManualRecordingInfo.swift` | Info about a manually started recording session, as opposed to one a detector started |
| `ManualRecordingRequest.swift` | What the user asked `WatchingController` to record by hand (app-picker vs. microphone-only) |
| `AppPickerStartState.swift` | Whether the app picker can start a recording, and if not, why |
| `MicrophoneRecordingAvailability.swift` | Whether the menu bar's "Record Microphone Only" item can start a recording, and if not, why |
| `ConsentDenyList.swift` | Persisted "Never for this app" consent denials (issue #503 follow-up), checked before the decline cooldown and before "record without asking" |

### Audio Processing

| File | Role |
|------|------|
| `AudioMixer.swift` | Resampling, mixing, echo suppression, WAV I/O |
| `AudioConstants.swift` | Shared audio pipeline constants (target sample rate) |
| `FFmpegHelper.swift` | ffmpeg CLI detection + 16 kHz mono WAV conversion fallback for file-import formats AVAsset can't decode |
| `FluidVAD.swift` | VAD preprocessing via FluidAudio Silero v6 — silence trimming + `VadSegmentMap` timeline remapping |
| `LiveAudioResampler.swift` | Streams live `LiveAudioBuffer` through `AVAudioConverter` → 16 kHz mono Float32 (feeds `StreamingTranscriber`) |
| `SampleRateDriftDetector.swift` | Watches actual vs declared CATap sample rate (catches USB hot-plug + HFP↔A2DP renegotiation drift) |
| `tools/audiotap/Sources/AppAudioCapture.swift` | CATapDescription + IOProc → FileHandle |
| `tools/audiotap/Sources/AppAudioCapture+PIDTranslation.swift` | Translates PIDs to CoreAudio `AudioObjectID`s (multi-process tap for Electron apps like Teams 2.x) |
| `tools/audiotap/Sources/AppAudioCapture+DebugLogging.swift` | Per-buffer dBFS/RMS logging helpers extracted from `AppAudioCapture` (line-cap split) |
| `tools/audiotap/Sources/AppAudioCapture+LiveSink.swift` | Live-buffer forwarding from CATap IOProc into `LiveAudioBuffer` sinks (line-cap split) |
| `tools/audiotap/Sources/AppAudioCapture+AggregateDescription.swift` | The CFDictionary describing the private aggregate device wrapping a process tap (line-cap split from `AppAudioCapture`) |
| `tools/audiotap/Sources/AppAudioCapture+Restart.swift` | Output-device-change restart path: off-main-queue, generation-tagged, deadline-bounded attempts (issue #588; line-cap split) |
| `tools/audiotap/Sources/AppTapSession.swift` | Owns one tap attempt's HAL resources (tap, aggregate device, IOProc) and their release ordering, injectable for testing without hardware |
| `tools/audiotap/Sources/MicCaptureHandler.swift` | AVAudioEngine → WAV |
| `tools/audiotap/Sources/MicCaptureHandler+Restart.swift` | Mic-side device-change restart path: off-main-queue, generation-tagged, deadline-bounded attempts (issue #588; same pattern as `AppAudioCapture+Restart`) |
| `tools/audiotap/Sources/MicCaptureHandler+DeviceSelection.swift` | Moves a running mic capture to another chosen device (`selectDevice(uid:)`) through the device-change restart path, charged to none of the progress watchdog's budgets (on a capture that stalled for lack of audio it is a revival, which `mayRevive` gates); a choice made while a restart runs is applied after it (the last one wins) and is what a retry aims at; `activeInputDevice` names the device the capture reports |
| `tools/audiotap/Sources/MicEngineSession.swift` | Everything mic capture that touches `AVAudioEngine`/CoreAudio, behind a protocol so `MicCaptureHandler` is testable without hardware; one session = one engine lifetime, discarded and rebuilt on restart |
| `tools/audiotap/Sources/MicChannelMap.swift` | Decides when a discrete multi-channel mic input needs an explicit converter `channelMap` — `AVAudioConverter`'s implicit downmix silently writes digital silence for most non-stereo layouts |
| `tools/audiotap/Sources/MicConverterFactory.swift` | Builds the tap → WAV converter for one mic capture, applying `MicChannelMap`'s explicit channel selection when needed |
| `tools/audiotap/Sources/AudioCaptureSession.swift` | Orchestrator (start/stop, computes micDelay) |
| `tools/audiotap/Sources/AudioCaptureConfiguration.swift` | What one capture records and how — the single list a new capture option is added to |
| `tools/audiotap/Sources/AudioCaptureResult.swift` | Result struct |
| `tools/audiotap/Sources/LiveAudioBuffer.swift` | Real-time audio sample snapshot yielded from capture callbacks (CATap IOProc + AVAudioEngine input tap) |
| `tools/audiotap/Sources/CurrentLevel.swift` | Pure function: dBFS level read with staleness decay (stale tap → silence) |
| `tools/audiotap/Sources/LevelPublisher.swift` | Cross-thread dBFS slot: audio callback writes, UI thread reads |
| `tools/audiotap/Sources/AppNoiseFloorSensor.swift` | Rolling 120 s share of app-tap samples in buffers below one 16-bit step; raises a flag at 90%, clears at 50% (issue #699). Warning only: feeds `ChannelFaultMonitor`'s `noiseFloor` fault, never the shared energy definition or the tap itself |
| `tools/audiotap/Sources/ChannelSignalAges.swift` | How long ago a channel last delivered a buffer, and last delivered one carrying signal — a single dBFS reading can't tell "dead", "muted", and "quiet room" apart, ages can (feeds `ChannelFaultMonitor`) |
| `tools/audiotap/Sources/DebugRMSReporter.swift` | Throttled RMS accumulator/reporter for audio debug logging |
| `tools/audiotap/Sources/Helpers.swift` | `machTicksToSeconds`, `getDefaultOutputDeviceUID`, `writeAllToFileHandle` |
| `tools/audiotap/Sources/MicRestartPolicy.swift` | Pure decision logic for mic engine restart on device change |
| `tools/audiotap/Sources/CaptureRestartRetryPolicy.swift` | Retry/backoff policy for a failed capture restart, shared by both the app-audio and mic channels (issue #379) |
| `tools/audiotap/Sources/RestartArbiter.swift` | Bounds how long a *single* restart attempt may run — generation-tagged so a wedged attempt that eventually returns is rejected rather than adopted, and forbids output-file creation forever once timed out (issue #588) |
| `tools/audiotap/Sources/OutputDeviceChangeCoordinator.swift` | State machine for output device change + tap restart flow |
| `tools/audiotap/Sources/ProcessTreeEnumerator.swift` | Enumerates all PIDs under an `.app` bundle (Electron/Teams child-process support) |
| `tools/audiotap/Sources/ProcessResponsibility.swift` | Groups a helper process with the app macOS holds *responsible* for it — needed for Safari, whose call audio comes from WebKit XPC services outside `Safari.app` rather than child processes under its bundle (issue #524); private symbol via `dlsym`, so it is `nil` under `APPSTORE` |
| `tools/audiotap/Sources/ChromiumHelperFilter.swift` | Keeps a Chromium/Electron app's audio service (`--utility-sub-type=audio.mojom.AudioService`) in the tap set and drops its other helpers; tapping the video-capture service alongside stalled the tap before its first IO cycle (issue #791). Leaves the set alone when no audio service is found |
| `tools/audiotap/Sources/ProcessArguments.swift` | Reads another process's argv via `KERN_PROCARGS2` (pure parser + live sysctl reader); empty when the kernel will not say, which every caller reads as "no opinion" |
| `tools/audiotap/Sources/SystemSettingsPaths.swift` | User-facing System Settings navigation paths (e.g. Screen Recording pane, renamed in macOS 15), kept in one place so the tap-error hint, permission UI, and channel-health notification name it identically |
| `tools/audiotap/Sources/SampleRateQuery.swift` | Pure functions for sample rate detection and cross-validation |
| `tools/audiotap/Sources/AVAudioNode+SafeInstallTap.swift` | Safe `installTapOnBus` wrapper catching `NSException` via `CExceptionCatcher` (issue #379) |
| `tools/audiotap/Sources/AppAudioCapture+Resampling.swift` | Capture-time resampling for CATap buffers (line-cap split from `AppAudioCapture`) |
| `tools/audiotap/Sources/AppAudioCapture+TapError.swift` | Tap-creation error mapping (line-cap split from `AppAudioCapture`) |
| `tools/audiotap/Sources/CExceptionCatcher/` | Obj-C module catching AVFoundation `NSException` from `installTapOnBus` |
| `tools/audiotap/Sources/DebugTapFault.swift` | Fault-injection config for mic device-change E2E to verify NSException recovery |
| `tools/audiotap/Sources/MicCaptureHandler+Timeline.swift` | Timeline tracking for `MicCaptureHandler` across device-change restarts |
| `tools/audiotap/Sources/StreamingMonoResampler.swift` | Streaming mono resampler for the live 16 kHz audio path |
| `tools/audiotap/Sources/TapFormatResolver.swift` | Derives mic tap format from hardware format (prevents installTap channel-count mismatch) |
| `tools/audiotap/Sources/TimelineAnchor.swift` | Wall-clock timeline anchor across device-change restarts (keeps track aligned to real time) |

### Support

| File | Role |
|------|------|
| `TranscriberStatus.swift` | Status + state enum models |
| `AppPaths.swift` | Centralized path constants (ipcDir, dataDir, logSubsystem, speakersDB) |
| `AXHelper.swift` | Shared accessibility API helper (used by ParticipantReader) |
| `NotificationManager.swift` | macOS notifications |
| `NotificationUrgency.swift` | How urgently a notification must reach the user — two cases (vs. the five `UNNotificationInterruptionLevel` offers) mapped to whether a given notification should pierce Focus |
| `NotificationScheduling.swift` | Port over the `UNUserNotificationCenter` slice `NotificationManager` uses, so posting/registration is testable against a fake scheduler |
| `NotificationRingBuffer.swift` | Bounded, thread-safe log of recently-posted notifications (`#if !APPSTORE`) |
| `NotificationManager+LocalModel.swift` | The local model's notices: "Meeting notes paused for your recording", "Meeting notes not written: low memory" (Try Again, Show Transcript) and "Meeting notes not written: no local model" (Open Settings), one notice per episode naming every meeting it covers (`#if !APPSTORE`) |
| `DateFormatter+FilenameStamp.swift` | `DateFormatter` pinned to Gregorian calendar + POSIX locale for filename timestamp stamps |
| `KeychainHelper.swift` | Legacy keychain CRUD (token now file-based) |
| `RecognitionStats.swift` | Recognition event model + `recognition_log.jsonl` reader/writer — backs `RecognitionStatsView` |
| `Permissions.swift` | Mic/accessibility permissions, project root detection |
| `PermissionRow.swift` | Permission status row UI component (icon, detail, help popover) |
| `PermissionHealthCheck.swift` | TCC verdict + live probe → `PermissionStatus`; drives exclamation badge overlay |
| `NotificationVisibility.swift` | What the notification centre will actually *do* with a posted notification (alert style, Time Sensitive, scheduled delivery) — authorisation alone can read `.authorized` while the prompt never shows |
| `ParticipantReader.swift` | Teams participant extraction via Accessibility API |
| `DebugRPCServer.swift` | Embedded HTTP RPC server core (routing, auth) for shell-driven inspection. `#if !APPSTORE`, opt-in via Settings → Advanced → Local Automation API or `MEETINGTRANSCRIBER_DEBUG_RPC=1`. Bearer-token + Origin reject; binds 127.0.0.1 only. Endpoint handlers split into companion files below (line-cap) |
| `DebugRPCServer+V1.swift` | `/v1` versioned automation API routing + response envelopes (`POST /v1/transcribe`, `/v1/jobs`, naming, `/v1/watch`, `/v1/record`) |
| `DebugRPCServer+Metrics.swift` | `GET /metrics` handler — cumulative CPU/RAM/instruction counters via `proc_pid_rusage` |
| `DebugRPCServer+Screenshot.swift` | `GET /screenshot` handler (PNG of the largest visible window via ScreenCaptureKit) |
| `DebugRPCServer+UITree.swift` | `GET /ui/tree` handler — read-only accessibility tree of an allowlisted window |
| `DebugRPCServer+UIPress.swift` | `POST /ui/press` handler — presses an allowlisted control via in-process `AXUIElementPerformAction`, or via `MouseInjection` when `"via":"click"` is requested |
| `DebugRPCServer+UIType.swift` | `POST /ui/type` handler — types into an allowlisted plain-text field via `KeyboardInjection` |
| `DebugRPCServer+AXElement.swift` | Shared self-pid `AXUIElement` tree walk backing `/ui/tree` and `/ui/press` |
| `KeyboardInjection.swift` | Types text into the app's own UI via posted key events (not an AX set-value, which wouldn't fire a SwiftUI `TextField` binding) — backs `POST /ui/type` |
| `MouseInjection.swift` | Clicks a point in the app's own UI via posted mouse events (real hit-testing, unlike some `kAXPressAction` controls that report success without effect) — backs `POST /ui/press` `"via":"click"` |
| `HTTPRequest.swift` | Minimal HTTP/1.1 request parsing for `DebugRPCServer` (pure value type, line-cap split) |
| `HTTPResponse.swift` | Minimal HTTP/1.1 response serialization for `DebugRPCServer` (pure value type, line-cap split) |
| `RPCResourceMetrics.swift` | JSON-serializable resource-usage snapshot of the running process, backs `GET /metrics` |
| `JobStatusDTO.swift` | Wire + persisted shape for `GET /v1/jobs/<id>` (live or terminal job status, result paths, and optional Notion page details) |
| `NamingStatusDTO.swift` | Wire shape for `GET /v1/jobs/<id>/naming` — per-speaker auto-name suggestion + speaking time + participants |
| `IdempotencyStore.swift` | Bounded FIFO map of `Idempotency-Key` → created job IDs for the `/v1` enqueue routes |
| `TerminalJobStore.swift` | File-backed store of recent finished-job statuses (survives queue reaping + app restart) |
| `MeetingFileRecord.swift` | One meeting's files and what has happened to them: paths, ownership, recording date, Keep mark, the build that created it, pending and incomplete deletions (see [Meeting Files and Deletion](#meeting-files-and-deletion)) |
| `MeetingFileStore.swift` | `meeting_files.json`: every meeting's record, lock-guarded writes shared with a second running build |
| `MeetingFilePresence.swift` | The one probe of a meeting's file: present, gone, or out of reach |
| `MeetingFileRemover.swift` | Moves a meeting's files to the Trash or deletes them for good, after the pending mark is on disk |
| `RecordingRetention.swift` | The retention setting's values and `RecordingRetentionRule`, which decides from the record alone whether a meeting's audio is due |
| `RecordingRetentionController.swift` | The automatic deletion check: when it runs, and what it asks the disk and the queue right before it deletes |
| `AppSettings+RPC.swift` | Builds the read-only settings projection for the debug RPC `/state` endpoint |
| `AppState+RPC.swift` | Builds `RPCStateSnapshot` from live `AppState` for the `/state` endpoint (`#if !APPSTORE`) |
| `RPCStateSnapshot.swift` | JSON-serializable RPC state snapshot type (`#if !APPSTORE`) |
| `Bundle+AppVersion.swift` | Bundle extension: `appVersion` + `gitCommitHash` from `Info.plist` |
| `DiagnosticExporter.swift` | Reads log entries and writes shareable `.log` file (Settings → Advanced → Export Diagnostics) |
| `PersistentDiagnosticLog.swift` | Persistent `log stream` subprocess with sliding-window restart policy for long-term log retention |
| `String+LogRedaction.swift` | String extensions: `.pseudonymized` (SHA-256 4-hex prefix) and `.redactedName` for log privacy |
| `FileManager+OwnerOnly.swift` | `FileManager` extension: owner-only file permission constant (`rw-------`) as single source of truth |
| `SingleFlight.swift` | Single-flight async deduplication coordinator (concurrent callers await one shared run and receive its outcome) |
| `RPCServerController.swift` | `@Observable` controller owning `DebugRPCServer` lifecycle (`#if !APPSTORE`, wired by `AppState`) |
| `PermissionsController.swift` | `@Observable` controller for permission health checks (wired by `AppState`, re-runs on activation) |

### Companion CLIs

| Path | Role |
|------|------|
| `tools/mt-cli/` | Thin Swift client for `DebugRPCServer`. Subcommands: `state`, `healthz`, `screenshot`, `open-settings`, `close-settings`, `confirm-browser-consent`, `wav-verdict`, `seed-speaker`, `rename-speaker`, `delete-speaker`, `merge-speakers`, `ui-tree`, `ui-press`, `watch`, `record`. Reads token from `~/Library/Application Support/MeetingTranscriber/.rpc-token`. Skill doc at `tools/mt-cli/skill.md`. |
| `tools/meeting-simulator/` | Test fixture: spawns a fake meeting window for E2E detection tests |
| `tools/local-llm-helper/` | The program the app starts to write one protocol with a local MLX model (`run`, `check <folder>`, `selftest`). Its own SwiftPM package, so the app's package never depends on MLX; bundled in the Homebrew build only. Process contract and exit statuses in its `README.md`; see [Local Model](#local-model) |

---

## State Machine

```
WatchLoop:     idle → watching → recording → watching (enqueues PipelineJob)
PipelineQueue: waiting → transcribing → [diarizing] → generatingProtocol → done (Notion export runs in the background; 60s auto-remove after any pending export)
                                                                            ↳ error
```

**Transitions** are observable via `WatchLoop.state` and `PipelineQueue.jobs`, triggering:
- Menu bar icon/label updates
- macOS notifications (recording started, protocol ready, error)

### Menu Bar Icon Animations

`BadgeKind.compute(watchLoopActive:watchLoopState:transcriberState:activeJobState:updateAvailable:permissionProblem:consentPending:)` is the pure function that maps the combined `WatchLoop` + pipeline state into one of `BadgeKind.inactive | .recording | .transcribing | .diarizing | .processing | .userAction | .done | .error | .updateAvailable`. `MenuBarIcon.image(badge:permissionOverlay:recordOnlyOverlay:)` then renders the matching animation frame.

| State | GIF | Triggered by | Code path |
|-------|-----|--------------|-----------|
| **Idle** | <img src="menu-bar-idle.gif" width="60"> | `WatchLoop.state == .idle / .watching` and `PipelineQueue` empty | `BadgeKind.inactive` |
| **Recording** | <img src="menu-bar-recording.gif" width="60"> | `WatchLoop.state == .recording` (waveform bars bounce) | `BadgeKind.recording` |
| **Transcribing** | <img src="menu-bar-transcribing.gif" width="60"> | `PipelineJob.state == .transcribing` or `TranscriberState.recordingDone` (bars morph into text glyphs) | `BadgeKind.transcribing` |
| **Diarizing** | <img src="menu-bar-diarizing.gif" width="60"> | `PipelineJob.state == .diarizing` (bars split into colored speaker groups) | `BadgeKind.diarizing` |
| **Protocol** | <img src="menu-bar-protocol.gif" width="60"> | `PipelineJob.state == .generatingProtocol` (lines appear sequentially) | `BadgeKind.processing` |

The icon is rendered as a SwiftUI `Image` template (auto-tinted by AppKit for light/dark mode) **unless** an overlay applies — overlays force non-template rendering to keep the colored badge intact.

While a "Record <App> meeting?" prompt waits for an answer, a **question mark** replaces the watching dot at the top right (`MenuBarIcon.image(..., questionOverlay:)`, driven by `AppState.awaitingUserAnswer`), so a detected meeting that is not being recorded yet shows on the icon even when the notification was missed. Like the dot it is drawn in the icon's own colour and keeps the template path, and it stays in the top half: the waveform state, the red tints and the bottom-right badges are drawn as without the prompt. Once the prompt is answered, expires or is declined, the dot is back. `BadgeKind` and the `badge` value do not change; automation clients read the open question from `pendingConsentApp`.

While a "meeting seems to have ended" countdown runs, the icon **pulses**: the whole icon, overlays included, is drawn at 30 % alpha on frames 3 to 5 of the 6-frame cycle and as usual on frames 0 to 2 (`MenuBarIcon.image(..., meetingEndCountdownOverlay:)`, driven by `AppState.meetingEndCountdownOverlay`, which is on exactly while `WatchLoop.meetingEndQuestionID` is set). It reads the loop's state alone, so the countdown shows whatever the notification permission, alert style or Focus, and it stops on every way out of the countdown. The fade is alpha only, so the icon stays a template wherever it was one. The countdown only runs while a detected meeting records, so `badge` stays `recording` and `BadgeKind` does not change. The pulse pauses while the menu is open, like every animation (`MenuBarIcon.animationRunLoopMode`).

### Permission problem badge

<p>
<img src="menu-bar-permission.gif" width="80" alt="Permission problem badge">
</p>

A red circle with a white "!" is composited in the bottom-right corner by `MenuBarIcon.drawExclamationBadge` whenever `PermissionHealthCheck` reports any of Microphone / Screen Recording / Accessibility as `.denied` or `.broken`. The overlay sits **on top of whatever primary state animation** is currently active — the user still sees what the app is doing while being told something is wrong. See "Permission health check + badge overlay" below for the full health-check semantics.

### Record-only mode badge

<p>
<img src="menu-bar-record-only.gif" width="80" alt="Record-only mode">
</p>

A persistent small red dot in the bottom-right corner indicates that **Record-only mode** is enabled (`AppSettings.recordOnly == true`). In this mode `WatchLoop.enqueueRecording()` moves dual-source WAVs into `<outputDir>/recordings/` together with a `<basename>_meta.json` `RecordingSidecar` and skips the entire post-processing pipeline (VAD, transcription, diarization, protocol). Intended for fleet topologies where macOS clients capture and a separate machine (e.g. a Linux GPU host via Syncthing) processes the audio. The sidecar's `trigger` field (`auto` | `manual`, schema version 2) tells that consumer which call site produced the recording, so it can treat a short auto-detected capture (likely a false trigger) differently from a short deliberate manual one.

Like the permission badge, the dot is rendered as a persistent overlay on top of whatever primary animation is currently active — so the mode is always clearly indicated whether the app is idle, recording, or running anything else. **Precedence:** when both apply, the red exclamation (permission badge) wins, because a permission problem actually breaks recording while record-only is a deliberate user choice.

### Per-channel asymmetric-silence indicator

When one capture channel goes silent while the other is still carrying audio for longer than the configured debounce window, the waveform bars in the menu bar are tinted **red** to surface the half-broken capture at a glance. `MenuBarIcon.image(..., micSilentOverlay:appSilentOverlay:)` paints the **top half** red when the mic channel is the silent one and the **bottom half** red when the app-audio channel is the silent one. When both apply, both halves are red (effectively all-red bars). Like the permission badge, this overlay forces non-template rendering so the red stays red in dark mode.

The flags driving this overlay (`AppState.micSilentActive` / `AppState.appSilentActive`) are flipped by a ~10 Hz polling task that reads `WatchLoop.activeRecorder?.{mic,app}LevelDBFS` and feeds the values into a pure `ChannelHealthMonitor` state machine. The monitor uses two dBFS thresholds — `silenceThresholdDBFS` (-60) and `speechThresholdDBFS` (-50) — with hysteresis: an episode only starts when one channel is below silence *and* the other is above speech, and only resolves when the supposedly-silent side crosses back above the speech threshold. Transient dips into the dead zone between the thresholds (natural pauses between syllables) keep the debounce timer running rather than resetting it.

**Settings → Audio → Per-Channel Indicator** turns the tint on or off (default on); the **Warn after** slider (30–300 s, default 90 s) sets the window. The toggle governs the tint alone: notifications are posted whether or not it is on, because a user who finds the red icon distracting is not asking to be left uninformed about a dead capture channel. The per-channel notification comes from `ChannelFaultMonitor`, which asks whether that channel has stopped delivering (no buffers, or buffers of digital zeroes) rather than whether it is quiet. On the app channel it also reports a floor below one 16-bit step (`AppNoiseFloorSensor`, issue #699): buffers that carry energy, so they never read as digital silence, but for two minutes at least 90% of them sit below 2^-15 RMS, which a tap of a silent meeting app never delivers. The symmetric `Recording Appears Silent` still comes from `SilentRecordingMonitor` and its dBFS thresholds, so it remains level-based and can fire on a call in which nobody is speaking; moving it onto the ages needs the gap between the two monitors closed first.

**Precedence ordering** (highest wins, composes over the others underneath):

1. Permission badge (red exclamation) — actually breaks recording
2. Channel-silent tint (red waveform halves) — degraded recording
3. Record-only dot (persistent red dot) — user-chosen mode
4. Primary state animation (idle / recording / transcribing / diarizing / protocol)

---

## Audio Pipeline

### Capture

```
AudioTapLib (CATapDescription)
├─ Input: App PID → CoreAudio process tap → aggregate device
├─ Output: Interleaved float32 (mono or stereo) → FileHandle (raw PCM)
├─ Mic: AVAudioEngine → mono WAV file (MicCaptureHandler)
└─ Metadata: micDelay, actualSampleRate, actualChannels via AudioCaptureResult
```

**Key:** CATapDescription is TCC-gated: it needs the "Audio Recording" grant (`NSAudioCaptureUsageDescription`) or, as a fallback, Screen Recording. With neither, the tap starts without an error and captures silence. Handles output device changes by recreating tap automatically.

**Start order (issue #693):** `AudioCaptureSession.start()` opens the microphone first and the app tap second, and the order is load-bearing. Opening the input takes a Bluetooth headset out of A2DP into its call profile; with the tap opened first, the disturbance landed underneath an aggregate device that had been created and started but had not yet run its first IO cycle, and the tap then delivered nothing for the rest of the recording (no IO callback, zero bytes, no error). Measured with a throwaway probe that is not in this repository: 9 failures in 30 starts with the tap first, 0 in 30 with the microphone first, which bounds what is left rather than proving it gone. **The full argument, including what the order does and does not guarantee and the three accepted costs, is the doc comment on `AudioCaptureSession.start()`; it is kept in one place on purpose.** Downstream, the measured `micDelay` is now normally negative (the microphone leads), which `MicDelayNormalisation` turns into a padded app track and a reported delay of 0; two cases it does not cover are a dual-source recording whose `_mic.wav` turns out unreadable, where the raw negative value is still what gets reported, and a crash-recovered recording, which `DualSourceRecorder.recoverCrashedRecording` rebuilds with a hard-coded `micDelay: 0` and therefore does not realign at all.

**Restart bounding (issue #588):** a device-change restart on either channel can wedge inside AVFAudio/CoreAudio and never return (e.g. `AVAudioEngine.inputNode` looping on a dangling Bluetooth sub-device held by coreaudiod). `RestartArbiter` bounds how long a single restart attempt may run — attempts carry a generation and run off the main queue, so a result from a wedged attempt that eventually returns is rejected rather than adopted. `CaptureRestartRetryPolicy` bounds how many attempts are made and is shared by both channels. A channel that gives up tells the user directly (`AudioCaptureSession`/`DualSourceRecorder` expose which one) instead of only decaying to silence, which the asymmetric-silence detector would otherwise misreport as a routing/mute problem rather than a channel that is gone for good.

**Safari support (issue #524):** the app-audio tap targets processes via macOS's *responsible-process* attribution (`ProcessResponsibility`) as well as bundle-path enumeration (`ProcessTreeEnumerator`) — Safari's call audio comes from WebKit XPC services outside `Safari.app`, unlike Electron/Chrome helpers that live inside their own bundle.

### Processing (DualSourceRecorder.stop())

```
App temp: already 16kHz mono float32 (resampled in-IOProc at capture time)
  → Save app.wav (16kHz mono)
  → Load mic.wav (already 16kHz from MicCaptureHandler)
  → Echo suppression (RMS-based gate, 20ms windows)
  → Delay alignment (prepend zeros by MIC_DELAY)
  → Mix (average tracks)
  → Save mix.wav (16kHz mono)
```

All recordings are normalized to 16kHz at capture time — no resampling needed in the pipeline.

### Echo Mitigation (issue #581)

The RMS-based echo suppression above is a capture-time gate; it does not catch a loudspeaker recording where the remote voices bleed into the microphone track after both tracks are already saved. Two independent, non-composing remedies run in the transcribe stage, decided per recording by `EchoRemedy`:

- **Detection first, always:** `EchoBleedDetector` (`PipelineQueue+EchoBleed.swift`) scores per-10s-window envelope correlation between the app and mic tracks, centred on the recorder's own `micDelay`, and reports `.notMeasured` / `.clean` / `.affected` as `PipelineJob.echo` (surfaced on `GET /v1/jobs/<id>`).
- **Cancellation (off by default):** `LocalVQECanceller`, over the vendored `CLocalVQE` static library, removes the far end from the microphone *audio* before transcription. `EchoCancellationSelfCheck` judges the run from the canceller's own per-window report before its output is adopted.
- **Transcript dedup (opt-in, off by default, and only on an `.affected` verdict):** `EchoSegmentClassifier` decides per mic segment whether the app track's energy explains it; explained segments are marked `suppressed` and left out of the transcript, so the far end isn't written twice. It ships off because a local speaker who only ever talks while the far end does is explained away and removed with them, which `EchoSegmentClassifierTests` pins as an expected failure.
- **Embedding quarantine:** on an `.affected` recording, `EchoEmbeddingQuarantine` holds mic-track speaker embeddings back from `speakers.json`, since a voice learned from contaminated audio would otherwise be folded permanently into a stored centroid.

Full design rationale (why the two remedies can't compose, the model provisioning, and the self-check semantics) lives in `docs/architecture/echo.md`.

---

## Transcription

### Engine Selection

`TranscribingEngine` protocol abstracts ASR backends. `AppSettings.transcriptionEngine` selects the active engine.

| | WhisperKit | Parakeet TDT v3 |
|---|---|---|
| **Languages** | 99+ | 25 European |
| **Model size** | ~800 MB–1.5 GB | ~50 MB |
| **Speed (M4 Pro)** | ~10–20× RTF | ~110× RTF |
| **Language selection** | Manual or auto-detect | Auto-detect only |
| **Timestamps** | Per-segment | Per-token |
| **macOS** | 14+ | 14+ |
| **Hallucinations** | Can occur | Minimal |

### WhisperKit Engine

- **Model:** `openai_whisper-large-v3-v20240930_turbo` (CoreML/ANE)
- **Pre-loading:** Model downloaded and loaded at app launch (when selected)
- **Lazy fallback:** `ensureModel()` loads on-demand if not ready

### Parakeet Engine

- **Model:** NVIDIA Parakeet TDT v3 via FluidAudio (CoreML/ANE)
- **Pre-loading:** Model downloaded and loaded at app launch (when selected)
- **Token grouping:** `groupTokensIntoSegments` groups per-token timings into sentence-level segments (split on `. ! ?` or 20 tokens)

### Modes

1. **Single source:** `transcribeSegments(audioPath:)` → `[TimestampedSegment]` with start/end/text
2. **Dual source:** `transcribeSegments(appAudio:)` + `transcribeSegments(micAudio:)` → `mergeDualSourceSegments(appSegments:micSegments:)` → `[TimestampedSegment]` merged by timestamp
   - App segments labeled "Remote"
   - Mic segments labeled with user's mic name (default "Me")
   - `mergeDualSourceSegments` is a protocol extension on `TranscribingEngine` — shared by all engines

### Post-processing (WhisperKit only)

- **Token stripping:** Regex `<\|[^|]*\|>` removes `<|startoftranscript|>`, `<|en|>`, etc.
- **Hallucination filtering:** Skip consecutive identical segments

### Custom Vocabulary & Terminology Normalization

- **Custom vocabulary** is one shared one-term-per-line file (`AppSettings.customVocabularyPath`, resolved through `VocabularyFileAccess` for sandbox bookmark access), not per engine. `AppSettings.customVocabularyEnabled` switches it on or off for both engines. Parakeet applies it via CTC boosting. WhisperKit applies it via `WhisperVocabularyPrompt` turning the file into a bounded decoder-prompt hint — WhisperKit shares its 224-token decoder context between that prompt and generated tokens, so a dense recording can lose whole sentences to it; Parakeet is the recommended engine for vocabulary boosting.
- **Vocabulary source:** one at a time, chosen in Settings → Transcribe → Vocabulary while "Use custom vocabulary" is on (`AppSettings.vocabularySource`): the local file above (the default), or a URL (`remoteVocabularyURL`, for example a file in a GitHub or GitLab repository, with an optional access token kept only in the Keychain and sent as `Authorization: Bearer`). `RemoteVocabularyController` keeps a cached copy of the URL source current with conditional requests (`RemoteVocabularyFetcher`, `RemoteVocabularyCache`). The engines read `AppSettings.effectiveVocabularyPath`, which for the URL source is the copy kept for the configured address: nothing is merged with the local file and nothing falls back to it, a failed check keeps the last good copy (also across a restart), and with no copy yet the engines run without vocabulary. The switch turns the URL source off as well: no engine reads the copy and the controller makes no requests while it is off. Settings shows the copy's term count, when it last changed and when the server was last reached, or why the last check failed.
- **Terminology normalization** (`TerminologyNormalizer`) is a separate, engine-independent post-ASR pass, applied to transcript segments right after transcription: opt-in `Canonical => spoken variant | another variant` rules, configured in Settings → Transcription → Vocabulary → Canonical terminology, either in the text area or in an optional rules file that is read again at the start of every job (details in `docs/architecture/transcription.md`).

---

## Live Captions (PoC)

Optional in-meeting caption overlay, "Enable live transcription during recording" in Settings →
Transcription (`AppSettings.liveTranscriptionEnabled`, off by default; enabling downloads a ~0.6 GB
model on first use behind a consent alert). Nested "Show caption overlay"
(`AppSettings.liveCaptionsOverlayEnabled`, default on) hides `LiveCaptionsOverlay` without
stopping the pipeline; `LiveCaptionsState` and `/state.liveCaptions` keep updating.

`LiveCaptionsGate.strategy(liveEnabled:engineLanguage:engineSupportsLive:)` is the pure decision
function — shared by `AppState`, `LiveTranscriptionCoordinator`, and `LiveTranscriptionController`
— that picks the per-channel backend from the active engine's **explicitly configured** language
(not auto-detect):

| Engine language | Strategy | Backend |
|---|---|---|
| `en` | English streaming | `EouStreamingCaptionSession` (FluidAudio Parakeet EOU) |
| a language Nemotron was trained on (`LiveCaptionLanguages`) | Nemotron streaming | `NemotronStreamingCaptionSession` / `NemotronAsrManager` (FluidAudio Nemotron multilingual) |
| auto-detect (`nil`) or any other language | re-transcribe | `StreamingTranscriber` via the active engine's `transcribeSamples`, if supported |
| auto-detect or any other language + engine doesn't support live re-transcribe | none | captions off |

Both streaming sessions are engine-independent (they drive their own FluidAudio models directly),
so they're available even when the active `TranscribingEngine` has no live re-transcribe hook.
`LiveTranscriptionController` wires the resolved per-channel pipeline to both `DualSourceRecorder`
sinks (mic + app) and feeds `LiveCaptionsState`, which backs the `LiveCaptionsOverlay` window.
`ModelWarmupQueue` serializes model warm-up loads (ASR engine + streaming models) so they don't
compile/load concurrently at launch.

---

## Diarization

### FluidDiarizer (On-device)

On-device speaker diarization using FluidAudio (CoreML/ANE). No HuggingFace token or Python subprocess needed. Models downloaded automatically on first run (~50 MB); Nemotron 3 mode downloads its own ~200 MB model the first time it is used.

Three modes selected via `AppSettings.diarizerMode`:
- **`.offline`** (default) — `OfflineDiarizerManager`, standard speaker segmentation
- **`.sortformer`** — `SortformerDiarizer`, overlap-aware diarization (handles simultaneous speech); speaker embeddings extracted post-hoc via `FluidDiarizer+SortformerEmbeddings` using overlap-excluded WeSpeaker masks
- **`.nemotron`** — `Nemotron3Diarizer`, NVIDIA's Nemotron 3 Diarization (an 8-speaker streaming Sortformer), overlap-aware for up to eight speakers; the `fast128` preset (~200 MB, downloaded on first use). The recording is streamed through the model in 60 s pieces, so the mel spectrogram of the whole file is never held; embeddings come from the same post-hoc WeSpeaker extraction as `.sortformer`. Like `.sortformer`, it ignores `numSpeakers`

Flow: `FluidDiarizer.run(audioPath, numSpeakers)` → selected diarizer → `DiarizationResult` with segments, speaking times, and speaker embeddings.

**Experimental tuning:** Five `OfflineDiarizerConfig` parameters are exposed in `AppSettings` and editable in Settings → Speakers → Experimental: Diarization Tuning: `clusterThreshold` (0.6), `warmStartFa` (0.07), `warmStartFb` (0.8), `minSegmentDurationSeconds` (1.0), `excludeOverlap` (true). All default to FluidAudio community values.

### Speaker Matching

`SpeakerMatcher` matches diarization speaker embeddings against a persistent speaker database (`speakers.json`) using cosine similarity (threshold: 0.40, confidence margin: 0.10). Stores a running-mean centroid (primary match anchor) plus a recent-samples FIFO (max 3, fallback when centroid match is borderline). Quality filter: embeddings from segments shorter than 3 s are excluded from the centroid but kept as fallback samples. Speakers are ranked by recency and use count in the naming UI. Enables recognition of returning speakers across meetings.

### Speaker Assignment

For each transcript segment, find the diarization segment with the longest temporal overlap:
```
overlap = max(0, min(seg.end, dSeg.end) - max(seg.start, dSeg.start))
```
No overlap → nearest-segment fallback by gap distance. Only if no diarization segments exist → "UNKNOWN".

### Dual-Track Diarization

When dual-source recording (app + mic) is available:
1. Transcribe app/mic tracks separately → "Remote" / micLabel segments
2. Diarize app track and mic track separately via FluidAudio
3. `mergeDualTrackDiarization()` — prefix speaker IDs (`R_` for remote, `M_` for local), merge segments by time
4. `preMatchParticipants()` — heuristic assignment of Teams participants to unmatched speakers by speaking time
5. Speaker naming UI — all speakers editable with participant suggestions
6. `assignSpeakersDualTrack()` — app segments matched against app diarization, mic segments against mic diarization

**Single-source fallback:** When only mix audio is available, diarize the mix and use `assignSpeakers()` with nearest-segment fallback.

### Speaker Naming UI

`SpeakerNamingView` shown when diarization finds speakers: by itself while "Open naming window automatically" (`AppSettings.autoOpenSpeakerNaming`) is on, otherwise when the user opens it from "Name Speakers…" in the menu bar. Each row shows label, auto-matched name, speaking time, and audio playback. All rows are editable. Supports re-run with different speaker count.

---

## Protocol Generation

### Provider Selection

`AppSettings.protocolProvider` selects the active provider:
- **`.claudeCLI`** — Claude CLI subprocess (`#if !APPSTORE`)
- **`.codexCLI`** — Codex CLI subprocess with the user's Codex login, model and reasoning effort (`#if !APPSTORE`)
- **`.customCommand`** — A command the user enters, one argument per line, with the placeholders `{model}`, `{prompt_file}` (instructions and transcript), `{transcript_file}` and `{output_file}`; without an input-file placeholder the prompt goes to stdin, without `{output_file}` the protocol is read from stdout (`#if !APPSTORE`)
- **`.openAICompatible`** — Any OpenAI-compatible HTTP API (Ollama, LM Studio, llama.cpp, etc.)
- **`.localModel`** — A local MLX model folder the user picked, run by the bundled helper `local-llm-helper` in a process of its own per protocol; see [Local Model](#local-model) (`#if !APPSTORE`)
- **`.none`** — Skip LLM generation; save transcript only

`AppSettings.includeFullTranscriptInProtocol` and
`AppSettings.saveRawTranscriptSeparately` default to `true` to preserve the
legacy output. Their values are captured when a job enters the queue, so a
later settings change affects only subsequent recordings. The raw `.txt` and
verbatim segment sidecar are deleted only after a job completes successfully
with a saved protocol. If protocol generation is disabled, fails, or the job
ends in an error, the raw transcript is retained with a warning. Neither setting
deletes a recording's audio; only the rules in
[Meeting Files and Deletion](#meeting-files-and-deletion) do.

The prompt is the job's protocol template: the built-in one ("Standard (built-in)") or a Markdown file in `~/Library/Application Support/MeetingTranscriber/Protocol Templates/`, named after the file and managed in Settings → Output. A job captures the template's name when it enters the queue, and the file is read when the protocol is made. A job that names no template gets the template of the first rule in `AppSettings.protocolTemplateRules` whose pattern matches its title, else `AppSettings.defaultProtocolTemplate`; a template picked by hand in the start dialog or the Record Meeting window always wins (`PipelineQueue.stampTranscriptOutputOptions`, the same for imports and recovered recordings). A pattern is a regular expression matched ignoring case anywhere in the title; Settings saves only patterns that compile. A rule whose template file is missing is skipped, and so is one that runs longer than 0.05 s on a title, with 0.25 s for all rules of one title, so a runaway pattern can delay a job by a quarter second at most. The match uses the job's title: the cleaned window title of a detected meeting (the app's name plus "Call" without the Screen Recording grant), the typed title or app name of a manual recording, "Microphone Recording", an imported file's name, a paired import's sidecar title, or "Recovered Recording (<stem>)". The start dialog and the Record Meeting window preselect what the rules pick and say why in a line under Template, until the user changes the template there; the regenerate sheet does not follow the rules. Titles and patterns are logged only as private values. With no rules, every path behaves as before. A template that is missing or blank when the protocol is made falls back to the built-in with a warning on the job. A custom prompt from an earlier version (`protocol_prompt.md`) is copied in once as the template "Custom Prompt" and made the default; the old file is left in place.

`AppSettings.useAITitleForFilenames` (off by default, captured per job the same
way) names a job's files after the meeting title in the generated protocol's
heading instead of the timestamped slug: `sprint_planning.md`,
`sprint_planning.txt`, `sprint_planning_mix.wav` and so on. It can only act once
a protocol exists, so with the `.none` provider, a failed generation, or a
heading that is a placeholder, bracketed or has no alphanumerics, the
timestamped names stay. The rename moves every artifact of the job in both
`protocols/` and `recordings/`, found from the closed suffix lists rather than a
prefix scan, because a bare-title stem is a prefix of other jobs' stems. A title
is taken only if none of its artifacts exist, otherwise `_<shortID>` is
appended, and nothing is overwritten. If any move fails, the ones already done
are undone and the job keeps its old stem and paths. The meeting's additional
reports (see [Additional Reports](#additional-reports)) are the one exception
to the suffix lists: the ownership rule finds them by their whole name before
` (`, they move in the same all-or-nothing run, and a title is taken when it
has a report or when a moved report would not land on a free name: another
meeting would own it (`weekly_sync (Short).txt` makes `weekly_sync (Short).md`
that meeting's notes), or a file differing only in case is there. A `protocols/` folder that cannot be listed renames nothing.
The title comes from the first top-level `# ` heading in what the model
wrote, and only for a job that ran the built-in template (after a fallback
too): a custom template's first heading is whatever it writes, a section such
as "Action items" as often as a title, so its files keep the timestamped
names (`ProtocolGenerator.fileTitleSlug`, over `ProtocolGenerator.aiTitle`).

### Additional Reports

Regenerate Notes… on a meeting that already has notes offers "Save as:" with
"An additional report" preselected: the new notes go to
`<basename> (<template name>).md` beside the meeting and the current notes stay
(the built-in template's report is `(Standard)`). "Replace the current notes"
works as before. A second report from the same template replaces the first,
whose file goes to the Trash; when the Trash refuses, the new report stays and
the old one stays beside it as `<name>.previous-<stamp>.md` with a warning.

One rule decides whose report a file is (`AdditionalReport`,
`MeetingReportFolder`), and the sheet's count, its orange lines, the row menu,
"Regenerate from File…", Move Meeting to Trash and the AI-title rename all use
it: a file with a `.txt` of its own name is a meeting, otherwise the longest
name before a ` (` that has a transcript (its `.txt`, or the transcript inside
its notes) owns it. Where it refuses or keeps a file, the rule compares names
without regard to case, as the default macOS volume does, where `Budget (Q3).md`
reaches the file `Budget (q3).md`: a `.txt` or a longer meeting in any case
claims the file, and a case variant of the chosen report's name is the file it
replaces. A meeting lists, moves and deletes only reports under its exact name,
because on a case-sensitive volume `Budget` and `budget` are two meetings. For a file
chosen with "Regenerate from File…", the folder's listing tells whether its own
`.txt` is there, so a transcript that cannot be read still makes it a meeting.
A report name the rule gives to another meeting disables Generate. The run
checks the name again right before the write, and a report that appeared,
changed or vanished meanwhile stops it like any changed file. The sheet stays
open after a run and reads the meeting again, so its choice, count and small
lines follow what the run wrote.

Nothing lists a report while its meeting lives, so a report renamed or deleted
in Finder drops out of the row menu. A report run never tells the job its
template and never lists its file as the meeting's notes, so Open Notes, the
automation API, a retried Notion export and the "right after the notes"
retention keep using the main notes (`ProtocolRegenerator.regenerate`).

`AppSettings.protocolLanguage` (default `"German"`) is substituted into the prompt as `{LANGUAGE}`. Every template can also use `{MEETING_DATE}` (`YYYY-MM-DD`) and `{MEETING_TIME}` (`HH:mm`), derived from the captured recording start time. Imports and recovery jobs resolve those time placeholders to `Unknown` rather than their enqueue or processing time. Only recordings with a captured start receive the authoritative meeting-metadata block, so templates receive reliable temporal context without needing to add the placeholders.

### CLI Runner

The Codex CLI and custom command providers share one runner, `CLIProcessRunner`, which the local model's Check Model in Settings also uses. Every run works in a fresh owner-only folder under the per-user temporary directory, removed when the run ends; the runner starts the program there directly from an argument vector, never through a shell, stops it after 10 minutes of wall-clock time even when it prints nothing (SIGTERM, then SIGKILL one second later), and caps stdout at 32 MiB. The Codex preset runs `codex exec --json --ephemeral --skip-git-repo-check --sandbox read-only --output-last-message {output_file} -` with the prompt on stdin; `--ephemeral` keeps the run out of Codex's session store.

The Claude CLI provider runs on `BoundedProcess` instead (see [Claude CLI Invocation](#claude-cli-invocation)), also with a 10-minute limit, in an owner-only working folder of its own per run, and stopped through the process group it leads (SIGTERM, then SIGKILL one second later).

### Local Model

`LocalModelProtocolGenerator` sends the prompt every provider sends (the system prompt, the transcript as the user prompt) to `tools/local-llm-helper`, a program the app starts for that one protocol and that exits afterwards. The model's memory (about 17 GB at peak for the tested 27B 4-bit model) and any crash therefore stay out of the app's process. The helper is its own SwiftPM package, so the app's package, its tests and the App Store build never compile MLX. The two share no code; the contract is the process boundary in the helper's `README.md`: the request as one JSON object on stdin, the private run directory as working directory, the protocol appended to `protocol.md` there as it is generated, progress and lifecycle lines on stderr, and a fixed table of exit statuses.

- **One door.** Every local protocol (queued jobs, every speaker-naming path, a regeneration, Try Again) goes through the single `LocalModelGate` that `PipelineController` owns. It runs one helper at a time, in arrival order, from the memory check until the helper's exit is confirmed.
- **Memory guard.** A helper starts only at normal memory pressure with free plus inactive memory of at least the weights' size plus 6 GB, and is ended at warning pressure or below 4 GB, checked every second while it runs (`LocalModelMemoryGuard`). A refusal or a stop becomes "Meeting notes not written: low memory" with Try Again.
- **Recordings first.** `WatchingController` pushes one recording-activity signal to the gate. When it turns on, a running helper gets SIGTERM and SIGKILL 3 s later if it is still there, and no helper starts until the signal turns off; the queue then generates the deferred protocols again by itself. A regeneration is not resumed.
- **Fixed limits** (`LocalModelLimits`, not settings): a 32,768-token context, 16,000 output tokens, 20 minutes in total and 3 minutes without a progress line. A prompt that does not fit is refused before any weights load; a protocol stopped at the output limit is kept with a warning.
- **Quit.** The app ends a running helper when it quits (SIGTERM, then SIGKILL after 1 s), and a run directory left by a crash is removed at the next launch.
- **Logs.** Every local-model log line is content-free (ids, counts, fixed words and memory figures), under the `LocalModel` category.

**Packaging.** `scripts/lib/local-llm-helper.sh` is the single place that builds the helper (release build only: a debug build computes wrong numbers on a 4-bit model) and installs it into a bundle; `build_release.sh` and `run_app.sh` both go through it and stop when Xcode's Metal Toolchain is missing, since a bundle without the helper would offer a provider that never works. The helper goes to `Contents/Helpers/local-llm-helper`, with every SwiftPM resource bundle the build put beside it (MLX's shaders `mlx-swift_Cmlx.bundle`, the Hub tokenizer fallbacks, ...). It cannot go into `Contents/MacOS`: MLX looks for its shaders beside `NSBundle.mainBundle`, which for an executable there is the app, not the helper's directory. `scripts/lib/signing.sh` signs the resource bundles and then the helper, with the Hardened Runtime, before the outer bundle (notarized build and `run_app.sh`; the unnotarized `--deep` branch of `build_release.sh` re-signs them without it); `scripts/lib/bundle-licenses.sh` installs the licence texts of the helper's dependencies from its resolved checkouts. The App Store build neither builds nor contains the helper. `scripts/local-llm-bundle-check.sh` proves a built bundle by running the helper's `selftest` from inside it and checking the signatures; it needs a GPU and is run by hand, not by CI. `scripts/pre-push.sh` builds the helper when the Metal Toolchain is installed and skips it with one line otherwise.

**Real-model test.** `LocalModelRealModelTests` runs the app's generator, gate and memory guard against real weights when `LOCAL_LLM_HELPER_TEST_MODEL` names a model folder, and skips without it, so CI never loads a model. It needs the helper's release build (`cd tools/local-llm-helper && swift build -c release`) and runs the helper with networking denied by `sandbox-exec`. A refusal by the memory guard skips the test with the readings rather than failing it. The second test starts a recording through the automation API's `POST /v1/record` and checks that the helper is gone within 5 seconds.

### Notion Export

When `AppSettings.notionExportEnabled` is on, `PipelineQueue` saves the generated
protocol locally first, moves the job to `done`, then exports the Markdown to the
selected Notion database in the background, so a slow Notion cannot hold up the next
job and a quit costs no second LLM call. The local copy is kept by default;
`notionSkipLocalMarkdownOnSuccess` removes it only after a successful export or
retry. Export failures add a job warning with a short cause and keep the local copy.
`notionSpeakerTagsEnabled` separately opts in to sending confirmed speaker names as
tags and defaults off. Date and Tags are written only when the selected database
has recognized columns. The page title follows the file-name rule
(`ProtocolGenerator.aiTitle`): the title the model wrote for notes from the
built-in template, otherwise the job's title. A retry reads the notes from the
backup and decides by the template the job asked for, or by the one a later
"Regenerate Notes" rewrote them from.

The job records its Notion page and database IDs as soon as the page is created,
so retries and protocol re-exports can use the same destination. Re-export after
speaker renaming replaces the page's root content with the current protocol. New
content is appended before prior root blocks are archived: a failed append keeps
the previous content, and a retry reconciles any partial new content. A successful
re-export replaces manual edits to the app-owned page, except blocks of a type
that never holds protocol text (`NotionReplacePlan.keptTypes`: sub-pages,
databases, media, embeds, links), which stay, above the new content. A delete
that answers 404, or 400 for an archived block, counts as done once a fresh
listing no longer shows the block; Notion answers 404 for lost access as well.
The client pins Notion API version `2022-06-28`; databases with multiple data
sources are rejected rather than guessing which source should receive the meeting.

A failed export retains the completed job and its local Markdown backup across
queue cleanup and app restarts, even if the original audio is no longer present.
The menu's **Retry Notion Export** action is available when export is enabled and
the backup file exists; it reads the saved protocol and reuses the recorded page
ID for the same database, plus saved speaker names when tags are enabled. It does
not transcribe audio or generate a new protocol. In the menu the job is a line
under "Needs you" (under "In progress" while an export runs), and **Discard
Notion Retry** takes it off. Success clears the export-failure
warning and starts the normal 60-second completed-job lifetime. If a completed
job's in-progress export is interrupted, recovery marks it failed with an
"interrupted when the app quit" warning for this same retry path; see
`pipeline.md` for when these jobs come back at launch. If the app stops during protocol generation for a pending export,
recovery regenerates from the saved corrected transcript when the saved
transcript and naming state permit protocol-only recovery, even if an older
Markdown file exists.

When a Notion target is routed and the Notion desktop app is running, the app
receives the page handoff. Otherwise, the original Notion URL is opened with
the system's default handler. If the desktop app rejects the handoff, the
original URL is also opened with the default handler. Local protocol files
always use the default handler.

### Claude CLI Invocation

```bash
/usr/bin/env claude -p - --output-format stream-json --verbose --model sonnet
```

- **Input:** Meeting metadata + protocol prompt (with variables substituted) + transcript piped to stdin
- **Output:** Stream-json parsed line-by-line (content_block_delta + assistant message)
- **Environment:** `CLAUDECODE` env var stripped to allow nested invocation
- **Timeout:** 10 minutes

### Output Structure

```markdown
# Meeting Protocol - [Title]
## Summary
## Participants
## Topics Discussed
## Decisions
## Tasks (table)
## Open Questions

---

## Full Transcript
[appended when enabled]
```

### Meeting Files and Deletion

Each meeting that enters processing gets a `MeetingFileRecord`, kept by
`MeetingFileStore` in `meeting_files.json` beside `terminal_jobs.json` and keyed
by the job id. The record lists every file of the meeting with its current path
and whether the app owns it, plus the recording date, the Keep mark, the state
of any deletion and the bundle identifier of the build that created it. It follows each file as the pipeline writes, moves,
replaces or removes it, and it outlives the 1000-entry finished-job list. A
deletion only touches a path the record lists, never one derived from a file
name or a folder. An imported source file is never owned, also inside the
recordings folder, and a meeting finished before this feature has no record and
gets none. A file counts as gone only when its folder reads and the file system
says the file does not exist (`MeetingFilePresence`). A missing volume or an
access error makes it unreachable, and an unreachable file stays listed.

**By hand, one meeting.** In the All Recordings window, a finished meeting's
row menu offers Keep (Never Delete Automatically), Move Audio to Trash… and
Move Meeting to Trash… (`RecordingRowActions`). They are absent for a failed
meeting and for a row without a record. They are disabled while the meeting
waits, runs, waits for speaker names, has a Notion export running or a deletion
pending. When it runs, each action asks the queue again with the check's own
question (`liveMeetingState`), so a re-export chained behind another holds it
also between the two exports, and so do saved jobs that did not read. Move
Meeting is also disabled while Regenerate Notes runs: the regenerator writes
notes that a removed record would no longer list. Keep
switches at once. Each Trash action asks first, and the dialog names what goes:
what the record lists, less what the disk answered gone
(`TrashConfirmationText`). If a file came back while the dialog was open, or
the other running build listed one in the shared record meanwhile, so the action
would move a file the dialog did not name, nothing moves and the window says so.
The window reads the record file again before it checks, and the action itself,
handed the named paths, checks once more against the record it reads and refuses
an unnamed file that is not gone. A file the Trash refuses leaves the
meeting as "Deletion incomplete" with Retry Deletion. Move Meeting to Trash
takes the row off the list at once. The record holds the pending mark, so it
goes last, after the queue and the finished-job list no longer hold the
meeting; after a failed write or a crash it stays until the next launch
finishes the removal. From then on `GET /v1/jobs/<id>` answers `404`.

**Additional reports in a deletion.** Move Meeting to Trash also moves the
meeting's additional reports, found by the ownership rule in each folder of
its transcript and notes (`MeetingReportScan`), and the confirmation counts and
names them. The dialog, the window's check, the action and each Retry Deletion
read them again, and a report the dialog did not name stops the action like
any unnamed file. They enter the record in the same save as the pending mark,
under the existing role `previous_protocol` (the release and the development
build share the record file, and a build that cannot decode a role moves the
file aside as corrupt), so a crash or a retry carries them. A report the record
lists keeps the identity it was listed with: one replaced since, or a different
file at the name of one an earlier run already moved, is refused as replaced.
A folder that cannot be read, or that now resolves elsewhere, moves nothing and leaves
"Deletion incomplete" with Retry Deletion; a meeting another record shares
keeps its reports; Move Audio and the automatic deletion leave them.

**By hand, several meetings.** Rows can be selected with Shift and Command.
The right-click menu over a selection offers only the two Trash items.
`TrashSelectionPlan` takes each selected meeting by its own row's rules above,
so a selection never offers what the action would refuse, and an item is
disabled when it applies to none. One confirmation names the kept meetings and
says how many selected meetings are left out and that imported files stay. If
any of the meetings would move a file the dialog did not count, because it came
back or another build listed it while the dialog was open, nothing moves; a
file that went missing is no reason to stop. Each meeting is checked again
right before its own move, so a
file that comes back while the earlier meetings move stops the batch before that
meeting, and the window says after how many it stopped. A meeting that fails
stays as "Deletion incomplete", and the meetings acted on leave the selection.
Only rows the search shows count as selected. The footer counts those rows (or
says "N of M selected"), adds the audio on disk of the ones with a record, and
says what the retention setting deletes.

**Automatically.** Settings → Output → Recordings, "Delete recordings
automatically": Never (the default), Right after the notes, After 7 days, After
30 days or After 90 days. `RecordingRetentionRule` selects, from the record
alone, the audio of meetings this build recorded, whose outcome is finished (notes
saved, or with notes generation off a transcript the record lists as present;
speakers named), that
are not marked Keep and whose recording date plus the chosen days has passed. `RecordingRetentionController` deletes that audio
for good, not to the Trash; the transcript, the notes and all other files stay.
It never touches imports, failed meetings, kept meetings, meetings without a
record, recordings from before this feature or meetings another build recorded.
A row the setting never reaches shows only its audio size. It skips a meeting whose state
changed since the check began or whose Notion export is running. Right before it
deletes, it asks the disk and the queue again, and it keeps the audio in cases
the rule cannot see: a folder, a link or an unreadable file at the notes path,
notes switched off with the transcript removed by hand, or saved jobs it cannot
read (the meeting then counts as not through). A file out of reach or one that
refuses to go stays listed and is tried again at the next check. The check runs
at launch, once a day, when a meeting finishes, when a Notion export ends, when
the pipeline builds or rebuilds its queue (the first time it is needed and each
time watching starts) and 5 seconds after a confirmed setting change, and never
two at once.

Choosing a value that would delete audio now first shows what it deletes
(`RetentionPreview`). Cancel is that alert's default button, so Return cancels.
A confirmed value is saved and starts a check 5 seconds later; the check reads
the setting when it runs, so going back to Never in between keeps the audio.
When nothing would be deleted, and for Never or a longer time, the value is
saved without asking. When what the value deletes cannot be told, because the
records or the queue's saved jobs do not read, the value is not saved.

The development and the release build share the data folder. Every write to
`meeting_files.json` takes a lock and changes only its one record, and a
deletion found pending is left alone while the process that started it still
runs. Each build keeps its own retention setting, so a build's setting reaches
only the records it created: the record names that build's bundle identifier
(`createdBy`, written once), and the rule, the row's audio line, the preview and
the store's last look before each file all take the running build's identifier
(`MeetingFileStore.bundleID`). A record without the field is never deleted
automatically. A build that does not know a field of the record drops it from
every record when it saves the file, so a field the automatic deletion depends
on has to keep the audio when it is missing, as `createdBy` does. The record
file and `createdBy` arrive in the same change, so no build that writes the file
deletes automatically without asking the field. The manual actions act on any
meeting the window lists.

---

## Data Flow

### Observable State Propagation

```
AppSettings (UserDefaults)
  → WatchLoop (@Observable: state, detail, currentMeeting, lastError)
  → PipelineQueue (@Observable: jobs, isProcessing, pendingSpeakerNaming)
    → AppState (computed: currentBadge via BadgeKind.compute(), currentStatus, currentStateLabel)
      → MeetingTranscriberApp (reads appState.*, passes to views)
        → MenuBarView (receives status + callbacks + pipeline queue)
        → SettingsView (receives @Bindable settings)
        → SpeakerNamingView (receives pendingSpeakerNaming data)
```

### File Locations

| Content | Path |
|---------|------|
| Recordings | `~/Library/Application Support/MeetingTranscriber/recordings/` |
| Protocols | `~/Downloads/MeetingTranscriber/` by default, or the folder chosen in Settings → Output |
| IPC | `~/Library/Application Support/MeetingTranscriber/ipc/` (`~/.meeting-transcriber/` is only read once, as a migration source) |
| Speaker DB | `~/Library/Application Support/MeetingTranscriber/speakers.json` |
| WhisperKit models | `~/Library/Application Support/MeetingTranscriber/huggingface/` |
| Pipeline logs | `~/Library/Application Support/MeetingTranscriber/ipc/pipeline_queue.json`, `pipeline_log.jsonl` |
| Meeting file records | `~/Library/Application Support/MeetingTranscriber/ipc/meeting_files.json`, beside `terminal_jobs.json` |
| AudioTapLib | Linked as SPM library (no separate binary) |

---

## Testing Hooks

| Component | Injection Point |
|-----------|----------------|
| MeetingDetector | `windowListProvider` closure (mock window list) |
| PowerAssertionDetector | `assertionProvider` + `windowListProvider` closures |
| MicInputDetector | `processProvider` + `windowListProvider` closures |
| DiarizationProvider | `diarizationFactory` closure in PipelineQueue |
| ProtocolGenerating | `protocolGenerator` protocol in PipelineQueue |
| RecordingProvider | `recorderFactory` closure in WatchLoop |
| ProtocolGenerator | `claudeBin` parameter |
| LocalModelProtocolGenerator | `locateHelper` closure (a stub helper script in tests); `LocalModelGate.Configuration` injects the memory probe, the limits, the run-directory parent and the diagnostics sink |
| NotificationManager | `NotificationScheduling` port over `UNUserNotificationCenter` (fake scheduler in tests) |
| ConsentPromptCoordinator | Injected timeout clock; pure register/resolve-once API (no UI dependency) |
| LiveCaptionsGate.strategy | Pure static function — call directly with any input combination, no controller needed |
| AppNotifying | `notifier` parameter in `AppState.init` (`SilentNotifier` default, `RecordingNotifier` in tests) |
| BadgeKind.compute | Pure static function — call directly with any input combination, no WatchLoop needed |
| DebugRPCServer | Out-of-process inspection via HTTP. Debug endpoints: `GET /state /healthz /metrics /screenshot`, `POST /action/openSettings /action/closeSettings`. Versioned automation API under `/v1` (`POST /v1/transcribe`, `POST /v1/jobs`, `GET /v1/jobs/<id>`, `GET`/`POST /v1/jobs/<id>/naming`, `POST /v1/jobs/<id>/naming/skip`, `GET`/`POST /v1/watch`, `GET`/`POST /v1/record`); see `docs/automation-api.md`. `#if !APPSTORE`; started by the Settings toggle or the env flag. `boundPort` exposes OS-assigned port for in-process integration tests. `tools/mt-cli/` is the matching inspection CLI. `scripts/test_rpc.sh` is a live smoketest (build + launch + drive + assert). |

---

## Permissions

| Permission | Required For | Notes |
|------------|-------------|-------|
| Screen Recording | Real meeting titles; fallback grant for the app-audio tap. Detection does not need it | CGWindowListCopyWindowInfo |
| Microphone | Mic recording | AVAudioEngine |
| Accessibility | Participant reading (optional) | Teams AX tree |
| Audio Recording | App audio capture | CATapDescription (Screen Recording also accepted) |

### Permission health check + badge overlay

`PermissionHealthCheck` verifies each of the three TCC permissions by combining the system verdict with a live probe (e.g. `CGWindowListCopyWindowInfo` returning non-empty window titles for Screen Recording). Each permission resolves to `PermissionStatus.healthy | .denied | .broken | .notDetermined` — `.broken` means "TCC says allowed but the probe disagrees," which happens when macOS hasn't actually wired the permission through and the user needs to toggle it off and on in System Settings.

`WatchLoop` runs the check on startup and `AppState` re-runs it on app activation. When the result is unhealthy:

1. `MeetingTranscriberApp` passes `permissionOverlay: true` to `MenuBarIcon.image(...)`, which composites a red circle with a white "!" in the bottom-right corner over the current badge (`MenuBarIcon.drawExclamationBadge`). This bypasses the cached template icons and renders a non-template image because the overlay must stay red in both light and dark mode.
2. `BadgeKind.compute(...)` returns `.error` when idle-with-problem, so the icon also reflects the problem state when no job is active.
3. A notification is posted via `NotificationManager` with the list of affected permissions (deduplicated — only re-posted when the problem set actually changes).

The overlay lives over the *currently active* animation (idle, recording, transcribing, …) so the user still sees what the app is doing and is simultaneously told "one of the permissions is wrong."

<p>
<img src="menu-bar-permission.gif" width="80" alt="Permission problem badge">
</p>

---

## Settings UI

`SettingsView` is a thin `NavigationSplitView` shell: a sidebar lists the tabs, the detail pane shows the selected one. Each tab is a self-contained `View` in `Sources/Settings/` owning only the bindings it needs and its own local `@State`. The settings window is resizable (`minWidth: 760, idealWidth: 860, maxWidth: 1000`).

| Tab | Sections | Bindings | Local state |
|---|---|---|---|
| **General** | Startup · Mode · Apps to Watch · Record Without Asking · Detection · Long Silence | `settings` | — |
| **Audio** | Microphone · Recording Levels · VAD · Echo · Per-Channel Indicator | `settings` | `audioDevices` |
| **Transcription** | Engine + per-engine options + vocabulary source + status | `settings`, three engines, `remoteVocabulary?` | — |
| **Speakers** | Diarization · Speaker Naming · Speaker Identity · Known Voices · Recognition Stats · Experimental: Diarization Tuning | `settings`, `recognitionStatsLog`, `enrollmentDiarizerFactory` | `knownVoicesSheet` |
| **Output** | LLM Provider (with the local model's folder and Check Model) · Notes Language · Output Folder · Recordings (automatic deletion, with its preview) · Notion Export · Meeting Notes Templates · Template Rules | `settings`, `templateStore` | `claudeBinaries` (#if !APPSTORE), connection-test state, `availableModels`; the templates section keeps its state in `ProtocolTemplatesModel`, the rules section in `TemplateRulesModel` |
| **Advanced** | Permissions · Diagnostics | — | `micPermission`, `screenRecordingOK`, `accessibilityOK` |
| **About** | Build identity · Dependencies · Updates | `settings`, `updateChecker?` | — |

**Conditional rendering rules:**
- `noMic` hides the mic-device picker (Audio) and the Speaker Identity section (Speakers)
- `diarize` hides the diarization method picker and the Expected speakers stepper; `diarizerMode` hides the stepper, its hint and the tuning disclosure for Sortformer and Nemotron 3 (they count the speakers themselves)
- `vadEnabled` hides the VAD threshold slider
- `transcriptionEngine` switches between WhisperKit / Parakeet option panels
- `customVocabularyEnabled` hides the vocabulary source picker, the vocabulary file row and the URL controls
- `vocabularySource` switches between the local vocabulary file row and the URL controls (address, token, "Update now", status)
- `protocolProvider` switches between Claude CLI / Codex CLI / Custom Command / OpenAI-compatible / Local model / None panels
- `#if APPSTORE` removes the Claude CLI, Codex CLI, Custom Command and Local model provider options entirely
- `updateChecker == nil` hides the entire Updates section in About

**Cross-cutting concerns owned by sub-views:**
- `OutputSettingsView` owns OpenAI-endpoint connection testing (`testConnection()`); `ProtocolTemplatesModel` owns the template folder I/O (create, open, move to the Trash, delete confirmation, the default template); `TemplateRulesModel` owns the rule list (a pattern is saved only once valid) and the try-a-title result
- `AdvancedSettingsView` owns permission live-probing (`refreshPermissions()`)
- `AboutSettingsView` owns version/build/ffmpeg status and update-check controls

---

## Key Architectural Decisions

1. **@Observable over @StateObject** — Fine-grained reactivity, macOS 14+
2. **PipelineQueue decoupling** — Recording and post-processing run independently; WatchLoop enqueues jobs and resumes watching
3. **AudioTapLib as SPM library** — Direct in-process audio capture via CATapDescription (App Store compatible)
4. **Dual-source recording** — Enables speaker separation without diarization (app=Remote, mic=Me)
5. **Graceful degradation** — Diarization optional, continues on partial failure
6. **Pre-loaded model** — Selected engine (WhisperKit or Parakeet) loaded at app launch, prevents delay on first meeting
7. **5s cooldown** — Prevents re-detecting same meeting after handling
8. **FluidAudio on-device diarization** — Replaces Python pyannote subprocess, no external dependencies
9. **Dual-track diarization** — App and mic tracks diarized separately, avoiding echo/cross-talk interference
10. **Embedded debug RPC + automation API** — In-process HTTP server (`DebugRPCServer`) exposes state, resource metrics (`GET /metrics`), screenshot, and scene actions for shell-driven inspection and integration tests, plus a versioned `/v1` automation API (headless transcribe + job/naming control, plus idempotent `/v1/watch` and `/v1/record` control surfaces behind Stream Deck/hotkey control; reference in `docs/automation-api.md`). Off by default, opt-in via the `Settings → Advanced → Local Automation API` toggle or the `MEETINGTRANSCRIBER_DEBUG_RPC=1` env var, excluded from App Store builds via `#if !APPSTORE`. Action endpoints route through existing `Notification.Name` observers in `MeetingTranscriberApp`, so RPC-driven flows mirror real menu-bar paths.
11. **No expensive work in SwiftUI hot paths** — view bodies, computed properties read by the body, and per-render closures must not call disk I/O, JSON decode, factory constructors, regex compilation, or other non-trivial work. SwiftUI re-renders on every `@State`/`@Observable` change and fans out aggressively, so what looks cheap once becomes a CPU pin fast. Push heavy values up: store as `@State`, inject as a stored property, or surface via an `@Observable` model. Caches that mirror the underlying source (e.g. `PipelineQueue.knownSpeakerNames` mirroring the speakers DB) must wire invalidation from every mutation site in the same PR — see issue #155 → PR #158 → PR #159 for the cautionary tale.
