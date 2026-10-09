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

/// The Transcriptions window: every job the app knows, newest first, searched
/// by title and participant, with the actions each entry allows.
///
/// Data and actions arrive as stored properties, the way `SettingsView` takes
/// them, so the view reads no app state of its own. The query is a binding for
/// the same reason: a test types into the field and reads what it wrote.
///
/// The window shows meeting titles and participants, so its scene id stays off
/// every debug RPC window allowlist, and its row identifiers carry the row's
/// index only.
struct TranscriptionsView: View {
    nonisolated static let windowID = "transcriptions"

    let entries: [TranscriptionEntry]
    let query: Binding<String>
    /// Whether the pipeline would accept a retry of this job now.
    let canRetry: (UUID) -> Bool
    /// Open and Show in Finder return false when the file is gone.
    let onOpen: (URL) -> Bool
    let onReveal: (URL) -> Bool
    let onRetry: (UUID) -> Void
    let onRemove: (UUID) -> Void

    @State private var notice: TranscriptionsFileNotice

    init(
        entries: [TranscriptionEntry],
        query: Binding<String>,
        canRetry: @escaping (UUID) -> Bool,
        onOpen: @escaping (URL) -> Bool,
        onReveal: @escaping (URL) -> Bool,
        onRetry: @escaping (UUID) -> Void,
        onRemove: @escaping (UUID) -> Void,
    ) {
        self.entries = entries
        self.query = query
        self.canRetry = canRetry
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onRetry = onRetry
        self.onRemove = onRemove
        // Created here, not as the property's default: SwiftUI defers creating
        // an `@Observable` default until the view is installed, so a view that
        // never is (one under test) would read a new object every time.
        _notice = State(initialValue: TranscriptionsFileNotice())
    }

    // Sections hoisted out of `body`, each type-checked on its own budget (see
    // the note on `MenuBarView.body`).
    var body: some View {
        VStack(spacing: 0) {
            searchField
            fileMissingMessage
            Divider()
            listOrPlaceholder
        }
        .frame(minWidth: 560, minHeight: 320)
    }

    // MARK: - Sections

    private var searchField: some View {
        TextField("Search titles and participants", text: query)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.transcriptionsSearchField)
            .padding()
    }

    @ViewBuilder private var fileMissingMessage: some View {
        if notice.fileMissing {
            Text("The file was moved or deleted.")
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 8)
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

    private func row(_ entry: TranscriptionEntry, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
            fileActions(entry, index: index)
            failureActions(entry, index: index)
        }
        .padding(.vertical, 4)
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

    /// Open and Show in Finder act on the protocol, else the transcript; an
    /// entry with neither has neither button.
    @ViewBuilder
    private func fileActions(_ entry: TranscriptionEntry, index: Int) -> some View {
        if let url = entry.fileToOpen {
            Button("Open") { notice.fileMissing = !onOpen(url) }
                .accessibilityIdentifier(A11yID.transcriptionOpenButton(index))
            Button("Show in Finder") { notice.fileMissing = !onReveal(url) }
                .accessibilityIdentifier(A11yID.transcriptionRevealButton(index))
        }
    }

    /// Retry where the pipeline would accept it now, and Remove, on a failed
    /// entry only.
    @ViewBuilder
    private func failureActions(_ entry: TranscriptionEntry, index: Int) -> some View {
        if entry.state == .error {
            if canRetry(entry.id) {
                Button("Retry") { onRetry(entry.id) }
                    .accessibilityIdentifier(A11yID.transcriptionRetryButton(index))
            }
            Button("Remove") { onRemove(entry.id) }
                .accessibilityIdentifier(A11yID.transcriptionRemoveButton(index))
        }
    }
}
