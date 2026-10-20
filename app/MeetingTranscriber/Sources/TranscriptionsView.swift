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
}

/// The All Recordings window: every job the app knows, newest first, searched
/// by title and participant. Each row has the one main button its state calls
/// for and a "…" menu, which its right-click menu repeats, both decided by
/// `RecordingRowActions`.
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
    typealias FilesOnDisk = RecordingRowActions.FilesOnDisk

    nonisolated static let windowID = "transcriptions"

    let entries: [TranscriptionEntry]
    let query: Binding<String>
    let actions: AllRecordingsActions

    @State private var notice: TranscriptionsFileNotice
    @State private var availability: RowAvailability

    init(entries: [TranscriptionEntry], query: Binding<String>, actions: AllRecordingsActions) {
        self.entries = entries
        self.query = query
        self.actions = actions
        // Created here, not as the properties' defaults: SwiftUI defers creating
        // an `@Observable` default until the view is installed, so a view that
        // never is (one under test) would read a new object every time.
        _notice = State(initialValue: TranscriptionsFileNotice())
        _availability = State(initialValue: RowAvailability())
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
                Label("Open Protocols Folder", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityIdentifier(A11yID.recordingsOpenFolderButton)
            Button {
                actions.regenerate(nil)
            } label: {
                Label("Regenerate from File…", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityIdentifier(A11yID.recordingsRegenerateFromFileButton)
        }
    }

    @ViewBuilder private var fileMissingMessage: some View {
        if notice.fileMissing {
            Text("The file was moved or deleted.")
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
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
        let canRetry = actions.canRetry(entry.id)
        let onDisk = availability.filesOnDisk(for: entry, resolve: actions.filesOnDisk)
        let items = RecordingRowActions.menuItems(state: entry.state, onDisk: onDisk, canRetry: canRetry)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .fontWeight(.medium)
                Text(Self.detailLine(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(statusText(entry), systemImage: statusSymbol(entry))
                    .font(.caption)
                outcome(entry)
            }
            Spacer(minLength: 12)
            mainButton(entry, canRetry: canRetry, index: index)
            Menu {
                rowMenu(items, entry: entry, onDisk: onDisk, index: index)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(items.isEmpty)
            .accessibilityIdentifier(A11yID.recordingMoreButton(index))
        }
        .padding(.vertical, 4)
        .contextMenu { rowMenu(items, entry: entry, onDisk: onDisk, index: index) }
    }

    /// The line under a row's title: app, date and time, and duration, each
    /// "—" when the entry does not have it (a record written before the
    /// history kept it, or a duration not measured yet).
    static func detailLine(for entry: TranscriptionEntry) -> String {
        let missing = "—"
        let app = entry.appName ?? missing
        let date = entry.date?.formatted(date: .abbreviated, time: .shortened) ?? missing
        let duration = entry.audioDuration.map { formattedTime($0) } ?? missing
        return "\(app) · \(date) · \(duration)"
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
    private func mainButton(_ entry: TranscriptionEntry, canRetry: Bool, index: Int) -> some View {
        let recorded = RecordingRowActions.RecordedFiles(
            hasProtocol: entry.protocolURL != nil, hasTranscript: entry.transcriptURL != nil,
        )
        if let action = RecordingRowActions.mainAction(state: entry.state, files: recorded, canRetry: canRetry) {
            Button(Self.title(of: action)) { perform(action, on: entry) }
                .accessibilityIdentifier(A11yID.recordingMainButton(index))
        }
    }

    /// The row's "…" menu and its right-click menu, one builder for both.
    /// `onDisk` comes from `availability`, never from the disk: SwiftUI builds
    /// both menus on every redraw of the row.
    private func rowMenu(_ items: [MenuItem], entry: TranscriptionEntry, onDisk: FilesOnDisk, index: Int) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Button(Self.title(of: item)) { perform(item, on: entry, onDisk: onDisk) }
                .disabled(item == .regenerate(enabled: false))
                .accessibilityIdentifier(Self.identifier(of: item, index: index))
        }
    }

    private func perform(_ action: MainAction, on entry: TranscriptionEntry) {
        switch action {
        case .cancel: actions.cancel(entry.id)
        case .nameSpeakers: actions.nameSpeakers(entry.id)
        case .openProtocol: open(entry.protocolURL, with: actions.openProtocol)
        case .openTranscript: open(entry.transcriptURL, with: actions.openTranscript)
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
        case .showInFinder: open(onDisk.protocolExists ? entry.protocolURL : entry.transcriptURL, with: actions.reveal)
        case .regenerate: actions.regenerate(entry)
        case .retry: actions.retry(entry.id)
        case .remove: actions.remove(entry.id)
        case .dismiss: actions.dismiss(entry.id)
        }
        availability.refresh()
    }

    /// A file that is gone says so in the window, and the next action that
    /// finds its file takes the message away.
    private func open(_ url: URL?, with action: (URL) -> Bool) {
        guard let url else { return }
        notice.fileMissing = !action(url)
    }

    static func title(of action: MainAction) -> String {
        switch action {
        case .cancel: "Cancel"
        case .nameSpeakers: "Name Speakers"
        case .openProtocol: "Open Protocol"
        case .openTranscript: "Open Transcript"
        case .retry: "Retry"
        case .remove: "Remove"
        }
    }

    static func title(of item: MenuItem) -> String {
        switch item {
        case .openProtocol: "Open Protocol"
        case .openTranscript: "Open Transcript"
        case .showInFinder: "Show in Finder"
        case .regenerate: "Regenerate Protocol…"
        case .retry: "Retry"
        case .remove: "Remove"
        case .dismiss: "Dismiss"
        }
    }

    static func identifier(of item: MenuItem, index: Int) -> String {
        switch item {
        case .openProtocol: A11yID.recordingMenuOpenProtocol(index)
        case .openTranscript: A11yID.recordingMenuOpenTranscript(index)
        case .showInFinder: A11yID.recordingMenuShowInFinder(index)
        case .regenerate: A11yID.recordingMenuRegenerate(index)
        case .retry: A11yID.recordingMenuRetry(index)
        case .remove: A11yID.recordingMenuRemove(index)
        case .dismiss: A11yID.recordingMenuDismiss(index)
        }
    }
}
