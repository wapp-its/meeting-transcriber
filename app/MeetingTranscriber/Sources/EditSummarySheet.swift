import Observation
import SwiftUI

/// The meeting the Edit Summary sheet is open for and the field's text. A reference
/// type, so a view test reads back what a control wrote
/// (docs/architecture/gui-testing.md, rung 2).
@Observable
@MainActor
final class EditSummarySheetState {
    /// What the sheet shows of the meeting, taken when it opened.
    struct Meeting: Equatable, Identifiable {
        let id: UUID
        /// Title, date and length as the row shows them, joined with " · ".
        let line: String
        /// The summaries as the meeting had them when the sheet opened.
        let summaries: MeetingSummaries?
    }

    static let title = "Edit Summary"
    static let fromNotesLine = "Taken from the meeting notes. Once you change it, new notes for this meeting no longer replace it."
    static let typedLine = "You wrote this summary. New notes for this meeting do not replace it."
    static let tooLongLine = "At most \(MeetingSummary.maxLength) characters."

    /// Bound to the sheet; nil closes it.
    var meeting: Meeting?
    var text = ""

    func open(_ entry: TranscriptionEntry, summaries: MeetingSummaries?) {
        let date = entry.date?.formatted(date: .abbreviated, time: .shortened)
        let length = entry.audioDuration.map { formattedTime($0) }
        meeting = Meeting(id: entry.id, line: [entry.title, date, length].compactMap(\.self).joined(separator: " · "), summaries: summaries)
        text = summaries?.shown ?? ""
    }

    func close() {
        meeting = nil
        text = ""
    }

    /// The line under the field: why it is too long, else where the meeting's
    /// summary came from, nil for a meeting without one.
    var noteLine: String? {
        if isTooLong { return Self.tooLongLine }
        guard let summaries = meeting?.summaries else { return nil }
        if summaries.typed != nil { return Self.typedLine }
        return summaries.notes == nil ? nil : Self.fromNotesLine
    }

    var isTooLong: Bool {
        text.count > MeetingSummary.maxLength
    }

    var notesSummary: String? {
        meeting?.summaries?.notes?.text
    }

    /// Puts the notes summary the meeting had when the sheet opened into the field.
    func useNotesSummary() {
        if let notesSummary { text = notesSummary }
    }

    /// Stores the field's text through `save` and closes.
    func save(_ save: (UUID, String) -> Void) {
        guard let meeting, !isTooLong else { return }
        save(meeting.id, text)
        close()
    }
}

/// The All Recordings window's Edit Summary sheet (spec R4, D11): the heading, the
/// meeting's line, the field, the line under it, then "Use Summary from Notes" at
/// the left and Cancel and Save at the right. It shows the meeting's summary, so it
/// stays off the `/screenshot`, `/ui/tree` and `/ui/press` allowlists, as the window
/// it is shown over does.
struct EditSummarySheet: View {
    let meeting: EditSummarySheetState.Meeting
    @Bindable var state: EditSummarySheetState
    let save: (UUID, String) -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(EditSummarySheetState.title)
                    .font(.headline)
                Text(meeting.line)
                    .foregroundStyle(.secondary)
            }
            TextField("Summary", text: $state.text, axis: .vertical)
                .lineLimit(5, reservesSpace: true)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .accessibilityIdentifier(A11yID.editSummaryTextField)
            if let line = state.noteLine {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(A11yID.editSummaryNoteLine)
            }
            buttons
        }
        .padding()
        .frame(width: 440)
        .onAppear { fieldFocused = true }
    }

    private var buttons: some View {
        HStack {
            Button("Use Summary from Notes") { state.useNotesSummary() }
                .disabled(state.notesSummary == nil)
                .accessibilityIdentifier(A11yID.editSummaryUseNotesButton)
            Spacer()
            Button("Cancel") { state.close() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(A11yID.editSummaryCancelButton)
            Button("Save") { state.save(save) }
                .keyboardShortcut(.defaultAction)
                .disabled(state.isTooLong)
                .accessibilityIdentifier(A11yID.editSummarySaveButton)
        }
    }
}

extension View {
    /// The Edit Summary sheet over the All Recordings window, open while `state`
    /// holds a meeting.
    func editSummarySheet(_ state: EditSummarySheetState, save: @escaping (UUID, String) -> Void) -> some View {
        sheet(item: Bindable(state).meeting) { meeting in
            EditSummarySheet(meeting: meeting, state: state, save: save)
        }
    }
}
