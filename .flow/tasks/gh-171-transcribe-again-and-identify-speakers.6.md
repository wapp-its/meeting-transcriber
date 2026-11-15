---
satisfies: [R7, R10, R11]
---
# gh-171-transcribe-again-and-identify-speakers.6 Keep word timings and identify speakers again without transcribing

## Description
Slice 2's pipeline half (R7, R10, A4, A22): keep the segments file of a finished meeting whose raw transcript is kept, and add the Identify Speakers Again mode to `rerunJob`, which re-labels the kept words with a new diarization and ends through task 4's swap or task 3's end path.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/SpeakerNamingStore.swift`, `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift`, `app/MeetingTranscriber/Sources/SpeakerNamingSession+Late.swift`, `app/MeetingTranscriber/Sources/PipelineQueue.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+Rerun.swift`, `app/MeetingTranscriber/Sources/PipelineQueue+RerunSwap.swift`, `docs/architecture/diarization.md`, tests
**Touches:** [app/MeetingTranscriber/Sources/SpeakerNaming*.swift, app/MeetingTranscriber/Sources/PipelineQueue*.swift, app/MeetingTranscriber/Sources/MeetingFileStore.swift, app/MeetingTranscriber/Sources/MeetingFileRecord*.swift, docs/architecture/diarization.md, app/MeetingTranscriber/Tests/PipelineQueueRerun*.swift, app/MeetingTranscriber/Tests/SpeakerNamingStoreTests.swift, app/MeetingTranscriber/Tests/PipelineQueueMeetingFilesLifecycleTests.swift]

### Approach
- Kept timings (R7): with "Save raw transcript separately" on, `_segments.json` survives `removeNamingData` (`SpeakerNamingSession.swift:412-422`, which runs `cleanupSidecarFiles` over `sidecarSuffixes`, `SpeakerNamingStore.swift:52,150`), including the unconditional call when the job leaves the queue (`PipelineQueue.swift:~912`) and the call when a job held after completion finishes (`applyJobState`'s `isHeldAfterCompletion` branch, ~1055, since the upstream merge also for failed notes), and `noteNamingFiles` stops marking `.segments` gone then (~1513). With the setting off it goes as today (`removeRawTranscriptArtifactsIfSafe`, 1082-1125, `removeTranscriptSegments`). It is already written owner-only and listed (`PipelineQueue+Stages.swift:1062-1070`). Keep in the record, with it, the label its microphone segments carry (the queue's `micLabel`, `PipelineQueue.swift:165,683-685`).
- Mode Identify Speakers Again with a method and a count. With kept segments: make the 16 kHz copies from the source audio (`AudioMixer.resampleFile`, `AudioMixer.mix` for a recording without its mix, the track names `transcribeDualSource` uses), apply the mic delay as the late re-run does, diarize with the chosen method and count, re-label the kept segments into the re-run's own transcript with the job's annotations (the note, the pauses and the mute spans, `micMuteSpansOnTranscript`, as `renderLabeledTranscript` takes them since the upstream merge; the kept segments already lack muted speech, `removingMuted`) (split a two-track meeting's segments by the recorded mic label, not today's: `DiarizationProcess.labelSegments`, `DiarizationProcess.swift:329-360`, matches `micLabel` exactly; without a recorded label every segment not labelled `remoteSpeakerLabel` is the microphone's), and build the naming data so the dialog opens (`resolveSpeakerNames`, `SpeakerNamingSession.swift:225-323`; the late re-run path `SpeakerNamingSession+Late.swift:247-396,529-592`, which today needs in-memory naming data and writes `job.transcriptPath`, so point it at the re-run's files). Without kept segments: task 2's run with the chosen method and count.
- Ends: speaker identification not available and no voices found end as R6 with the warning line "Identify Speakers Again failed: <reason>", the reason taken from `SpeakerNamingRefusal` (`rerunDiarizerUnavailable`, `rerunFoundNoVoices`); the naming dialog's own Re-run inside such a run works on the re-run's files only.
- Swap (A22): the re-run's segments file takes the current name at success and the earlier one is deleted; before success it stays.
- `docs/architecture/diarization.md` describes the kept timings and this run.

### Investigation targets
**Required:**
- `app/MeetingTranscriber/Sources/SpeakerNamingStore.swift:40-160`
- `app/MeetingTranscriber/Sources/SpeakerNamingSession+Late.swift:241-401,521-593`
- `app/MeetingTranscriber/Sources/SpeakerNamingSession.swift:225-323,404-440`
- `app/MeetingTranscriber/Sources/PipelineQueue.swift:1040-1058,1082-1125,1503-1520`
**Optional:**
- `app/MeetingTranscriber/Tests/PipelineQueueTests.swift:4119-4382` (late re-run suite)
- `app/MeetingTranscriber/Tests/PipelineQueueMeetingFilesLifecycleTests.swift:390-415` (segments permissions)

### Key context
- The segments file holds the transcript text with its timings: it stays owner-only and never reaches a log.
- `ArtifactRenamePlan.artifactURLs` still moves the segments file at a first run's AI-title rename; keep that.
## Acceptance
- [ ] With the raw transcript kept, the segments file stays after naming, after the job leaves the queue and when a job held after completion (failed notes, failed export) finishes, owner-only and listed as `segments`; Move Meeting to Trash moves it; Move Audio to Trash and the recording retention leave it; with the setting off it is deleted as today.
- [ ] With kept timings, Identify Speakers Again calls no transcription engine (stub asserts it), the new transcript has every word in the same order (a word-sequence test, for a two-track meeting also after Settings' mic name changed since the first run), only speaker labels and turn grouping differ, a muted stretch keeps its mute line (A20), and the naming dialog opens with the new speakers.
- [ ] Without kept timings, the run transcribes with the current settings and diarizes with the chosen method and count.
- [ ] Success and failure follow R5 and R6 with the Identify Speakers Again warning lines; speaker identification not available and no voices found each end as R6 with their sentence.
- [ ] At success the re-run's segments file holds the current name and the earlier one is gone; before success the earlier one is byte for byte.
- [ ] `docs/architecture/diarization.md` describes it.
- [ ] The Quick commands' focused tests and `./scripts/lint.sh` pass.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
