---
satisfies: [R1, R2, R3, R4, R5, R6, R7]
---
# gh-163-diarization-controls-that-fit-and-say.1 Implement Diarization controls that fit and say what they do

## Description
TBD

## Acceptance
Every R-ID in the parent spec's ## Acceptance Criteria is satisfied; judge this task against the spec's criteria directly.

## Done summary
Fixed the diarization controls in Settings > Speakers and in the Name Speakers dialog so they fit and say what they do.

- R1: the dialog's re-run area is two lines (method picker alone, then the hint or the count with the Re-run button at the end); every text wraps, the button is fixed-size. `SpeakerNamingRerunLayoutTests` hosts the dialog in a real `NSWindow` at its minimum width (400 pt) and at its opening size for each method and both job kinds and checks the AppKit-backed controls lie inside the content area.
- R2: `DiarizerMode.displayOrder` and `displayName` (Standard, Sortformer, Nemotron 3) drive both pickers; raw values unchanged (pin test untouched).
- R3: `DiarizerMode.methodDescription` shown per option in the Settings radio group; `SpeakersSettingsView.methodHint(for:)` gives the per-call hint (two sides, cap times two).
- R4: count row, its hint and the tuning disclosure exist only while Standard is picked (`countsSpeakersItself`); the onChange clamp is gone, so a stored count survives a method switch (test: 6 survives Sortformer and back).
- R5: dialog count labelled "Speakers in the call audio: N" plus the microphone line for a two-track job, "Speakers: N" for a single file; Settings row "Expected speakers" with the spec's hint.
- R6: `SpeakerNamingView.initialRerunCount(labels:)` counts call-audio keys when labels carry track prefixes, otherwise all, plus one, clamped to 2...10.
- R7: `SpeakerNamingView.rerunMethodHint(mode:isDualSource:)` gives the per-side dialog hint; no text states a per-meeting cap.

Decisions: A4 recorded in the spec (the segmented picker keeps its natural width, centred, because a SwiftUI segmented control does not stretch on macOS).

Verification: `swift test --filter 'SpeakerNamingRerunLayoutTests|SpeakerNamingViewTests|SettingsViewTests|FluidDiarizerSortformerTests|FluidDiarizerNemotronTests|AppSettingsTests|SpeakerNamingFieldIdentityTests|SpeakerNamingRowWritesTests|A11yID'` 270 tests, 0 failures; `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 clean; layouts rendered to PNG and inspected at 400 pt and at the fitting size. Impl review (codex gpt-5.6-sol xhigh): SHIP, no findings.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: cd3ba0d95c93954508ea9b443b38f8c7f98d9ad5
- Tests: cd app/MeetingTranscriber && swift test --filter 'SpeakerNamingRerunLayoutTests|SpeakerNamingViewTests|SettingsViewTests|FluidDiarizerSortformerTests|FluidDiarizerNemotronTests|AppSettingsTests|SpeakerNamingFieldIdentityTests|SpeakerNamingRowWritesTests|A11yID', ./scripts/lint.sh
- PRs: