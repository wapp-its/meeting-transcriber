import Observation
import SwiftUI

/// The meeting the Identify Speakers Again sheet is open for, the method and count
/// picked in it, and why its last click queued nothing. A reference type, so a view
/// test reads back what a control wrote (docs/architecture/gui-testing.md, rung 2).
@Observable
@MainActor
final class IdentifySpeakersAgainSheetState {
    /// Bound to the sheet; nil closes it.
    var meeting: RerunSheetText.Meeting?
    var method: DiarizerMode = .offline
    var count = 2
    /// Shown in red above the buttons (A18, A27); nil until a click is refused.
    private(set) var refusal: RerunRefusal?

    /// Opens at Settings' method and expected speakers (D7).
    func open(_ meeting: RerunSheetText.Meeting, settings: RerunSheetText.Settings) {
        refusal = nil
        method = settings.diarizerMode
        count = RerunSheetText.IdentifySpeakersAgain.startingCount(settings.numSpeakers)
        self.meeting = meeting
    }

    func close() {
        meeting = nil
        refusal = nil
    }

    /// A queued re-run closes the sheet. A refused one keeps it open with its line,
    /// and the next click asks again.
    func confirm(_ identifySpeakersAgain: (UUID, RerunSpeakers) -> RerunAdmission) {
        guard let meeting else { return }
        switch identifySpeakersAgain(meeting.id, RerunSpeakers(method: method, count: count)) {
        case .queued: close()
        case let .refused(reason): refusal = reason
        }
    }
}

/// The All Recordings window's Identify Speakers Again sheet (spec R9, D7): the
/// meeting, the speaker method and count in one box, what happens, then Cancel and
/// "Identify Speakers". Its texts come from `RerunSheetText.IdentifySpeakersAgain`.
/// It shows the meeting's title, so it stays off the `/screenshot`, `/ui/tree` and
/// `/ui/press` allowlists, as the window it is shown over does.
struct IdentifySpeakersAgainSheet: View {
    private typealias Words = RerunSheetText.IdentifySpeakersAgain

    let meeting: RerunSheetText.Meeting
    let state: IdentifySpeakersAgainSheetState
    /// Read on every redraw, so the lines follow Settings' notes now.
    let settings: () -> RerunSheetText.Settings
    let identifySpeakersAgain: (UUID, RerunSpeakers) -> RerunAdmission

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Words.title)
                    .font(.headline)
                Text(RerunSheetText.meetingLine(meeting))
                    .foregroundStyle(.secondary)
            }
            methodBox
            whatHappens(Words.whatHappens(settings(), meeting: meeting))
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

    /// One white box headed "Speaker method": the methods as Settings lists them, and
    /// under them, indented to the names, the count or the method's hint (A17).
    private var methodBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Words.methodHeading)
                .foregroundStyle(.secondary)
            Picker(Words.methodHeading, selection: Bindable(state).method) {
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
            .labelsHidden()
            .accessibilityIdentifier(A11yID.identifySpeakersAgainMethodPicker)
            underTheList(Words.underTheList(state.method, twoTracks: meeting.twoTracks))
                .padding(.leading, 20)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder
    private func underTheList(_ under: Words.UnderTheList) -> some View {
        switch under {
        case let .count(note):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(Words.countLabel)
                    Text("\(state.count)")
                        .monospacedDigit()
                    Stepper("", value: Bindable(state).count, in: SpeakerNamingView.rerunCountRange)
                        .labelsHidden()
                        .accessibilityIdentifier(A11yID.identifySpeakersAgainCountStepper)
                }
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case let .hint(hint):
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func whatHappens(_ lines: [Words.Line]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RerunSheetText.whatHappensHeading)
                .bold()
            ForEach(lines, id: \.text) { line in
                Text(line.text)
                    .foregroundStyle(line.isWarning ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { state.close() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(A11yID.identifySpeakersAgainCancelButton)
            Button(Words.actionButton) { state.confirm(identifySpeakersAgain) }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(A11yID.identifySpeakersAgainConfirmButton)
        }
    }
}

extension View {
    /// The Identify Speakers Again sheet over the window, open while `state` holds a
    /// meeting: the item of that meeting's row opened it.
    func identifySpeakersAgainSheet(_ state: IdentifySpeakersAgainSheetState, actions: AllRecordingsActions) -> some View {
        sheet(item: Bindable(state).meeting) { meeting in
            IdentifySpeakersAgainSheet(
                meeting: meeting, state: state, settings: actions.rerunSettings, identifySpeakersAgain: actions.identifySpeakersAgain,
            )
        }
    }
}
