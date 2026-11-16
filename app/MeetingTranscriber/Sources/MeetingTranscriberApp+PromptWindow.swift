import SwiftUI

extension MeetingTranscriberApp {
    /// Wires the prompt window below the menu bar icon (issue #99) into the
    /// menu bar label, next to the live captions panel: creates its controller
    /// once and renders it whenever the setting or an open question changes,
    /// at launch too. Kept out of `MeetingTranscriberApp.swift`, whose struct
    /// body is at its length limit; applied there with one `.modifier` line.
    struct PromptWindowWiring: ViewModifier {
        let appState: AppState
        @State private var controller: PromptWindowController?

        func body(content: Content) -> some View {
            content.onChange(of: appState.promptWindowInput, initial: true) {
                let controller = controller ?? PromptWindowController(
                    input: { appState.promptWindowInput },
                    answers: PromptWindowAnswers(
                        consent: { appState.answerConsentQuestion($0, answer: $1) },
                        meetingEnd: { appState.answerMeetingEndQuestion($0, answer: $1) },
                    ),
                )
                self.controller = controller
                controller.update()
            }
        }
    }
}
