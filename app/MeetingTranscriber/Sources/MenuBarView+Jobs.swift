import SwiftUI

/// The menu's job lines: the "In progress" and "Needs you" groups, one line
/// per job with its actions in a submenu.
extension MenuBarView {
    /// The jobs under way and the jobs waiting on the user, each group under
    /// its own header and only when it has a line. Row indexes run on across
    /// both groups and count only job rows, so every row's identifiers stay
    /// unique and "Name Speakers…" shifts none of them.
    @ViewBuilder var jobSections: some View {
        let sections = TranscriptionList.menuSections(transcriptionEntries)
        if !sections.inProgress.isEmpty {
            jobGroupHeader("In progress", systemImage: "gearshape.2.fill")
            jobRows(sections.inProgress, firstIndex: 0)
        }
        if !sections.needsYou.isEmpty || actions.nameSpeakers != nil {
            jobGroupHeader("Needs you", systemImage: "exclamationmark.circle")
            nameSpeakersItem
            jobRows(sections.needsYou, firstIndex: sections.inProgress.count)
        }
    }

    @ViewBuilder
    private func jobGroupHeader(_ title: String, systemImage: String) -> some View {
        Divider()
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func jobRows(_ entries: [TranscriptionEntry], firstIndex: Int) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
            jobRow(entry, index: firstIndex + offset)
        }
    }

    /// The first line of "Needs you" while a job waits for speaker names. A
    /// hidden item registers no shortcut, so ⌘N exists only while it shows.
    @ViewBuilder private var nameSpeakersItem: some View {
        if let nameSpeakers = actions.nameSpeakers {
            Button {
                nameSpeakers()
            } label: {
                Label("Name Speakers…", systemImage: "person.2.fill")
            }
            .keyboardShortcut("n")
            .accessibilityIdentifier(A11yID.nameSpeakersMenuItem)
        }
    }

    /// The same list as the All Recordings window, so the two cannot disagree
    /// about which jobs exist or what state they are in.
    var transcriptionEntries: [TranscriptionEntry] {
        TranscriptionList.entries(liveJobs: pipelineQueue.jobs, records: history)
    }

    // MARK: - Job lines

    /// One menu item per job, its actions in a submenu. A menu-style
    /// `MenuBarExtra` cannot lay anything out side by side: an `HStack` row
    /// came out as one menu item per part, so the status dot and the spacer
    /// became empty lines and the buttons stood one below the other.
    private func jobRow(_ entry: TranscriptionEntry, index: Int) -> some View {
        Menu {
            Text(entry.title)
            jobStateLabel(entry)
            Divider()
            jobActions(entry, index: index)
        } label: {
            Label(jobMenuTitle(entry), systemImage: jobSymbol(entry))
        }
    }

    /// Hoisted out of the `ViewBuilder` for the type-check budget (see the
    /// note on `body`).
    private func jobMenuTitle(_ entry: TranscriptionEntry) -> String {
        let status = JobMenuSummary.status(
            state: entry.state, hasWarnings: !entry.warnings.isEmpty, progress: stageProgress(entry),
        )
        return "\(entry.title) — \(status)"
    }

    private func jobSymbol(_ entry: TranscriptionEntry) -> String {
        JobMenuSummary.symbol(state: entry.state, hasWarnings: !entry.warnings.isEmpty)
    }

    /// A failed line is taken off for good by Remove; Dismiss is left to a
    /// job waiting for speaker names.
    @ViewBuilder
    private func jobActions(_ entry: TranscriptionEntry, index: Int) -> some View {
        if entry.state.isTerminal, let url = entry.fileToOpen {
            Button("Open") { actions.openProtocol(url) }
        }
        if entry.state == .speakerNamingPending {
            Button("Name Speakers") { actions.nameSpeakers?() }
        }
        if entry.state == .waiting || entry.state == .transcribing
            || entry.state == .diarizing || entry.state == .generatingProtocol {
            Button("Cancel") { pipelineQueue.cancelJob(id: entry.id) }
        }
        retryButton(entry, index: index)
        if entry.state == .error {
            Button("Remove") { actions.removeFailedJob(entry.id) }
                .accessibilityIdentifier(A11yID.jobRemoveButton(index))
        }
        if entry.state == .speakerNamingPending {
            Button("Dismiss") { actions.dismissJob(entry.id) }
        }
    }

    /// Runs a failed job again from its audio, instead of the user having to
    /// find the staged recording and import it by hand. A failed job known
    /// only from the history is not in the queue, so the queue refuses it
    /// until the pipeline has loaded it.
    @ViewBuilder
    private func retryButton(_ entry: TranscriptionEntry, index: Int) -> some View {
        if pipelineQueue.canRetryJob(id: entry.id) {
            Button("Retry") { pipelineQueue.retryJob(id: entry.id) }
                .accessibilityIdentifier(A11yID.jobRetryButton(index))
        }
    }

    private func jobStateLabel(_ entry: TranscriptionEntry) -> some View {
        Group {
            if [.transcribing, .diarizing, .generatingProtocol].contains(entry.state) {
                Text(stageProgress(entry))
                    .foregroundStyle(.secondary)
            } else if entry.state == .error, let msg = entry.error {
                Text(msg)
                    .foregroundStyle(.red)
            } else {
                Text(entry.state.label)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    /// The running stage's start and expected finish, read from the queue's
    /// clock for the job. Nothing here reads the time, so the line changes
    /// only when the clock does, at a job event.
    private func stageProgress(_ entry: TranscriptionEntry) -> String {
        JobMenuSummary.stageProgress(state: entry.state, clock: pipelineQueue.stageClock(forJobID: entry.id))
    }
}
