// The prompt window's content (issue #99): each open question with its text
// as posted, its answers and a ✕, laid out as the accepted boards draw it.
// One small subview per question kind, so no body crosses the type-check
// budget.
import SwiftUI

/// What a click in the prompt window asks for. The controller decides what
/// follows (`PromptWindowController`).
enum PromptWindowAction: Equatable {
    case answerConsent(ConsentQuestion, ConsentAnswer)
    case answerMeetingEnd(MeetingEndQuestion, MeetingEndAnswer)
    /// ✕: hide the question; not an answer.
    case hide(PromptWindowItem.QuestionID)
}

struct PromptWindowView: View {
    static let width: CGFloat = 340

    let items: [PromptWindowItem]
    /// The moment the countdown's time left is counted from.
    let now: Date
    let perform: (PromptWindowAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider()
                }
                row(for: item)
                    .padding(14)
            }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // The panel is never key and the app is usually not active, and then
        // a `.borderedProminent` button draws like a plain one.
        .environment(\.controlActiveState, .key)
    }

    @ViewBuilder
    private func row(for item: PromptWindowItem) -> some View {
        switch item {
        case let .meetingEnd(question):
            MeetingEndPromptRow(
                question: question, showsTile: items.count == 1,
                timeLeft: PromptWindowContent.timeLeft(until: question.deadline, now: now), perform: perform,
            )

        case let .consent(question):
            ConsentPromptRow(question: question, showsTile: items.count == 1, perform: perform)
        }
    }
}

/// "Record <App> meeting?": the notification's three answers, right-aligned,
/// "Record" the prominent one, no keyboard shortcut.
private struct ConsentPromptRow: View {
    let question: ConsentQuestion
    let showsTile: Bool
    let perform: (PromptWindowAction) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            PromptRowText(
                title: question.title, message: question.body, showsTile: showsTile,
                hideID: A11yID.promptWindowHidePrompt,
            ) { perform(.hide(.consent(question.id))) }
            HStack(spacing: 8) {
                Button("Never for this app") { perform(.answerConsent(question, .never)) }
                    .accessibilityIdentifier(A11yID.promptWindowNever)
                Button("Ignore") { perform(.answerConsent(question, .declined)) }
                    .accessibilityIdentifier(A11yID.promptWindowIgnore)
                Button("Record") { perform(.answerConsent(question, .granted)) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(A11yID.promptWindowRecord)
            }
        }
    }
}

/// "Meeting seems to have ended": the time left on the left, then "Stop now"
/// and "Keep recording", the prominent one.
private struct MeetingEndPromptRow: View {
    let question: MeetingEndQuestion
    let showsTile: Bool
    let timeLeft: String
    let perform: (PromptWindowAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PromptRowText(
                title: question.title, message: question.body, showsTile: showsTile,
                hideID: A11yID.promptWindowHideCountdown,
            ) { perform(.hide(.meetingEnd(question.id))) }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("Ends in")
                    Text(timeLeft)
                        .bold()
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                Button("Stop now") { perform(.answerMeetingEnd(question, .stopNow)) }
                    .accessibilityIdentifier(A11yID.promptWindowStopNow)
                Button("Keep recording") { perform(.answerMeetingEnd(question, .keepRecording)) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(A11yID.promptWindowKeepRecording)
            }
        }
    }
}

/// A question's title in bold, its body as posted below it, the microphone
/// tile on the left while it is the only question, and ✕ at the top right.
private struct PromptRowText: View {
    let title: String
    let message: String
    let showsTile: Bool
    let hideID: String
    let hide: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsTile {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: hide) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide this question")
            .accessibilityIdentifier(hideID)
        }
    }
}
