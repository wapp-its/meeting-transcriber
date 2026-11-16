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
- Kept timings (R7): with "Save raw transcript separately" on, `_segments.json` survives `removeNamingData` (`SpeakerNamingSession.swift:412-422`, which runs `cleanupSidecarFiles` over `sidecarSuffixes`, `SpeakerNamingStore.swift:52,150`), including the unconditional call when the job leaves the queue (`PipelineQueue.swift:~912`) and the call when a job held after completion finishes (`applyJobState`'s `isHeldAfterCompletion` branch, ~1055, since the upstream merge also for failed notes), and `noteNamingFiles` stops marking `.segments` gone then (~1513). With the setting off it goes as today (`removeRawTranscriptArtifactsIfSafe`, 1082-1125, `removeTranscriptSegments`); for a re-run that step runs after the swap's commit (task 4). It is already written owner-only and listed (`PipelineQueue+Stages.swift:1062-1070`). Keep in the record, with it, the label its microphone segments carry (the queue's `micLabel`, `PipelineQueue.swift:165,683-685`).
- Mode Identify Speakers Again with a method and a count. With kept segments: make the 16 kHz copies from the source audio (`AudioMixer.resampleFile`, `AudioMixer.mix` for a recording without its mix, the track names `transcribeDualSource` uses), apply the mic delay as the late re-run does, diarize with the chosen method and count, re-label the kept segments into the re-run's own transcript with the job's annotations (the note, the pauses and the mute spans, `micMuteSpansOnTranscript`, as `renderLabeledTranscript` takes them since the upstream merge; the kept segments already lack muted speech, `removingMuted`) (split a two-track meeting's segments by the recorded mic label, not today's: `DiarizationProcess.labelSegments`, `DiarizationProcess.swift:329-360`, matches `micLabel` exactly; without a recorded label every segment not labelled `remoteSpeakerLabel` is the microphone's), and build the naming data so the dialog opens (`resolveSpeakerNames`, `SpeakerNamingSession.swift:225-323`; the late re-run path `SpeakerNamingSession+Late.swift:247-396,529-592`, which today needs in-memory naming data and writes `job.transcriptPath`, so point it at the re-run's files). Without kept segments: task 2's run with the chosen method and count.
- Ends: speaker identification not available and no voices found end as R6 with the warning line "Identify Speakers Again failed: <reason>", the reason taken from `SpeakerNamingRefusal` (`rerunDiarizerUnavailable`, `rerunFoundNoVoices`); the naming dialog's own Re-run inside such a run works on the re-run's files only. Two tracks (A25, task 3's run result): when Identify Speakers Again diarizes through `runDualTrackDiarization` (`SpeakerNamingSession+Late.swift:457-490`), a track that was offered and failed ends it as R6 with "Identify Speakers Again failed: <reason>"; in the naming dialog's own Re-run of a re-run job (either mode) it makes that Re-run fail as a whole, `returnToNaming(..., failure: .rerunFailed)` with the labels it had (`SpeakerNamingSession+Late.swift:389-395`); a track measured as holding no audio is no failure; a new meeting's late Re-run keeps its one-track fallback.
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
- [ ] In a two-track meeting, a failing track ends Identify Speakers Again as R6, and makes the naming dialog's own Re-run inside a re-run fail with the labels it had; a new meeting's late Re-run with one failing track still falls back to the other.
- [ ] Success and failure follow R5 and R6 with the Identify Speakers Again warning lines; speaker identification not available and no voices found each end as R6 with their sentence.
- [ ] At success the re-run's segments file holds the current name and the earlier one is gone; before success the earlier one is byte for byte.
- [ ] `docs/architecture/diarization.md` describes it.
- [ ] The Quick commands' focused tests and `./scripts/lint.sh` pass.
## Done summary
A meeting whose raw transcript is kept separately now keeps its transcript segments file (its word timings), listed in its record as `segments`. The queue has a new re-run mode, Identify Speakers Again (`PipelineQueue.rerunJob(id:mode: .identifySpeakersAgain, speakers:)`), which labels those kept words again without transcribing (R7, R10, R11).

stage: impl-review - ran [09:33..10:08] (codex:gpt-6.1-sol:xhigh; three lenses then two single-reviewer re-reviews; NEEDS_WORK, NEEDS_WORK, SHIP; every receipt names gpt-6.1-sol at xhigh)

Tier: implementer - opus (explicit invocation) at xhigh effort (requested) (model: claude-opus-5-5)

Baseline: green. The build and 303 focused tests passed before any edit.

### What changed

Kept word timings (R7):
- The segments file now stays in three places where it used to be deleted:
  - when the speakers are named (`SpeakerNamingSession.removeResolvedNamingData`);
  - when a done job leaves the queue, or a restore discards it;
  - when a job held after completion finishes.
- It stays only for a meeting that has a record and whose stamped option `saveRawTranscriptSeparately` is on (`PipelineQueue.keepsWordTimings`).
- It is deleted as before for:
  - a dismissed or failed job;
  - a Retry;
  - a meeting without a record;
  - any meeting with the option off.
- The file stays owner-only. Move Meeting to Trash takes it; Move Audio to Trash and the recording retention leave it.
- The naming session asks through a new delegate requirement, `keepsWordTimings(jobID:)`, which defaults to false.

Identify Speakers Again (R10):
- **Settings:** it always identifies speakers. It uses the method and count the caller chose (`RerunSpeakers`), else Settings' own. A method whose factory is missing falls back to the queue's diarizer and logs `rerun_method_unavailable`.
- **With kept timings** (`PipelineQueue+Stages.swift` `reuseWordTimings`), stage 1:
  - makes the 16 kHz copies;
  - takes the track verdict and the echo measure;
  - hands the kept segments on as the transcription.

  It calls no engine and does not enter `.transcribing`, so the transcription speed figures stay clean. It also:
  - tags the two-track segments again with this queue's mic label (`retaggedForThisQueue`);
  - keeps the first run's mute lines, also on the mix or on one track;
  - puts a lone microphone track on the meeting's timeline (`moveOntoTheMeetingsTimeline`);
  - renders tied lines in the kept order (`inKeptOrder`), or in the order an older transcript has them (`inTheTranscriptsOrder`).
- **Without kept timings** (or with an unreadable file) it transcribes with the current settings first.
- **Each failure ends it as R6, with its own line:**

  | Cause | Line |
  |---|---|
  | Speaker identification not available | "speaker diarization is not available right now" |
  | Diarization found no voices | "found no voices to name" |
  | A track fails | as for Transcribe Again |

  In the naming dialog, a Re-run during any re-run fails as a whole when a track fails, and the labels go back to what they were. A new meeting's late Re-run still falls back to the other track. Re-runs no longer get the one-side warning.
- **At commit:**
  - The re-run's segments file takes the current name and the earlier one is deleted (task 4's `finishCommittedRerun`).
  - Task 4's `removeEarlierSegments` also deletes the earlier file when the re-run kept no segments file of its own.
  - Before success, the earlier file stays byte for byte.

### Verification on the reviewed head
- `swift build -j 6 --build-tests`: exit 0.
- Focused tests (`--num-workers 2`): exit 0, 905 tests, all of them passed.
  - The filter is the Quick filter plus the rendering classes this change reaches: `DiarizationLabelSegmentsTests`, `DualTrackTranscriptionTests`, `DualTrackViabilityTests`, `MicMuteReimportTests`, `StaleNamingTimeoutTests`, `Echo*` and `PipelineControllerTests`.
- `./scripts/lint.sh` with the pinned SwiftFormat and SwiftLint: 0 violations.
- Wiring check:
  - The new tests fail when any one of these is removed: the retag, the earlier-segments removal, the re-run track guard, the keep flag, the admission's mute keep, the timeline move, the kept-order sort, or the transcript-order step.
  - Each removal fails for the stated reason, and every line was restored afterwards.

### Tests per acceptance criterion
- **Kept word timings:**
  - `PipelineQueueMeetingFilesLifecycleTests.testAFinishedMeetingKeepsItsWordTimingsOnlyWithTheRawTranscriptKept` covers named, left the queue and held after completion, each with the option on and off, plus 0600, the record listing and the trash scopes.
  - `SpeakerNamingStoreTests.test_cleanupSidecarFiles_keepingSegments_leavesOnlyTheSegmentsFile`.
- **Without transcribing:** `PipelineQueueRerunIdentifyTests.testItLabelsTheKeptWordsAgainWithoutTranscribingAndNamesTheNewSpeakers` covers:
  - the stubbed engine is never called;
  - the word sequence is unchanged after Settings' mic name changed;
  - the mute line stays;
  - the dialog opens with new speakers;
  - the segments file takes the current name and the earlier one is gone.
- **Fallback sources:** `testOnWhatIsLeftOfItsAudioItKeepsTheMuteLinesAndTheMeetingsTimeline`.
- **Tied lines:** `testTwoLinesStartingAtOnceKeepTheirOrderWhenBothTracksAreLabelledAgain` covers both a new transcript and one from an earlier build.
- **Method, count, and the no-timings path:** `testItDiarizesWithTheChosenMethodAndCountAndTranscribesOnlyWithoutKeptWordTimings`.
- **Ends:** `testEachFailureEndsItWithItsLineAndLeavesTheMeetingAsItWas` covers not available, no voices, call audio failing and microphone failing.
- **Dialog Re-run with a failing track:** `testTheDialogsRerunWithAFailingTrackKeepsTheLabelsItHad`.
- **Earlier segments with nothing kept:** `testARerunThatKeptNoWordTimingsTakesTheEarlierOnesAlong`.
- **New meeting's late Re-run with one failing track:** the existing `PipelineQueueTests.testLateRerunDualSourceMicFailFallsBackToAppOnly`, unchanged and passing.

Tests changed by declared intent (R7 keeps a file the old tests expected gone):
- In `PipelineQueueMeetingFilesLifecycleTests`, the reaping test and `testEveryWayOutOfNamingMarksItsFilesGone` now expect the segments file to stay.
- In `PipelineQueueRerunSwapTests`:
  - the earlier transcript count ignores the earlier segments entry, which A22 marks gone;
  - the kept-false row also deletes the file, so it stands for a meeting from before R7.
- `PipelineQueueRerunSwapRecoveryTests` compares the expected files by resolved path.

### Decisions and assumptions (reversible)
1. **Which meetings keep their timings:** only a meeting with a record. The record is how Move Meeting to Trash finds the file, so without one the file would outlive the meeting.
2. **The mic label is not stored.** Every segment not tagged `Remote` is the microphone's, which is the spec's own fallback rule. The mic label is sanitized and never reads `Remote`, so a stored label could not change the split.
3. **Echo:** identify measures echo so that the naming's voice-profile quarantine works, but it neither announces it nor runs echo cancellation. The microphone track is diarized as recorded.
4. **Kept-order tie-break:** the tie-break follows the kept order in every rendering, which changes only lines with exactly equal starts.

### Deviation
One line outside Touches: `TranscriptionsView+RowLabels.swift` gains the `.identifySpeakersAgain` case of `rerunWarningLine`'s exhaustive switch ("Identify Speakers Again"). Without it the code does not compile, and the acceptance criteria require it for the warning lines.

### Follow-ups
- Reviewer FYI, not blocking: `inTheTranscriptsOrder` finds each tied text's first occurrence anywhere in the transcript. A phrase repeated earlier in the meeting could therefore order a later tie wrongly. This only affects transcripts rendered by an earlier build.
- A track whose transcription failed in the first run is not known to identify. Both tracks' kept segments are labelled with what diarization finds.
- `PipelineController.rerunJob` still has no `speakers:` parameter. Task 7 adds the row item and the sheet on top of the queue's mode.
- The app-store variant was not built locally. Nothing in the change is variant-gated.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: d16dbec4ef1c7e17d632ccc8b4c1323e3bc5a54b, 6f227e4822d3e95da6c7f2461d778c289d72ff14, 67b74e4f5af1c0f0c309fac5cd5f222bbd498332, 033055bc78c674451cf4367564627c681e7890ad, 322c54d52d7247774282ce5a023301cee5ab770b
- Tests: cd app/MeetingTranscriber && swift build -j 6 --build-tests (exit 0), CFFIXED_USER_HOME=<scratch dir> swift test --skip-build --parallel --num-workers 2 --filter '<Quick filter>|DiarizationLabelSegmentsTests|DualTrackTranscriptionTests|DualTrackViabilityTests|MicMuteReimportTests|StaleNamingTimeoutTests|Echo|PipelineControllerTests' (exit 0, 905 tests), ./scripts/lint.sh (exit 0, 0 violations)
- PRs: