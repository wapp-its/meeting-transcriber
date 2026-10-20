// swiftlint:disable file_length
// `@preconcurrency`: AVFoundation types lack Sendable annotations —
// same gap as AudioMixer.swift; preemptively guarded.
@preconcurrency import AVFoundation
import SwiftUI

/// Format seconds as "Xs" or "M:SS".
func formattedTime(_ seconds: Double) -> String {
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return m > 0 ? "\(m):\(String(format: "%02d", s))" : "\(s)s"
}

/// Window that lets the user name speakers after diarization.
struct SpeakerNamingView: View { // swiftlint:disable:this type_body_length
    let data: PipelineQueue.SpeakerNamingData
    /// Names of speakers known from previous meetings, surfaced as quick-pick chips
    /// in addition to the current meeting's participants. Empty array hides the row.
    let knownSpeakerNames: [String]
    /// Diarizer mode used to produce `data`. Initial value for the re-run
    /// mode picker. `nil` for legacy jobs without a recorded mode — the
    /// picker initialises to `.offline` in that case.
    let currentDiarizerMode: DiarizerMode?
    /// Number of jobs currently waiting for speaker naming. Part of the grace
    /// gate's identity, not display state: a job arriving here force-activates
    /// the app, so the buttons must re-lock even though the displayed data is
    /// unchanged. See `NamingGraceKey`.
    let pendingJobCount: Int
    /// Whether each voice sample is brought to a common speech level before it
    /// plays (`playbackSnippet`). The naming dialog passes
    /// `AppSettings.levelBalanceEnabled`; voice enrollment leaves it off.
    let balanceSampleLevels: Bool
    /// Invoked when the user asks to dismiss the dialog (Escape). Closing is a
    /// no-op for the job — it stays `.speakerNamingPending` and can be reopened
    /// from the menu bar — which is what makes it a safe thing to bind a stray
    /// keystroke to. `nil` for hosts with no window to close (voice enrollment
    /// renders this view inline), where Escape stays inert.
    let onDismissRequest: (() -> Void)?
    let onComplete: (PipelineQueue.SpeakerNamingResult) -> Void

    /// Window after the dialog appears (or after Re-run produces a fresh `data.revision`)
    /// during which Confirm and Skip remain disabled. Prevents accidental confirms from
    /// stray Enter/Escape keystrokes that leak from another app's focus when
    /// `bringWindowToFront` steals focus mid-keystroke. Historical pipeline_log data
    /// shows ~19% of speaker-naming sessions exiting within 2-3 s — an isolated cluster
    /// outside the log-normal human-confirm distribution. See
    /// `docs/plans/.local/research/2026-05-19-late-speaker-renaming-after-done.md`.
    static let defaultKeyboardGracePeriod: TimeInterval = 0.75

    let gracePeriod: TimeInterval

    init(
        data: PipelineQueue.SpeakerNamingData,
        knownSpeakerNames: [String] = [],
        currentDiarizerMode: DiarizerMode? = nil,
        pendingJobCount: Int = 1,
        balanceSampleLevels: Bool = false,
        gracePeriod: TimeInterval = Self.defaultKeyboardGracePeriod,
        onDismissRequest: (() -> Void)? = nil,
        onComplete: @escaping (PipelineQueue.SpeakerNamingResult) -> Void,
    ) {
        self.data = data
        self.knownSpeakerNames = knownSpeakerNames
        self.currentDiarizerMode = currentDiarizerMode
        self.pendingJobCount = pendingJobCount
        self.balanceSampleLevels = balanceSampleLevels
        self.gracePeriod = gracePeriod
        self.onDismissRequest = onDismissRequest
        self.onComplete = onComplete
        // Seed `names` and `rerunCount` synchronously so the view renders
        // its fields and chip rows with the right contents on first body
        // evaluation. `.onAppear` re-runs the same logic for belt-and-braces,
        // but this lets ViewInspector tests + tests that never trigger the
        // SwiftUI lifecycle still see the correct surface.
        let speakerList = Self.computeSpeakers(from: data)
        _rows = State(
            initialValue: SpeakerNamingRowState(names: Self.computeInitialNames(speakers: speakerList)),
        )
        _rerunMode = State(initialValue: currentDiarizerMode ?? .offline)
        _rerunCount = State(initialValue: Self.initialRerunCount(labels: speakerList.map(\.label)))
        // Initialize the grace-period gate to "active" when the period is positive
        // so the buttons start disabled. When tests pass gracePeriod = 0 the gate
        // starts open (no grace) and the unlock task is a no-op.
        _keyboardGracePeriodActive = State(initialValue: gracePeriod > 0)
    }

