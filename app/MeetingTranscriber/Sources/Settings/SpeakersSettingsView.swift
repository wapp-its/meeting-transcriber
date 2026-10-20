import SwiftUI

/// Identifiable wrapper letting the Known Voices sheet use `.sheet(item:)`.
/// A fresh `id` per presentation means each open carries its own matcher.
private struct KnownVoicesSheetItem: Identifiable {
    let id = UUID()
    let matcher: SpeakerMatcher
}

struct SpeakersSettingsView: View {
    @Bindable var settings: AppSettings
    var recognitionStatsLog: RecognitionStatsLog
    var stageTimingLog: StageTimingLog
    var enrollmentDiarizerFactory: (() -> any DiarizationProvider)?
    var namingDialogActive: Bool
    var pipelineBusy: Bool
    /// Called whenever the user mutates the speakers DB from the Known
    /// Voices sheet (rename / delete / merge). Used to refresh
    /// `PipelineQueue.knownSpeakerNames` so the next naming dialog sees
    /// up-to-date chips. Optional — tests and the parent that doesn't
    /// own a PipelineQueue can omit.
    var onSpeakerMutate: (() -> Void)?
    var matcherFactory: () -> SpeakerMatcher = { SpeakerMatcher() }

    /// Holds the lazily-created matcher while the Known Voices sheet is up.
    /// `SpeakerMatcher.init` reads + decodes speakers.json, so it must not run
    /// per body re-evaluation — it's built on tap. Drives the sheet via
    /// `.sheet(item:)` rather than `isPresented` + `if let`: item-presentation
    /// fires only once the matcher exists and hands it in unwrapped, avoiding
    /// the SwiftUI race where the first present snapshots a still-nil matcher
    /// and shows an empty window (worked only on the second tap).
    @State private var knownVoicesSheet: KnownVoicesSheetItem?
    // Read only through `$experimentalTuningExpanded` below. Built with Xcode 27,
    // `swiftlint analyze` no longer sees a reference made through the projected
    // value and reports the property as unused.
    // swiftlint:disable:next unused_declaration
    @State private var experimentalTuningExpanded = false

    /// Stepper range for `numSpeakers`. 0 = Auto. The row exists only while
    /// Standard is picked (the other two methods ignore the count, see
    /// `DiarizerMode.countsSpeakersItself`), so the range is Standard's.
    /// Switching the method no longer clamps the stored count: with the row
    /// hidden in the overlap-aware modes a clamp there only destroyed a
    /// value Standard needs when the user switches back.
    static let expectedSpeakerRange = 0 ... DiarizerMode.offline.speakerCap

    /// Hint under the method picker while an overlap-aware method is picked;
    /// `nil` for Standard. The per-call figure is twice the per-track cap: a
    /// recorded call is two tracks, each diarized on its own, so a "caps at
    /// 4" hint read as a meeting limit was wrong by half (issue #163). The
    /// total is written as its sum (2 × cap) next to the per-input cap,
    /// because a bare "up to 8" hid the limit a user actually runs into.
    static func methodHint(for mode: DiarizerMode) -> String? {
        guard mode.countsSpeakersItself else { return nil }
        let cap = mode.speakerCap
        return "\(mode.displayName) counts the speakers itself: up to \(cap) per input. "
            + "A recorded call has two inputs, the call audio and your microphone, so up to \(cap * 2) speakers in total (2 × \(cap))."
    }

    /// What the Standard count does, including the part that misled a user
    /// who entered the meeting total: in a two-track recording it applies to
    /// the call audio only (`PipelineQueue` diarizes the microphone track
    /// with `numSpeakers: nil`).
    static let expectedSpeakersHint = "Auto finds the number. A fixed number forces exactly that many voices. "
        + "In a recorded call it counts only the call audio, because your microphone side is always counted automatically. "
        + "In an imported file it counts everyone."

