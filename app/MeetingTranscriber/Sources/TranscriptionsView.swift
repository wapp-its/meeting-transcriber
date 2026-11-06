import Observation
import SwiftUI

/// Whether the window's last Open or Show in Finder found its file gone.
///
/// A reference type held in `@State` rather than a `Bool`, so the write a
/// button makes lands in the object a test can read back, as with
/// `SpeakerNamingRowState` (CLAUDE.md, GUI Testing, rung 2).
@Observable
@MainActor
final class TranscriptionsFileNotice {
    var fileMissing = false
    /// A Trash confirmation stopped because it no longer named every file to move.
    var trashStopped = false
}

/// The Trash confirmation the window is showing, if any: which action, on which
/// meeting, in what words. A reference type for the reason on
/// `TranscriptionsFileNotice`.
@Observable
@MainActor
final class TrashConfirmationPrompt {
    enum Action {
        case moveAudio
        case moveMeeting

        var kind: MeetingFileRecord.DeletionKind {
            switch self {
            case .moveAudio: .audioToTrash
            case .moveMeeting: .meetingToTrash
            }
        }
    }

    struct Request {
        let action: Action
        let entry: TranscriptionEntry
        let text: TrashConfirmationText
        /// The paths the dialog names, which are all its confirmation answers for.
        let named: Set<String>
    }

    var request: Request?
}

/// The All Recordings window: every job the app knows, newest first, searched
/// by title and participant. Each row has the one main button its state calls
/// for and a "…" menu, which its right-click menu repeats, both decided by
/// `RecordingRowActions`, and says what happens to its audio, decided by
/// `RecordingAudioLine`. Regenerating a protocol happens in a sheet over the
/// window, which `regenerateSheet` presents.
///
/// Data and actions arrive as stored properties, the way `SettingsView` takes
/// them, so the view reads no app state of its own. The query is a binding for
/// the same reason: a test types into the field and reads what it wrote.
///
/// The window shows meeting titles and participants, so its scene id stays off
/// every debug RPC window allowlist, and its row identifiers carry the row's
/// index only.
struct TranscriptionsView: View {
    typealias MainAction = RecordingRowActions.MainAction
    typealias MenuItem = RecordingRowActions.MenuItem
    typealias RowMainAction = RecordingRowActions.RowMainAction
    typealias RowMenuItem = RecordingRowActions.RowMenuItem
    typealias FilesOnDisk = RecordingRowActions.FilesOnDisk

    /// What one row shows and offers, worked out once per draw, so its two menus and
    /// its button read the same answers.
    private struct RowFacts {
        let onDisk: FilesOnDisk
        let meeting: RecordingRowActions.Meeting?
        let audioLine: RecordingAudioLine
        let items: [RowMenuItem]
        let main: RowMainAction?
    }

    nonisolated static let windowID = "transcriptions"

    let entries: [TranscriptionEntry]
    let query: Binding<String>
    let actions: AllRecordingsActions
    let regenerateSheet: RegenerateSheetState
    /// The regenerator's state, which the sheet shows; a reopened sheet shows
    /// a run still going.
    let regenerationPhase: ProtocolRegenerator.Phase

    @State private var notice: TranscriptionsFileNotice
    @State private var availability: RowAvailability
    @State private var trashPrompt: TrashConfirmationPrompt

    init(
        entries: [TranscriptionEntry],
        query: Binding<String>,
        actions: AllRecordingsActions,
        regenerateSheet: RegenerateSheetState,
        regenerationPhase: ProtocolRegenerator.Phase,
    ) {
        self.entries = entries
        self.query = query
        self.actions = actions
        self.regenerateSheet = regenerateSheet
        self.regenerationPhase = regenerationPhase
        // Created here, not as the properties' defaults: SwiftUI defers creating
        // an `@Observable` default until the view is installed, so a view that
        // never is (one under test) would read a new object every time.
        _notice = State(initialValue: TranscriptionsFileNotice())
        _availability = State(initialValue: RowAvailability())
        _trashPrompt = State(initialValue: TrashConfirmationPrompt())
    }

