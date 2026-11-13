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
    /// What the window says when a Trash confirmation stopped because it no longer
    /// named every file to move.
    var trashStopped: String?
}

/// The All Recordings window: every job the app knows, newest first, searched
/// by title and participant. Each row has the one main button its state calls
/// for and a "…" menu, which its right-click menu repeats, both decided by
/// `RecordingRowActions`, and says what happens to its audio, decided by
/// `RecordingAudioLine`. Several rows can be selected, and the right-click menu
/// over them moves their audio or the meetings to the Trash after one confirmation,
/// as `TrashSelectionPlan` decides. The footer counts the rows shown. Regenerating
/// a protocol happens in a sheet over the window, which `regenerateSheet` presents.
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
    @State private var selection: TranscriptionsSelection

    init(
        entries: [TranscriptionEntry],
        query: Binding<String>,
        actions: AllRecordingsActions,
        regenerateSheet: RegenerateSheetState,
        regenerationPhase: ProtocolRegenerator.Phase,
        selection: TranscriptionsSelection = TranscriptionsSelection(),
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
        _selection = State(initialValue: selection)
    }

    // Sections hoisted out of `body`, each type-checked on its own budget (see
    // the note on `MenuBarView.body`).
    var body: some View {
        VStack(spacing: 0) {
            fileMissingMessage
            listOrPlaceholder
            footer
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
        // The moments the rows' files are read again (see `RowAvailability`); a
        // regeneration that ended may have written a report.
        .onAppear { availability.refresh() }
        .onChange(of: entries) { availability.refresh() }
        .onChange(of: regenerationPhase) { availability.refresh() }
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
            refreshTarget: actions.readTargetAgain,
            onGenerate: actions.generate,
        ) { regenerateSheet.isPresented = false }
    }

    @ViewBuilder private var fileMissingMessage: some View {
        if notice.fileMissing { windowMessage("The file was moved or deleted.") }
        if let stopped = notice.trashStopped { windowMessage(stopped) }
    }

    private var shown: [TranscriptionEntry] {
        TranscriptionList.matching(entries, query: query.wrappedValue)
    }

    /// A `Set` selection makes the list multi-select, with Shift and Command built in.
    @ViewBuilder private var listOrPlaceholder: some View {
        let shown = shown
        if entries.isEmpty {
            placeholder("No transcriptions yet")
        } else if shown.isEmpty {
            placeholder("No transcriptions match")
        } else {
            List(selection: Bindable(selection).ids) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                    row(entry, index: index)
                        .tag(entry.id)
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in selectionMenu(for: ids) }
        }
    }

    /// The rows shown and their audio on disk, read through `availability` as the rows
    /// read it, so a redraw reads nothing again. A row without a record adds nothing.
    private var footer: some View {
        let shown = shown
        let bytes = shown.reduce(Int64(0)) { total, entry in
            let audio = availability.audioOnDisk(for: entry, record: actions.meetingFiles(entry.id), resolve: actions.audioOnDisk)
            return total + (audio?.bytes ?? 0)
        }
        let text = TranscriptionsFooter.text(
            shown: shown.count, selected: selection.entries(in: shown).count, audioBytes: bytes, retention: actions.retention(),
        )
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .accessibilityIdentifier(A11yID.transcriptionsFooter)
    }

    // MARK: - Row

    /// The "…" menu and the right-click menu of one row are one list by
    /// construction: both are built from the same `items`.
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
                audio: audio, retention: actions.retention(), retained: actions.retainedRecording(entry.id), now: Date(),
                calendar: .current,
                locale: .current,
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

    /// Keep is a toggle, which is what a menu shows with a check mark; the reports'
    /// heading is text, which a menu shows as an item that does nothing.
    @ViewBuilder
    private func menuEntry(_ item: RowMenuItem, entry: TranscriptionEntry, facts: RowFacts, index: Int) -> some View {
        switch item {
        case .item(.separator):
            Divider()

        case .item(.reportsHeading):
            Text(Self.title(of: item))
                .accessibilityIdentifier(Self.identifier(of: item, index: index))

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
        case .separator, .reportsHeading: break
        case let .report(report, _): open(report.url, with: actions.openProtocol)
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

// MARK: - Selection and Trash confirmations

extension TranscriptionsView {
    /// The right-click menu over `ids`, which SwiftUI hands in: the clicked row, or the
    /// selection when the click was on a selected row. Of one row shown, that row's own
    /// menu; of several, only the two Trash items, applied to all of them.
    @ViewBuilder
    func selectionMenu(for ids: Set<UUID>) -> some View {
        let rows = shown.enumerated().filter { ids.contains($0.element.id) }
        if rows.count == 1, let row = rows.first {
            rowMenu(row.element, facts: facts(for: row.element), index: row.offset)
        } else if rows.count > 1 {
            let selected = rows.map { TrashSelectionPlan.Selected(entry: $0.element, meeting: facts(for: $0.element).meeting) }
            selectionItem(.moveAudio, selected, title: Self.title(of: .moveAudioToTrash(enabled: true)), id: A11yID.recordingsSelectionMoveAudioToTrash)
            selectionItem(
                .moveMeeting, selected, title: Self.title(of: .moveMeetingToTrash(enabled: true)), id: A11yID.recordingsSelectionMoveMeetingToTrash,
            )
        }
    }

    private func selectionItem(
        _ action: TrashConfirmationPrompt.Action, _ selected: [TrashSelectionPlan.Selected], title: String, id: String,
    ) -> some View {
        let plan = TrashSelectionPlan(action: action, selected: selected, isRegenerating: isRegenerating)
        return Button(title) { askToMove(plan) }
            .disabled(!plan.isEnabled)
            .accessibilityIdentifier(id)
    }

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
        let reports = action == .moveMeeting ? actions.meetingReports(meeting.record) : []
        let text = switch action {
        case .moveAudio:
            TrashConfirmationText.moveAudio(
                meetingTitle: entry.title, record: meeting.record, audio: meeting.audio,
                transcriptSource: facts.onDisk.transcriptSource,
            )

        case .moveMeeting:
            TrashConfirmationText.moveMeeting(
                meetingTitle: entry.title, record: meeting.record, audio: meeting.audio,
                hasNotionPage: entry.hasNotionPage, hasFailedExport: entry.liveNotionExport == .failed, reports: reports,
            )
        }
        let named = TrashConfirmationText.files(of: action.kind, record: meeting.record, audio: meeting.audio).map(\.path) + reports
        notice.trashStopped = nil
        trashPrompt.request = .init(action: action, entries: [entry], text: text, named: [entry.id: Set(named)])
    }

    /// The same for a selection: one dialog for every meeting the plan applies to.
    private func askToMove(_ selected: TrashSelectionPlan) {
        var plan = selected
        if plan.action == .moveMeeting {
            plan.reports = Dictionary(plan.meetings.map { ($0.entry.id, actions.meetingReports($0.meeting.record)) }) { first, _ in first }
        }
        notice.trashStopped = nil
        trashPrompt.request = .init(
            action: plan.action, entries: plan.meetings.map(\.entry), text: .forSelection(plan), named: plan.named,
        )
    }

    @ViewBuilder
    private func trashButtons(_ request: TrashConfirmationPrompt.Request) -> some View {
        Button("Cancel", role: .cancel) { trashPrompt.request = nil }
            .accessibilityIdentifier(A11yID.recordingTrashCancelButton)
        Button(request.text.confirmButton, role: .destructive) { confirm(request) }
            .accessibilityIdentifier(A11yID.recordingTrashConfirmButton)
    }

    /// The action works out its files anew, and the disk or the other running build's
    /// record can have moved on since the dialog opened: a file back from where it was,
    /// or newly listed, would go without having been named. That stops here, for every
    /// meeting of the dialog, with the rows as they were, and choosing the item again
    /// names it. Fewer files than named is no harm. An earlier meeting's move takes time,
    /// during which a file of a later one can come back, so each after the first is asked
    /// again right before its own action, and the batch stops there; the action itself
    /// refuses a file it was not named, which stops it the same way. A meeting acted on
    /// leaves the selection, also one left as "Deletion incomplete".
    private func confirm(_ request: TrashConfirmationPrompt.Request) {
        actions.reloadMeetingFiles()
        let stillNamed = { (entry: TranscriptionEntry) in
            namesEveryFileToMove(of: entry, named: request.named[entry.id] ?? [], kind: request.action.kind)
        }
        if request.entries.allSatisfy(stillNamed) {
            var actedOn: [UUID] = []
            for entry in request.entries {
                guard actedOn.isEmpty || stillNamed(entry), move(entry, as: request) || stillNamed(entry) else {
                    notice.trashStopped = actedOn.isEmpty
                        ? TrashConfirmationText.nothingMoved(meetings: request.entries.count)
                        : TrashConfirmationText.stopped(after: actedOn.count, of: request.entries.count)
                    break
                }
                actedOn.append(entry.id)
            }
            selection.ids.subtract(actedOn)
        } else {
            notice.trashStopped = TrashConfirmationText.nothingMoved(meetings: request.entries.count)
        }
        availability.refresh()
        trashPrompt.request = nil
    }

    /// False when the action moved nothing. The record it read is then in the store.
    private func move(_ entry: TranscriptionEntry, as request: TrashConfirmationPrompt.Request) -> Bool {
        let named = request.named[entry.id] ?? []
        return switch request.action {
        case .moveAudio: actions.moveAudioToTrash(entry.id, named)
        case .moveMeeting: actions.moveMeetingToTrash(entry.id, named)
        }
    }

    /// Without a record the action refuses by itself. Move Meeting also has to have
    /// named each additional report there now.
    private func namesEveryFileToMove(of entry: TranscriptionEntry, named: Set<String>, kind: MeetingFileRecord.DeletionKind) -> Bool {
        guard let record = actions.meetingFiles(entry.id), let audio = actions.audioOnDisk(entry) else { return true }
        let reports = kind == .meetingToTrash ? actions.meetingReports(record) : []
        return named.isSuperset(of: TrashConfirmationText.files(of: kind, record: record, audio: audio).map(\.path) + reports)
    }
}