    /// Smallest width the dialog can be shown at. The window scene uses
    /// `.windowResizability(.contentSize)`, so this is also the narrowest the
    /// window opens at, and every control in the re-run area has to fit it
    /// without truncation (`SpeakerNamingRerunLayoutTests`).
    static let minimumWidth: CGFloat = 400

    /// Range of the re-run count. The count is read by the Standard method
    /// only (`DiarizerMode.countsSpeakersItself`), so the range is Standard's
    /// and does not change with the picked method.
    static let rerunCountRange = 1 ... DiarizerMode.offline.speakerCap

    /// The count the dialog starts at: one more than the speakers the count
    /// applies to, because the user opens this control when the result has
    /// too few. In a two-track recording the count applies to the call audio
    /// only (the microphone track is always diarized automatically), so with
    /// track-prefixed labels only the call audio's (`R_`) speakers are counted.
    /// Unprefixed labels (a single file, or a two-track job where one track's
    /// diarization failed and the other's labels were kept bare) count every
    /// speaker: the naming data does not say which track survived, and a
    /// starting value the user can change in one click did not justify
    /// persisting that. At least 2, at most Standard's cap.
    static func initialRerunCount(labels: some Sequence<String>) -> Int {
        let keys = labels.map(SpeakerKey.init(encoded:))
        let prefixed = keys.contains { $0.track != .single }
        let counted = keys.filter { !prefixed || $0.track == .app }.count
        return min(max(2, counted + 1), rerunCountRange.upperBound)
    }

    /// Label of the count control. Names the call audio for a two-track job,
    /// because that is the only track the count applies to.
    static func rerunCountLabel(count: Int, isDualSource: Bool) -> String {
        isDualSource ? "Speakers in the call audio: \(count)" : "Speakers: \(count)"
    }

    /// Shown under the count of a two-track job.
    static let micSideNote = "Your microphone side is always counted automatically."

    /// Hint shown in place of the count while an overlap-aware method is
    /// picked; `nil` for Standard. Per track, never per meeting: the earlier
    /// "caps at 4 speakers" hint read as a meeting limit and was contradicted
    /// by the two-track result it sat under (issue #163).
    static func rerunMethodHint(mode: DiarizerMode, isDualSource: Bool) -> String? {
        guard mode.countsSpeakersItself else { return nil }
        let cap = mode.speakerCap
        return isDualSource
            ? "\(mode.displayName) counts the speakers itself: up to \(cap) in the call audio and \(cap) on your microphone."
            : "\(mode.displayName) counts the speakers itself: up to \(cap)."
    }

    /// Identity of the current grace window. Changing it re-locks the buttons.
    var graceKey: NamingGraceKey {
        NamingGraceKey(revision: data.revision, pendingJobCount: pendingJobCount)
    }

    @State private var keyboardGracePeriodActive: Bool = true
    /// Everything the user changes in the rows: the name per label and which
    /// rows are expanded. A reference type held in `@State`, so a row's write
    /// is observable from outside the view (see `SpeakerNamingRowState`).
    @State private var rows: SpeakerNamingRowState
    /// Job-ID for which this view has already fired `onComplete`. Tracked
    /// per-job (not just a Bool) so that when the window switches to a
    /// different pending job, the `Confirm` / `Skip` / `Re-run` buttons
    /// are responsive again. Previous Bool-only guard could get stuck
    /// across multi-job switching, leaving the dialog effectively dead.
    @State private var completedJobID: UUID?
    @State private var player: AVAudioPlayer?
    @State private var playingLabel: String?
    @State private var rerunMode: DiarizerMode = .offline
    @State private var rerunCount: Int = 2
    /// Number of "Known:" chips shown by default before "More…" appears.
    private static let knownChipsCollapsedLimit = 8

