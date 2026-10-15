import SwiftUI

/// The Microphone and Output entries: the two devices a recording depends on.
extension MenuBarView {
    /// Which microphone recordings use, switchable in a submenu; with "No
    /// Microphone" on, one disabled line. Every string comes from
    /// `MicrophoneMenuState`, so nothing is assembled here (see the note on
    /// `MenuBarView.body`).
    @ViewBuilder var microphoneSection: some View {
        if let microphoneMenu {
            if microphoneMenu.isEnabled {
                Menu {
                    microphonePicker(microphoneMenu)
                    if let hint = microphoneMenu.hint {
                        Text(hint)
                    }
                } label: {
                    Label(microphoneMenu.title, systemImage: "mic")
                }
            } else {
                Label(microphoneMenu.title, systemImage: "mic.slash")
            }
        }
    }

    /// An inline picker, so the menu shows each device as an item with the
    /// checkmark on the current choice. Choosing one only stores it; nothing
    /// here touches the macOS default input.
    private func microphonePicker(_ menu: MicrophoneMenuState) -> some View {
        Picker("Microphone", selection: Binding(get: { menu.checkedUID }, set: { onSelectMicrophone($0) })) {
            ForEach(menu.items, id: \.uid) { item in
                Text(item.label)
                    .disabled(!item.isEnabled)
                    .tag(item.uid)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .accessibilityIdentifier(A11yID.menuMicrophonePicker)
    }

    /// The Mac's sound output, switchable in a submenu; with no output found,
    /// one disabled line. Every string comes from `OutputMenuState`.
    @ViewBuilder var outputSection: some View {
        if let outputMenu {
            if outputMenu.isEnabled {
                Menu {
                    outputPicker(outputMenu)
                    if let hint = outputMenu.hint {
                        Text(hint)
                    }
                } label: {
                    Label(outputMenu.title, systemImage: outputMenu.warning ? "exclamationmark.triangle" : "speaker.wave.2")
                }
            } else {
                Label(outputMenu.title, systemImage: "speaker.slash")
            }
        }
    }

    /// An inline picker, like the microphone's. Unlike that one, choosing an
    /// item changes the Mac's default output, system-wide.
    private func outputPicker(_ menu: OutputMenuState) -> some View {
        Picker("Output", selection: Binding(get: { menu.checkedUID }, set: { onSelectOutput($0) })) {
            ForEach(menu.items, id: \.uid) { item in
                Text(item.label)
                    .disabled(!item.isEnabled)
                    .tag(item.uid)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .accessibilityIdentifier(A11yID.menuOutputPicker)
    }
}
