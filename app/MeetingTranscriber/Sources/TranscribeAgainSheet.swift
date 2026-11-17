import Observation
import SwiftUI

/// The meeting the Transcribe Again sheet is open for, and why its last click
/// queued nothing. A reference type, so a view test reads back what a button
/// wrote (docs/architecture/gui-testing.md, rung 2).
@Observable
@MainActor
final class TranscribeAgainSheetState {
    /// Bound to the sheet; nil closes it.
    var meeting: RerunSheetText.Meeting?
    /// Shown in red above the buttons (A18, A27); nil until a click is refused.
    private(set) var refusal: RerunRefusal?

    func open(_ meeting: RerunSheetText.Meeting) {
        refusal = nil
        self.meeting = meeting
    }

    func close() {
        meeting = nil
        refusal = nil
    }

    /// A queued re-run closes the sheet. A refused one keeps it open with its line,
    /// and the next click asks again.
    func confirm(_ transcribeAgain: (UUID) -> RerunAdmission) {
        guard let meeting else { return }
        switch transcribeAgain(meeting.id) {
        case .queued: close()
        case let .refused(reason): refusal = reason
        }
    }
}

/// The All Recordings window's Transcribe Again sheet (spec R3, D6): the meeting,
/// what the re-run takes from Settings in one box, what happens, then Cancel and
/// "Transcribe Again". Its texts come from `RerunSheetText`. It shows the meeting's
/// title, so it stays off the `/screenshot`, `/ui/tree` and `/ui/press`
/// allowlists, as the window it is shown over does.
struct TranscribeAgainSheet: View {
    let meeting: RerunSheetText.Meeting
    let state: TranscribeAgainSheetState
    /// Read on every redraw, so the sheet shows what a click takes from Settings now.
    let settings: () -> RerunSheetText.Settings
    let transcribeAgain: (UUID) -> RerunAdmission

    var body: some View {
        let settings = settings()
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(RerunSheetText.title)
                    .font(.headline)
                Text(RerunSheetText.meetingLine(meeting))
                    .foregroundStyle(.secondary)
            }
            settingsBox(RerunSheetText.rows(settings, meeting: meeting))
            Text(RerunSheetText.fromSettings)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            whatHappens(RerunSheetText.whatHappens(settings, meeting: meeting))
            if let refusal = state.refusal {
                Text(RerunSheetText.refusal(refusal))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding()
        .frame(width: 440)
    }

    /// One white box, a row per setting, the label in grey and the value on the right.
    private func settingsBox(_ rows: [RerunSheetText.Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                HStack {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.value)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    private func whatHappens(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RerunSheetText.whatHappensHeading)
                .bold()
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { state.close() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(A11yID.transcribeAgainCancelButton)
            Button(RerunSheetText.actionButton) { state.confirm(transcribeAgain) }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(A11yID.transcribeAgainConfirmButton)
        }
    }
}