    private var speakers: [(label: String, autoName: String?, speakingTime: Double)] {
        Self.computeSpeakers(from: data)
    }

    /// Re-run controls on two lines: the method picker across the full width,
    /// then either the count (Standard) or the hint that the method counts
    /// the speakers itself (Sortformer, Nemotron 3), with the Re-run button
    /// at the end of that line. Two lines because the single row this
    /// replaced (label, 280 pt picker, stepper, button) was wider than the
    /// dialog's minimum width, and at that width SwiftUI truncated its texts.
    /// Now the only fixed-width items on a line are the stepper and the
    /// button; the texts wrap. Re-run posts `.rerunWithMode(mode, count)`
    /// when the caller tracks the job's method, otherwise the legacy
    /// `.rerun(count)` form (so consumers that don't care about
    /// mode-switching stay unaffected); in the overlap-aware modes the count
    /// travels along and the diarizer ignores it, as it always did.
    private var rerunSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Hide the mode picker for callers that don't track per-job
            // diarizer mode (currently the voice-enrollment flow): they
            // can't honour `.rerunWithMode`, so a visible-but-inert
            // picker would silently discard the user's choice.
            if currentDiarizerMode != nil {
                rerunModePicker
            }
            HStack(alignment: .top, spacing: 12) {
                if let hint = Self.rerunMethodHint(mode: rerunMode, isDualSource: data.isDualSource) {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(A11yID.rerunMethodHint)
                } else {
                    rerunCountControl
                }
                rerunButton
            }
        }
    }

    private var rerunCountControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Stepper(
                Self.rerunCountLabel(count: rerunCount, isDualSource: data.isDualSource),
                value: $rerunCount,
                in: Self.rerunCountRange,
            )
            .font(.caption)
            .fixedSize()
            .accessibilityIdentifier(A11yID.rerunStepper)
            if data.isDualSource {
                Text(Self.micSideNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(A11yID.rerunMicSideNote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rerunModePicker: some View {
        Picker("", selection: $rerunMode) {
            ForEach(DiarizerMode.displayOrder, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .font(.caption)
        .accessibilityIdentifier(A11yID.rerunModePicker)
    }

    private var rerunButton: some View {
        Button("Re-run") {
            guard completedJobID != data.jobID else { return }
            completedJobID = data.jobID
            player?.stop()
            // `nil` currentDiarizerMode = legacy / enrollment caller that
            // doesn't track per-job mode → keep the legacy `.rerun(count)`
            // shape so those consumers stay unaffected. When the caller
            // provides a mode, always fire `.rerunWithMode` so the picker's
            // selection is authoritative — even when it matches the
            // recorded mode. Otherwise lateDiarization would fall back to
            // the no-arg factory (current global setting), which can differ
            // from the recorded mode if the user touched Settings between
            // recording and re-run.
            if currentDiarizerMode != nil {
                onComplete(.rerunWithMode(rerunMode, rerunCount))
            } else {
                onComplete(.rerun(rerunCount))
            }
        }
        .font(.caption)
        // Never shrinks or wraps: the texts on its line give way instead.
        .fixedSize()
        .accessibilityIdentifier(A11yID.rerunButton)
    }

    static func computeSpeakers(
        from data: PipelineQueue.SpeakerNamingData,
    ) -> [(label: String, autoName: String?, speakingTime: Double)] {
        data.mapping.keys.sorted().map { label in
            let autoName = data.mapping[label]
            let isAutoNamed = autoName != nil && autoName != label
            return (
                label: label,
                autoName: isAutoNamed ? autoName : nil,
                speakingTime: data.speakingTimes[label] ?? 0,
            )
        }
    }

    var body: some View {
        // swiftlint:disable:next closure_body_length
        VStack(spacing: 16) {
            Text("Name Speakers — \"\(data.meetingTitle)\"")
                .font(.headline)
                .padding(.top, 8)

            ScrollView {
                VStack(spacing: 16) {
                    ForEach(speakers, id: \.label) { speaker in
                        speakerRow(speaker: speaker)
                    }
                }
            }
            .frame(height: min(CGFloat(speakers.count) * 120, 500))

            Divider()

            rerunSection

            HStack(spacing: 12) {
                // Deliberately no `.keyboardShortcut(.escape)`. Skip accepts the
                // matcher's guesses and then deletes the naming data, so it is
                // irreversible — while Escape means "dismiss this" to everyone
                // who has ever used a Mac. Binding the two made a dismissal
                // silently commit a low-confidence auto-match (issue #577).
                // Escape now closes the window instead (see `onDismissRequest`),
                // which leaves the job pending and re-openable.
                Button("Skip") {
                    guard completedJobID != data.jobID else { return }
                    completedJobID = data.jobID
                    onComplete(.skipped)
                }
                .disabled(keyboardGracePeriodActive)
                .accessibilityIdentifier(A11yID.skipButton)

                Button("Confirm") {
                    guard completedJobID != data.jobID else { return }
                    completedJobID = data.jobID
                    confirm()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(keyboardGracePeriodActive)
                .accessibilityIdentifier(A11yID.confirmButton)
            }
            .padding(.bottom, 8)

            escapeDismissShortcut
        }
        .padding()
        .frame(minWidth: Self.minimumWidth, maxHeight: 700)
        .id(data.meetingTitle)
        .onAppear { resetForCurrentPresentation() }
        // After Re-run, lateDiarization replaces the SpeakerNamingData for
        // the same jobID. Watching `data.revision` (a fresh UUID per
        // instance) fires reliably even when the new mapping happens to be
        // byte-identical to the previous one — otherwise the per-job
        // `completedJobID` guard kept Confirm/Skip/Re-run dead.
        .onChange(of: data.revision) { _, _ in
            resetForCurrentPresentation()
        }
        // Escape dismisses the window rather than resolving the job. The
        // optional is passed straight through, so a host that supplies none
        // installs no handler at all and Escape keeps bubbling — the voice
        // enrollment flow renders this view in a sheet, where swallowing Escape
        // would silently break sheet-dismisses-on-Escape for one stage only.
        //
        // `onExitCommand` alone is not enough, which is easy to miss: it only
        // sees Escape once something translated the keystroke into
        // `cancelOperation:`, and that translation happens in
        // `interpretKeyEvents:`, which only text-input responders call. With no
        // name field focused, AppKit's fallback emits `cancel:` instead and the
        // handler never runs. The destructive binding this replaced did not have
        // that gap — a `keyboardShortcut` rides the key-equivalent pass, which
        // fires regardless of focus, which is exactly how a stray Escape reached
        // Skip in the first place. So the dismiss is bound both ways (see
        // `escapeDismissShortcut`) rather than trading one blind spot for another.
        .onExitCommand(perform: onDismissRequest)
        // Keyboard-grace gate: keep Confirm + Skip disabled for `gracePeriod`
        // seconds after the dialog appears, after each Re-run produces a fresh
        // `data.revision`, and whenever another job reaches naming and steals
        // focus. The `task(id:)` cancels + restarts when `graceKey` changes,
        // re-locking the buttons each time.
        .task(id: graceKey) {
            guard gracePeriod > 0 else {
                keyboardGracePeriodActive = false
                return
            }
            keyboardGracePeriodActive = true
            try? await Task.sleep(for: .seconds(gracePeriod))
            if !Task.isCancelled {
                keyboardGracePeriodActive = false
            }
        }
        // No onDisappear → .skipped: in the non-blocking architecture closing
        // the window (Cmd+Q, click X, app quit) leaves the job in
        // .speakerNamingPending so the user can re-open later. Explicit Skip
        // button still calls onComplete(.skipped).
    }

    /// Zero-sized carrier for the Escape key equivalent, present only when the
    /// host gave us something to dismiss.
    ///
    /// A button rather than another view modifier because `.cancelAction` is the
    /// documented way onto the key-equivalent pass, and that pass is what makes
    /// Escape work with nothing focused. Not user-visible: the dialog's
    /// affordances stay Skip and Confirm, and closing is already reachable by the
    /// window's close button. Deliberately *not* behind the keyboard-grace gate —
    /// dismissing changes nothing about the job, so there is no accident to
    /// protect against, which is the whole reason Escape was moved here.
    @ViewBuilder private var escapeDismissShortcut: some View {
        if let onDismissRequest {
            Button("", action: onDismissRequest)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// Re-seed all per-presentation state from the current `data`. Called on
    /// first appearance and again whenever `data.revision` changes. The key is
    /// `revision` and not `mapping` on purpose: a re-diarization can produce a
    /// byte-equal `mapping`, and comparing that would swallow the reset.
    private func resetForCurrentPresentation() {
        completedJobID = nil
        rows.reset(names: Self.computeInitialNames(speakers: speakers))
        // Re-seed `rerunMode` from the prop so cross-job dialog switches
        // (same view identity, different data) start with the correct
        // picker selection instead of inheriting the previous job's mode.
        rerunMode = currentDiarizerMode ?? rerunMode
        rerunCount = Self.initialRerunCount(labels: speakers.map(\.label))
    }

    private func speakerRow(
        speaker: (label: String, autoName: String?, speakingTime: Double),
    ) -> some View {
        // swiftlint:disable:next closure_body_length
        GroupBox {
            // swiftlint:disable:next closure_body_length
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(speaker.label)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if data.audioPath != nil {
                        Button {
                            playSpeakerSnippet(label: speaker.label)
                        } label: {
                            Image(systemName: playingLabel == speaker.label
                                ? "stop.circle.fill" : "play.circle.fill")
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.play(speaker.label))
                    }

                    Spacer()
                    Text("(\(formattedTime(speaker.speakingTime)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let autoName = speaker.autoName {
                    Text("Auto: \(autoName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Read here, next to the field, and passed down rather than
                // read inside `suggestionChips`. Beyond feeding the chip
                // filter, this read is what registers the row body's
                // observation dependency on `names`, and that dependency is
                // what redraws the field when a chip writes into it. Measured
                // in a hosted window: mutate the object, the field repaints.
                // A refactor that stops reading `names` while rendering the row
                // would leave chip taps invisible on screen while every
                // in-process test stayed green, since those re-evaluate the
                // body themselves.
                let typed = rows.names[speaker.label] ?? ""
                nameField(for: speaker.label)
                suggestionChips(for: speaker, query: typed)
            }
            .padding(4)
        }
    }

    /// A plain `TextField`, on purpose: it takes a fresh binding on every update,
    /// so nothing parked on the field can outlive the row's position (issue #700).
    /// Why it is no longer the `NSViewRepresentable` it once was: see CLAUDE.md (#702).
    private func nameField(for label: String) -> some View {
        TextField("Name", text: nameBinding(for: label))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.speakerName(label))
    }

    /// Captures the row state rather than `self`: SwiftUI keeps the binding it
    /// handed the field until the next update, and capturing the view would
    /// keep that job's segments and embeddings alive with it.
    private func nameBinding(for label: String) -> Binding<String> {
        let store = rows
        return Binding(
            get: { store.names[label] ?? "" },
            set: { store.names[label] = $0 },
        )
    }

    /// Live-filtered chip rows. Typing in the field shrinks both rows to names
    /// matching the query — typing IS the filter UI, no separate dropdown.
    /// Same name in multiple rows is allowed (legitimate in dual-track when
    /// M_ and R_ pick up the same speaker).
    @ViewBuilder
    private func suggestionChips(
        for speaker: (label: String, autoName: String?, speakingTime: Double),
        query: String,
    ) -> some View {
        participantChips(for: speaker.label, query: query)
        knownChips(for: speaker, query: query)
    }

    @ViewBuilder
    private func participantChips(for label: String, query: String) -> some View {
        let participants = Self.filterByQuery(names: data.participants, query: query)
        if !participants.isEmpty {
            chipRow(names: participants, idPrefix: A11yID.participantNamePrefix) { rows.names[label] = $0 }
        }
    }

    @ViewBuilder
    private func knownChips(
        for speaker: (label: String, autoName: String?, speakingTime: Double),
        query: String,
    ) -> some View {
        let known = Self.filterByQuery(names: knownNamesNotInParticipants, query: query)
        if !known.isEmpty {
            let ranked = Self.rankedKnownNames(
                known: known, autoName: speaker.autoName, participants: data.participants,
            )
            let expanded = rows.knownExpanded.contains(speaker.label)
            // Don't bother with the Top-N cap once the user has typed — they're
            // already looking at a filtered short list.
            let limit = query.isEmpty ? Self.knownChipsCollapsedLimit : ranked.count
            let visible = expanded ? ranked : Array(ranked.prefix(limit))
            let hidden = ranked.count - visible.count

            VStack(alignment: .leading, spacing: 2) {
                Text("Known:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ChipFlowLayout(spacing: 4) {
                    ForEach(visible, id: \.self) { name in
                        chipButton(label: name, identifier: A11yID.knownName(name)) {
                            rows.names[speaker.label] = name
                        }
                    }
                    if hidden > 0 {
                        chipMoreButton(
                            label: "More (\(hidden))…",
                            identifier: A11yID.knownMore(speaker.label),
                        ) { rows.knownExpanded.insert(speaker.label) }
                    } else if expanded, ranked.count > Self.knownChipsCollapsedLimit {
                        chipMoreButton(
                            label: "Less",
                            identifier: A11yID.knownLess(speaker.label),
                        ) { rows.knownExpanded.remove(speaker.label) }
                    }
                }
            }
        }
    }

    /// Known speakers minus participants (avoids duplicate chips when a known
    /// speaker is also a meeting participant).
    private var knownNamesNotInParticipants: [String] {
        let participantSet = Set(data.participants)
        return knownSpeakerNames.filter { !participantSet.contains($0) }
    }

    private func chipRow(
        names: [String], idPrefix: String, onSelect: @escaping (String) -> Void,
    ) -> some View {
        ChipFlowLayout(spacing: 4) {
            ForEach(names, id: \.self) { name in
                chipButton(label: name, identifier: "\(idPrefix)\(name)") { onSelect(name) }
            }
        }
    }

    private func chipButton(
        label: String, identifier: String, action: @escaping () -> Void,
    ) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption)
            .accessibilityIdentifier(identifier)
    }

    private func chipMoreButton(
        label: String, identifier: String, action: @escaping () -> Void,
    ) -> some View {
        Button(label, action: action)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption)
            .accessibilityIdentifier(identifier)
    }

    /// Play the longest temporally-pure segment of a speaker from the audio file.
    private func playSpeakerSnippet(label: String) {
        // Stop if already playing this speaker
        if playingLabel == label {
            player?.stop()
            player = nil
            playingLabel = nil
            return
        }

        // Pick the longest pure segment to avoid cross-voice contamination,
        // and play it from the speaker's own track where there is one.
        guard let chosen = Self.selectSampleSegment(for: label, in: data.segments),
              let source = data.sampleSource(for: chosen) else { return }

        // Perform file I/O off the main thread
        Task.detached { [source, balanceSampleLevels] in
            do {
                let (samples, sampleRate) = try await AudioMixer.loadAudioAsFloat32(url: source.url)
                guard let range = Self.sampleRange(
                    start: source.start,
                    end: source.end,
                    sampleRate: sampleRate,
                    totalSamples: samples.count,
                ) else { return }

                let snippet = Self.playbackSnippet(
                    of: samples, range: range, sampleRate: sampleRate, balanced: balanceSampleLevels,
                )
                let tmpPath = FileManager.default.temporaryDirectory
                    .appendingPathComponent("speaker_\(label).wav")
                try AudioMixer.saveWAV(samples: snippet, sampleRate: sampleRate, url: tmpPath)

                let newPlayer = try AVAudioPlayer(contentsOf: tmpPath)
                let duration = newPlayer.duration

                await MainActor.run {
                    player?.stop()
                    player = newPlayer
                    player?.play()
                    playingLabel = label
                }

                // Reset icon when done
                try? await Task.sleep(for: .seconds(duration + 0.1))
                await MainActor.run {
                    if playingLabel == label {
                        playingLabel = nil
                    }
                }
            } catch {
                // Silently fail — playback is best-effort
            }
        }
    }

    /// Picks the longest-duration segment attributed to `label` so the
    /// playback snippet is the speaker's most representative sample.
    /// Returns nil when the speaker has no segments. Pure for testability —
    /// `playSpeakerSnippet`'s detached I/O path stays unchanged.
    static func longestSegment(
        forSpeaker label: String,
        in segments: [PipelineQueue.SpeakerNamingData.Segment],
    ) -> PipelineQueue.SpeakerNamingData.Segment? {
        segments
            .filter { $0.speaker == label }
            .max { ($0.end - $0.start) < ($1.end - $1.start) }
    }

    private func confirm() {
        player?.stop()
        let mapping = Self.buildSpeakerMapping(speakers: speakers, names: rows.names)
        onComplete(.confirmed(mapping))
    }

    // MARK: - Pure Functions (testable without UI)

    /// Maps a [start, end] time range (seconds) to a clamped half-open sample range,
    /// rounding down to whole samples. Returns `nil` when the resulting range is
    /// empty (start >= end after clamping/conversion). Multiplies before truncation
    /// so fractional starts (e.g. 1.7s) preserve precision; the previous inline code
    /// did `Int(start) * sampleRate`, which discarded the sub-second offset and shifted
    /// playback by up to ~1s into a different speaker.
    nonisolated static func sampleRange(
        start: TimeInterval,
        end: TimeInterval,
        sampleRate: Int,
        totalSamples: Int,
    ) -> Range<Int>? {
        let startSample = max(0, Int(start * Double(sampleRate)))
        let endSample = min(totalSamples, Int(end * Double(sampleRate)))
        guard startSample < endSample else { return nil }
        return startSample ..< endSample
    }

    /// The samples to play for `range` of a decoded file at `sampleRate`.
    /// With `balanced`, the cut is brought to `LevelBalance.targetDBFS`
    /// speech level on its own, under the same boost cap and clip rules as the
    /// mix, so an own-voice and a far-end sample play at a similar loudness.
    /// Its speech level is measured on the cut alone rather than given its
    /// track's gain, because a microphone track on loudspeakers carries the far
    /// end too; which frames count as speech is judged against the noise floor
    /// of the whole file, because the cut can be speech from start to end. A
    /// cut with less than `LevelBalance.sampleMinimumSpeechSeconds` of
    /// measurable speech plays as it is.
    nonisolated static func playbackSnippet(
        of samples: [Float],
        range: Range<Int>,
        sampleRate: Int,
        balanced: Bool,
    ) -> [Float] {
        var snippet = Array(samples[range])
        if balanced {
            _ = LevelBalance.balance(
                &snippet, sampleRate: sampleRate, minimumSpeechSeconds: LevelBalance.sampleMinimumSpeechSeconds,
                noiseReference: samples,
            )
        }
        return snippet
    }

    /// Picks the longest temporally-pure segment for `label`, falling back to
    /// `longestSegment` when no pure segment ≥ `minDuration` exists. A segment is
    /// "pure" when no other speaker has any segment overlapping the window
    /// `[c.start - purityWindow, c.end + purityWindow]`. Used to avoid
    /// cross-voice contamination in the speaker-naming dialog playback.
    static func selectSampleSegment(
        for label: String,
        in segments: [PipelineQueue.SpeakerNamingData.Segment],
        minDuration: TimeInterval = 1.5,
        purityWindow: TimeInterval = 0.5,
    ) -> PipelineQueue.SpeakerNamingData.Segment? {
        let own = segments.filter { $0.speaker == label }
        guard !own.isEmpty else { return nil }
        let others = segments.filter { $0.speaker != label }
        let pure = own
            .filter { c in
                (c.end - c.start) >= minDuration
                    && !others.contains { $0.start < c.end + purityWindow && c.start - purityWindow < $0.end }
            }
            .max { ($0.end - $0.start) < ($1.end - $1.start) }
        return pure ?? longestSegment(forSpeaker: label, in: segments)
    }

    /// Computes the initial text field contents from the speaker auto-name
    /// mappings, keyed by speaker label. Labels are `data.mapping`'s keys and so
    /// unique by construction; first wins rather than trapping if that changes.
    static func computeInitialNames(
        speakers: [(label: String, autoName: String?, speakingTime: Double)],
    ) -> [String: String] {
        Dictionary(speakers.map { ($0.label, $0.autoName ?? "") }) { first, _ in first }
    }

    /// Filter names against the user's current input. Empty query → unchanged.
    /// Non-empty → prefix-of-any-token matches first, then contains-substring,
    /// both case-insensitive, stable within each tier.
    static func filterByQuery(names: [String], query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return names }
        let needle = trimmed.lowercased()
        var prefix: [String] = []
        var contains: [String] = []
        for name in names {
            let lower = name.lowercased()
            if lower.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
                prefix.append(name)
            } else if lower.contains(needle) {
                contains.append(name)
            }
        }
        return prefix + contains
    }

    private enum NameRelevance: Int, Comparable {
        case autoNameMatch = 0
        case participantMatch = 1
        case other = 2
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Sort known names by relevance for the "Known:" chips:
    /// 1. First-token matches the auto-name (case-insensitive).
    /// 2. First-token matches a meeting participant.
    /// 3. Remaining names in input order.
    /// Stable within each tier.
    static func rankedKnownNames(
        known: [String], autoName: String?, participants: [String],
    ) -> [String] {
        let autoToken = (autoName.map(firstToken) ?? "").lowercased()
        let participantTokens = Set(
            participants.map { firstToken($0).lowercased() }.filter { !$0.isEmpty },
        )

        func relevance(of name: String) -> NameRelevance {
            let token = firstToken(name).lowercased()
            if !autoToken.isEmpty, token == autoToken { return .autoNameMatch }
            if participantTokens.contains(token) { return .participantMatch }
            return .other
        }

        return known.enumerated()
            .map { (offset: $0.offset, relevance: relevance(of: $0.element), name: $0.element) }
            .sorted { lhs, rhs in
                if lhs.relevance != rhs.relevance { return lhs.relevance < rhs.relevance }
                return lhs.offset < rhs.offset
            }
            .map(\.name)
    }

    private static func firstToken(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// Builds the speaker label → user-entered name mapping, skipping empty names
    /// and speakers with no entry in `names`.
    static func buildSpeakerMapping(
        speakers: [(label: String, autoName: String?, speakingTime: Double)],
        names: [String: String],
    ) -> [String: String] {
        var mapping: [String: String] = [:]
        for speaker in speakers {
            let name = (names[speaker.label] ?? "").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                mapping[speaker.label] = name
            }
        }
        return mapping
    }
}

/// Layout that arranges its children left-to-right and wraps to a new row when
/// the row width is exhausted. Used for the suggestion-chip rows in
/// `SpeakerNamingView`, where a fixed-width HStack would either overflow or
/// truncate button labels when the speaker DB grows large.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 4

    /// Subview intrinsic sizes are cached so `sizeThatFits` and
    /// `placeSubviews` don't each re-query every child per layout pass.
    typealias Cache = [CGSize]

    func makeCache(subviews: Subviews) -> Cache {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache: inout Cache) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        return Self.computeLayout(
            sizes: cache, containerWidth: containerWidth, spacing: spacing,
        ).totalSize
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = Self.computeLayout(
            sizes: cache, containerWidth: bounds.width, spacing: spacing,
        )
        for (index, sv) in subviews.enumerated() {
            let pos = result.positions[index]
            sv.place(
                at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y),
                proposal: ProposedViewSize(cache[index]),
            )
        }
    }

    /// Pure layout calculation — extracted so the wrapping logic can be
    /// covered by unit tests without a SwiftUI host.
    static func computeLayout(
        sizes: [CGSize], containerWidth: CGFloat, spacing: CGFloat,
    ) -> (totalSize: CGSize, positions: [CGPoint]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        var positions: [CGPoint] = []
        positions.reserveCapacity(sizes.count)

        for size in sizes {
            if x > 0, x + size.width > containerWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        // Report the actual content width (capped at the container) so unconstrained
        // parents (proposal == .infinity) don't get an infinite frame.
        let width = sizes.isEmpty ? 0 : min(maxWidth, containerWidth)
        let height = sizes.isEmpty ? 0 : y + rowHeight
        return (totalSize: CGSize(width: width, height: height), positions: positions)
    }
}
