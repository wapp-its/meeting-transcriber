import Observation
import SwiftUI

/// What the Record Meeting window holds while it is open. A reference type so
/// a view test presets the options and reads back what a refused answer left
/// (CLAUDE.md, GUI Testing, rung 2).
@Observable
@MainActor
final class ConsentOptionsDraft {
    let protocolOptions: ProtocolOptionsDraft
    /// Record found the question no longer open.
    var questionClosed = false

    init(protocolOptions: ProtocolOptionsDraft = ProtocolOptionsDraft()) {
        self.protocolOptions = protocolOptions
    }

    /// How every question starts: the default template, no background.
    func reset(to template: ProtocolTemplateID) {
        protocolOptions.reset(to: template)
        questionClosed = false
    }
}

/// "Record with Options…" on the open "Record <App> meeting?" prompt: the
/// prompt's own question, with the template and background info for that
/// recording's protocol. Record answers the prompt the way the menu's Record
/// does. Shows background text, so it stays off the `/screenshot`, `/ui/tree`
/// and `/ui/press` allowlists.
@MainActor
struct ConsentOptionsView: View {
    static let windowID = "record-meeting-options"
    static let noLongerOpen = "This question is no longer open, so nothing was recorded."
    static let noQuestion = "No recording prompt is open."

    /// The question the window was opened for. Nil only when macOS restored
    /// the window at launch, before any prompt.
    let question: ConsentQuestion?
    /// Read when the window opens, so templates added in Finder since are listed.
    let optionsContext: () -> ProtocolOptionsContext
    /// Answers `question` as Record with the options; false when it is no
    /// longer the open prompt.
    let onRecord: (ConsentQuestion, MeetingProtocolOptions) -> Bool
    let onClose: () -> Void

    @State private var openedContext: ProtocolOptionsContext?
    @State private var draft: ConsentOptionsDraft

    init(
        question: ConsentQuestion?,
        optionsContext: @escaping () -> ProtocolOptionsContext,
        draft: ConsentOptionsDraft = ConsentOptionsDraft(),
        onRecord: @escaping (ConsentQuestion, MeetingProtocolOptions) -> Bool,
        onClose: @escaping () -> Void,
    ) {
        self.question = question
        self.optionsContext = optionsContext
        _draft = State(initialValue: draft)
        self.onRecord = onRecord
        self.onClose = onClose
    }

    private var context: ProtocolOptionsContext {
        openedContext ?? optionsContext()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            questionSection
            Divider()
            ProtocolOptionsForm(context: context, draft: draft.protocolOptions)
            if draft.questionClosed {
                Text(Self.noLongerOpen)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding()
        .frame(width: 440)
        .onAppear(perform: startOver)
        // Reopened from the menu for a newer prompt while still open: the
        // options belong to one question, so they start over with it.
        .onChange(of: question) { startOver() }
    }

    @ViewBuilder private var questionSection: some View {
        if let question {
            VStack(alignment: .leading, spacing: 2) {
                Text(question.title)
                    .font(.headline)
                Text(question.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(Self.noQuestion)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button("Cancel") {
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier(A11yID.consentOptionsCancelButton)

            Spacer()

            Button("Record") {
                guard let question else { return }
                if onRecord(question, draft.protocolOptions.options) {
                    onClose()
                } else {
                    draft.questionClosed = true
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(question == nil)
            .accessibilityIdentifier(A11yID.consentOptionsRecordButton)
        }
    }

    private func startOver() {
        let opened = optionsContext()
        openedContext = opened
        draft.reset(to: opened.defaultTemplate)
    }
}