    // Sections hoisted out of `body`, each type-checked on its own budget (see
    // the note on `MenuBarView.body`).
    var body: some View {
        VStack(spacing: 0) {
            fileMissingMessage
            listOrPlaceholder
        }
        .frame(minWidth: 560, minHeight: 320)
        .toolbar { toolbarItems }
        .sheet(isPresented: Bindable(regenerateSheet).isPresented) { regenerateForm }
        // `presenting`, so the buttons hold their request whether SwiftUI clears the
        // binding before or after running them.
        .alert(trashPrompt.request?.text.title ?? "", isPresented: trashPromptShown, presenting: trashPrompt.request) { request in
            trashButtons(request)
        } message: { request in
            Text(request.text.lines.joined(separator: "\n\n"))
        }
        // The moments the rows' files are read again (see `RowAvailability`).
        .onAppear { availability.refresh() }
        .onChange(of: entries) { availability.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow)?.identifier?.rawValue == Self.windowID { availability.refresh() }
        }
    }

    // MARK: - Sections

    /// The search, and the two actions that belong to no row: the folder the
    /// protocols are written to, and a protocol made again from a file chosen
    /// by hand, for a meeting the list does not hold. The two buttons show
    /// their names, which a toolbar would otherwise reduce to the icon.
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            TextField("Search titles and participants", text: query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .accessibilityIdentifier(A11yID.transcriptionsSearchField)
            Button {
                actions.openProtocolsFolder()
            } label: {
                Label("Open Notes Folder", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityIdentifier(A11yID.recordingsOpenFolderButton)
            Button {
                _ = actions.regenerate(nil)
            } label: {
                Label("Regenerate from File…", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityIdentifier(A11yID.recordingsRegenerateFromFileButton)
        }
    }

    /// The regenerate form, opened with what the presenter chose: a row's
    /// meeting, or none and "Choose File…". Cancel closes the sheet.
    private var regenerateForm: some View {
        RegenerateProtocolView(
            phase: regenerationPhase,
            templateChoices: actions.templateChoices,
            optionsUse: actions.optionsUse,
            initialTarget: regenerateSheet.initialTarget,
            allowsChooseFile: regenerateSheet.allowsChooseFile,
            chooseFile: actions.chooseFile,
            resolveFile: actions.resolveFile,
            onGenerate: actions.generate,
        ) { regenerateSheet.isPresented = false }
    }

    @ViewBuilder private var fileMissingMessage: some View {
        if notice.fileMissing { windowMessage("The file was moved or deleted.") }
        if notice.trashStopped {
            windowMessage("Nothing was moved: the meeting's files changed while the dialog was open. Choose the action again to see what it moves now.")
        }
    }

    private func windowMessage(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
    }

    @ViewBuilder private var listOrPlaceholder: some View {
        let shown = TranscriptionList.matching(entries, query: query.wrappedValue)
        if entries.isEmpty {
            placeholder("No transcriptions yet")
        } else if shown.isEmpty {
            placeholder("No transcriptions match")
        } else {
            List {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                    row(entry, index: index)
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row

    /// The "…" menu and the right-click menu are one list by construction:
    /// both are built from the same `items`.
    private func row(_ entry: TranscriptionEntry, index: Int) -> some View {
        let facts = facts(for: entry)
        return HStack(alignment: .top, spacing: 12) {
            rowText(entry, facts: facts, index: index)
            Spacer(minLength: 12)
            mainButton(entry, facts: facts, index: index)
            Menu {
                rowMenu(entry, facts: facts, index: index)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(facts.items.isEmpty)
            .accessibilityIdentifier(A11yID.recordingMoreButton(index))
        }
        .padding(.vertical, 4)
        .contextMenu { rowMenu(entry, facts: facts, index: index) }
    }

    /// The record comes from the store on every draw, so the row follows it while the
    /// window is open, and the disk only through `availability`, as SwiftUI builds both
    /// menus on every redraw. The queue's word on the job counts only while it lists
    /// the job: a history entry's state is what the job ended in.
    private func facts(for entry: TranscriptionEntry) -> RowFacts {
        let canRetry = actions.canRetry(entry.id)
        let onDisk = availability.filesOnDisk(for: entry, resolve: actions.filesOnDisk)
        let record = actions.meetingFiles(entry.id)
        let audio = availability.audioOnDisk(for: entry, record: record, resolve: actions.audioOnDisk)
        let exportRunning = entry.isLive && entry.liveNotionExport == .inProgress
        let meeting = record.flatMap { record in
            audio.map { RecordingRowActions.Meeting(record: record, notionExportRunning: exportRunning, audio: $0) }
        }
        let recorded = RecordingRowActions.RecordedFiles(
            hasProtocol: entry.protocolURL != nil, hasTranscript: entry.transcriptURL != nil,
            hasNotionPage: entry.notionPageURL != nil,
        )
        return RowFacts(
            onDisk: onDisk,
            meeting: meeting,
            audioLine: RecordingAudioLine.resolve(
                record: record,
                live: entry.isLive ? LiveMeetingState(state: entry.state, notionExportRunning: exportRunning) : nil,
                audio: audio, retention: actions.retention(), now: Date(), calendar: .current, locale: .current,
            ),
            items: RecordingRowActions.menuItems(
                state: entry.state, onDisk: onDisk, canRetry: canRetry, meeting: meeting,
                hasNotionPage: entry.notionPageURL != nil,
            ),
            main: RecordingRowActions.mainAction(state: entry.state, files: recorded, canRetry: canRetry, meeting: meeting),
        )
    }

    private func rowText(_ entry: TranscriptionEntry, facts: RowFacts, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .fontWeight(.medium)
                if facts.audioLine.showsKeepBadge { keepBadge(index: index) }
            }
            Text(Self.detailLine(for: entry))
                .font(.caption)
                .foregroundStyle(.secondary)
            statusLine(entry, facts: facts)
            outcome(entry)
            if let audioLine = facts.audioLine.text {
                Text(audioLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func keepBadge(index: Int) -> some View {
        Text("Keep")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(.secondary.opacity(0.5), lineWidth: 1))
            .accessibilityIdentifier(A11yID.recordingKeepBadge(index))
    }

    /// While a deletion is incomplete, why it stopped takes the status's place: that
    /// is what the row needs from the user, and a finished job has nothing to add.
    @ViewBuilder
    private func statusLine(_ entry: TranscriptionEntry, facts: RowFacts) -> some View {
        if let incomplete = facts.audioLine.incompleteText {
            Label(incomplete, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Label(statusText(entry), systemImage: statusSymbol(entry))
                .font(.caption)
        }
    }

    private func statusText(_ entry: TranscriptionEntry) -> String {
        JobMenuSummary.status(state: entry.state, hasWarnings: !entry.warnings.isEmpty, progress: entry.state.label)
    }

    private func statusSymbol(_ entry: TranscriptionEntry) -> String {
        JobMenuSummary.symbol(state: entry.state, hasWarnings: !entry.warnings.isEmpty)
    }

    /// Why a failed job failed, or what a finished one warned about.
    @ViewBuilder
    private func outcome(_ entry: TranscriptionEntry) -> some View {
        if entry.state == .error, let error = entry.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        } else if entry.state == .done, !entry.warnings.isEmpty {
            Text(entry.warnings.joined(separator: "; "))
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    /// Follows the files the job recorded, not the disk: a file gone since
    /// still gets its button, and the button says it was moved or deleted.
    @ViewBuilder
    private func mainButton(_ entry: TranscriptionEntry, facts: RowFacts, index: Int) -> some View {
        switch facts.main {
        case let .action(action):
            Button(Self.title(of: action)) { perform(action, on: entry) }
                .accessibilityIdentifier(A11yID.recordingMainButton(index))

        case .retryDeletion:
            Button("Retry Deletion") {
                actions.retryDeletion(entry.id)
                availability.refresh()
            }
            .disabled(isRegenerating && facts.meeting?.record.incomplete?.kind == .meetingToTrash)
            .accessibilityIdentifier(A11yID.recordingRetryDeletionButton(index))

        case nil:
            EmptyView()
        }
    }

    /// The row's "…" menu and its right-click menu, one builder for both.
    /// `facts.onDisk` comes from `availability`, never from the disk: SwiftUI builds
    /// both menus on every redraw of the row.
    private func rowMenu(_ entry: TranscriptionEntry, facts: RowFacts, index: Int) -> some View {
        ForEach(Array(facts.items.enumerated()), id: \.offset) { _, item in
            menuEntry(item, entry: entry, facts: facts, index: index)
        }
    }

    /// Keep is a toggle, which is what a menu shows with a check mark.
    @ViewBuilder
    private func menuEntry(_ item: RowMenuItem, entry: TranscriptionEntry, facts: RowFacts, index: Int) -> some View {
        switch item {
        case let .item(plain):
            menuButton(item, index: index) { perform(plain, on: entry, onDisk: facts.onDisk) }

        case let .keep(checked, _):
            Toggle(Self.title(of: item), isOn: keepBinding(entry, checked: checked))
                .disabled(!isEnabled(item))
                .accessibilityIdentifier(Self.identifier(of: item, index: index))

        case .moveAudioToTrash:
            menuButton(item, index: index) { askToMove(.moveAudio, entry, facts: facts) }

        case .moveMeetingToTrash:
            menuButton(item, index: index) { askToMove(.moveMeeting, entry, facts: facts) }
        }
    }

    private func menuButton(_ item: RowMenuItem, index: Int, action: @escaping () -> Void) -> some View {
        Button(Self.title(of: item), action: action)
            .disabled(!isEnabled(item))
            .accessibilityIdentifier(Self.identifier(of: item, index: index))
    }

    private func keepBinding(_ entry: TranscriptionEntry, checked: Bool) -> Binding<Bool> {
        Binding(
            get: { checked },
            set: { keep in
                actions.setKeep(entry.id, keep)
                availability.refresh()
            },
        )
    }

    /// A run writes its meeting's notes when it ends. Once a Move Meeting has taken
    /// the record, nothing lists that file and it stays behind, so what removes a whole
    /// meeting waits for the run. The regenerator does not say which meeting it is on.
    private var isRegenerating: Bool {
        regenerationPhase == .running
    }

    private func isEnabled(_ item: RowMenuItem) -> Bool {
        switch item {
        case let .item(plain): plain != .regenerate(enabled: false)
        case let .keep(_, enabled), let .moveAudioToTrash(enabled): enabled
        case let .moveMeetingToTrash(enabled): enabled && !isRegenerating
        }
    }

    // MARK: - Trash confirmations

    private var trashPromptShown: Binding<Bool> {
        Binding(
            get: { trashPrompt.request != nil },
            set: { shown in
                if !shown { trashPrompt.request = nil }
            },
        )
    }

    /// Only asks: what the dialog says comes from the row's record and what was
    /// last read for it, and nothing moves until it is confirmed.
    private func askToMove(_ action: TrashConfirmationPrompt.Action, _ entry: TranscriptionEntry, facts: RowFacts) {
        guard let meeting = facts.meeting else { return }
        let text = switch action {
        case .moveAudio:
            TrashConfirmationText.moveAudio(
                meetingTitle: entry.title, record: meeting.record, audio: meeting.audio,
                transcriptSource: facts.onDisk.transcriptSource,
            )

        case .moveMeeting:
            TrashConfirmationText.moveMeeting(
                meetingTitle: entry.title, record: meeting.record, audio: meeting.audio,
                hasNotionPage: entry.hasNotionPage, hasFailedExport: entry.liveNotionExport == .failed,
            )
        }
        let named = TrashConfirmationText.files(of: action.kind, record: meeting.record, audio: meeting.audio)
        notice.trashStopped = false
        trashPrompt.request = .init(action: action, entry: entry, text: text, named: Set(named.map(\.path)))
    }

    @ViewBuilder
    private func trashButtons(_ request: TrashConfirmationPrompt.Request) -> some View {
        Button("Cancel", role: .cancel) { trashPrompt.request = nil }
            .accessibilityIdentifier(A11yID.recordingTrashCancelButton)
        Button(request.text.confirmButton, role: .destructive) { confirm(request) }
            .accessibilityIdentifier(A11yID.recordingTrashConfirmButton)
    }

    /// The action works out its files anew, and the disk can have moved on since the
    /// dialog opened: a file back from where it was would go without having been named.
    /// That stops here, with the row as it was, and choosing the item again names it.
    /// Fewer files than named is no harm.
    private func confirm(_ request: TrashConfirmationPrompt.Request) {
        if namesEveryFileToMove(request) {
            switch request.action {
            case .moveAudio: actions.moveAudioToTrash(request.entry.id)
            case .moveMeeting: actions.moveMeetingToTrash(request.entry.id)
            }
        } else {
            notice.trashStopped = true
        }
        availability.refresh()
        trashPrompt.request = nil
    }

    /// Without a record the action refuses by itself.
    private func namesEveryFileToMove(_ request: TrashConfirmationPrompt.Request) -> Bool {
        guard let record = actions.meetingFiles(request.entry.id), let audio = actions.audioOnDisk(request.entry) else { return true }
        return request.named.isSuperset(of: TrashConfirmationText.files(of: request.action.kind, record: record, audio: audio).map(\.path))
    }

    // MARK: - Performing

    private func perform(_ action: MainAction, on entry: TranscriptionEntry) {
        switch action {
        case .cancel: actions.cancel(entry.id)
        case .nameSpeakers: actions.nameSpeakers(entry.id)
        case .openProtocol: open(entry.protocolURL, with: actions.openProtocol)
        case .openTranscript: open(entry.transcriptURL, with: actions.openTranscript)
        case .openInNotion: openInNotion(entry)
        case .retry: actions.retry(entry.id)
        case .remove: actions.remove(entry.id)
        }
        availability.refresh()
    }

    /// Show in Finder reveals the protocol, else the transcript, whichever
    /// was there when the menu was built.
    private func perform(_ item: MenuItem, on entry: TranscriptionEntry, onDisk: FilesOnDisk) {
        switch item {
        case .openProtocol: open(entry.protocolURL, with: actions.openProtocol)
        case .openTranscript: open(entry.transcriptURL, with: actions.openTranscript)
        case .openInNotion: openInNotion(entry)
        case .showInFinder: open(onDisk.protocolExists ? entry.protocolURL : entry.transcriptURL, with: actions.reveal)
        case .regenerate: notice.fileMissing = !actions.regenerate(entry)
        case .retry: actions.retry(entry.id)
        case .remove: actions.remove(entry.id)
        case .dismiss: actions.dismiss(entry.id)
        }
        availability.refresh()
    }

    /// A page is not a file, so nothing here can find it gone; the message
    /// of an earlier Open stays as it was.
    private func openInNotion(_ entry: TranscriptionEntry) {
        if let page = entry.notionPageURL { actions.openInNotion(page) }
    }

    /// A file that is gone says so in the window, and the next action that
    /// finds its file takes the message away.
    private func open(_ url: URL?, with action: (URL) -> Bool) {
        guard let url else { return }
        notice.fileMissing = !action(url)
    }
}
