// swiftlint:disable:this file_name
//
// The file holds the settings of the two command-line providers, Codex CLI
// and the custom command; neither view alone names it.

#if !APPSTORE

    import AppKit
    import SwiftUI

    /// Settings → Output for the Codex CLI provider. Notes only: the preset
    /// has no settings of its own.
    struct CodexProviderSettingsView: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Runs codex exec with your Codex login.")
                Text("The model and reasoning effort come from Codex's own configuration.")
                Text("Codex is started with --ephemeral, so it keeps no session of the run.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(A11yID.codexProviderNote)
        }
    }

    /// Settings → Output for the custom command: the command, one argument
    /// per line, the value of `{model}`, and how the placeholders work.
    struct CustomCommandSettingsView: View {
        @Bindable var settings: AppSettings

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Command")
                CommandArgumentsEditor(text: $settings.customCommandText)
                    .frame(minHeight: 72)
                    .accessibilityIdentifier(A11yID.customCommandEditor)
                Text("One argument per line, the program (a name or a full path) on the first. It runs directly, without a shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Model")
                Spacer()
                TextField("", text: $settings.customCommandModel)
                    .frame(width: 200)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(A11yID.customCommandModelField)
            }
            Text("Replaces {model}.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("{prompt_file}: a file with the instructions and the transcript")
                Text("{transcript_file}: a file with the transcript alone")
                Text("{output_file}: the file the command writes the protocol to")
                Text(
                    "Without {prompt_file} or {transcript_file}, the instructions and the transcript go to "
                        + "standard input. Without {output_file}, the protocol is read from standard output.",
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("What the command does with the transcript is up to the command.")
                .font(.caption)
        }
    }

    /// A plain-text editor for the command. `TextEditor` keeps the system's
    /// smart quotes, smart dashes and text replacement, which turn a typed
    /// `--model` into `—model`, so the program would receive an argument the
    /// user did not type; this `NSTextView` has them off.
    struct CommandArgumentsEditor: NSViewRepresentable {
        @Binding var text: String

        func makeCoordinator() -> Coordinator {
            Coordinator(text: $text)
        }

        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSTextView.scrollableTextView()
            if let textView = scrollView.documentView as? NSTextView {
                textView.isRichText = false
                textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                textView.isAutomaticQuoteSubstitutionEnabled = false
                textView.isAutomaticDashSubstitutionEnabled = false
                textView.isAutomaticTextReplacementEnabled = false
                textView.isAutomaticSpellingCorrectionEnabled = false
                textView.isContinuousSpellCheckingEnabled = false
                textView.smartInsertDeleteEnabled = false
                textView.allowsUndo = true
                textView.string = text
                textView.delegate = context.coordinator
            }
            return scrollView
        }

        func updateNSView(_ scrollView: NSScrollView, context: Context) {
            context.coordinator.text = $text
            if let textView = scrollView.documentView as? NSTextView, textView.string != text {
                textView.string = text
            }
        }

        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            var text: Binding<String>

            init(text: Binding<String>) {
                self.text = text
            }

            func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                text.wrappedValue = textView.string
            }
        }
    }

#endif