    var body: some View {
        Form {
            diarizationSection
                .accessibilityIdentifier(A11yID.diarizationSection)
                .recordOnlyDisabled(settings.recordOnly)

            if !settings.noMic {
                Section("Speaker Identity") {
                    HStack {
                        Text("Mic Speaker Name")
                        Spacer()
                        TextField("Me", text: $settings.micName)
                            .frame(width: 160)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier(A11yID.micNameField)
                    }
                    Text("Your name for dual-source mode. Leave empty to diarize mic track (multi-person room).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .recordOnlyDisabled(settings.recordOnly)
            }

            Section("Known Voices") {
                Button("Manage\u{2026}") {
                    knownVoicesSheet = KnownVoicesSheetItem(matcher: matcherFactory())
                }
                Text("Rename, delete, or merge entries in your speaker DB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RecognitionStatsView(log: recognitionStatsLog)

            ProcessingStatsView(log: stageTimingLog)
        }
        .formStyle(.grouped)
        .sheet(item: $knownVoicesSheet) { item in
            KnownVoicesView(
                matcher: item.matcher,
                diarizerFactory: enrollmentDiarizerFactory,
                namingDialogActive: namingDialogActive,
                pipelineBusy: pipelineBusy,
                onMutate: onSpeakerMutate,
            )
        }
    }

    // MARK: - Diarization Section

    private var diarizationSection: some View {
        Section("Diarization") {
            Toggle("Speaker Diarization", isOn: $settings.diarize)
            if settings.diarize {
                diarizationModePicker
                if let hint = Self.methodHint(for: settings.diarizerMode) {
                    Label(hint, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .accessibilityIdentifier(A11yID.diarizationMethodHint)
                }
                // The count and the tuning knobs belong to the clustering
                // diarizer alone: the overlap-aware models read neither.
                if !settings.diarizerMode.countsSpeakersItself {
                    expectedSpeakersRow
                    Label(Self.expectedSpeakersHint, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    experimentalTuningDisclosure
                }
            }
        }
    }

    /// One row per method, name over description, in `DiarizerMode.displayOrder`.
    /// A radio group rather than the segmented control it replaced: three
    /// names alone did not say what the methods do, and a segment has no room
    /// for a second line.
    private var diarizationModePicker: some View {
        Picker("Method", selection: $settings.diarizerMode) {
            ForEach(DiarizerMode.displayOrder, id: \.self) { mode in
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                    Text(mode.methodDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(mode)
            }
        }
        .pickerStyle(.radioGroup)
        .accessibilityIdentifier(A11yID.diarizationMethodPicker)
    }

    private var expectedSpeakersRow: some View {
        HStack {
            Text("Expected speakers")
            Spacer()
            Text(settings.numSpeakers == 0 ? "Auto" : "\(settings.numSpeakers)")
                .frame(width: 40)
                .multilineTextAlignment(.trailing)
            Stepper(
                "",
                value: $settings.numSpeakers,
                in: Self.expectedSpeakerRange,
            )
            .labelsHidden()
            .accessibilityIdentifier(A11yID.expectedSpeakersStepper)
        }
    }

    // MARK: - Experimental Tuning

    private var experimentalTuningDisclosure: some View {
        DisclosureGroup(isExpanded: $experimentalTuningExpanded) {
            tuningDisclosureBody
        } label: {
            tuningDisclosureLabel
        }
        .accessibilityIdentifier(A11yID.experimentalTuningDisclosure)
    }

    private var tuningDisclosureLabel: some View {
        HStack(spacing: 4) {
            Text("Experimental: Diarization Tuning")
            if !settings.diarizerTuningIsAllDefaults {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Non-default tuning active")
            }
        }
    }

    private var tuningDisclosureBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            tuningWarningBanner
            TuningSliderRow(knob: .clusterThreshold, value: $settings.clusterThreshold)
            TuningSliderRow(knob: .warmStartFa, value: $settings.warmStartFa)
            TuningSliderRow(knob: .warmStartFb, value: $settings.warmStartFb)
            TuningSliderRow(knob: .minSegmentDuration, value: $settings.minSegmentDurationSeconds)
            HStack {
                Toggle("Exclude overlap", isOn: $settings.excludeOverlap)
                HelpBadge(
                    text: "When enabled, frames with multiple active speakers are masked out during embedding extraction.",
                )
                Spacer()
            }
            Button("Reset to defaults") {
                settings.resetDiarizerTuning()
            }
            .disabled(settings.diarizerTuningIsAllDefaults)
        }
        .padding(.top, 4)
    }

    private var tuningWarningBanner: some View {
        Label(
            "Changing these values may degrade diarization quality. Use with caution and reset if unsure.",
            systemImage: "exclamationmark.triangle.fill",
        )
        .foregroundColor(.red)
        .font(.caption)
        .padding(.vertical, 4)
    }
}

// MARK: - Tuning slider helpers

/// Static description of a single experimental tuning knob — keeps the
/// per-knob configuration (range, step, format, label, help text) out of
/// the SwiftUI body so it stays easy to read and lint-friendly.
private struct TuningKnob {
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    let suffix: String
    let help: String

    static let clusterThreshold = Self(
        title: "Cluster threshold",
        range: 0.0 ... 1.0,
        step: 0.05,
        format: "%.2f",
        suffix: "",
        help: "Cosine-similarity threshold for merging speaker embeddings. Higher values split speakers more aggressively (more speakers detected).",
    )

    static let warmStartFa = Self(
        title: "Warm-start Fa",
        range: 0.0 ... 1.0,
        step: 0.01,
        format: "%.2f",
        suffix: "",
        help: "VBx warm-start Fa controls clustering precision. Increasing it tightens speaker boundaries.",
    )

    static let warmStartFb = Self(
        title: "Warm-start Fb",
        range: 0.0 ... 2.0,
        step: 0.05,
        format: "%.2f",
        suffix: "",
        help: "VBx warm-start Fb controls clustering recall. Increasing it merges similar speakers more readily.",
    )

    static let minSegmentDuration = Self(
        title: "Min segment duration",
        range: 0.0 ... 5.0,
        step: 0.1,
        format: "%.1f",
        suffix: "s",
        help: "Skip embedding extraction for segments shorter than this duration. Larger values trade recall for stability.",
    )
}

private struct TuningSliderRow: View {
    let knob: TuningKnob
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(knob.title)
                HelpBadge(text: knob.help)
                Spacer()
                Text("\(String(format: knob.format, value))\(knob.suffix)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: knob.range, step: knob.step)
        }
    }
}
