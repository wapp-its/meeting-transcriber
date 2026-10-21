import SwiftUI

/// The fields a device entry reads, which `MicrophoneMenuState` and
/// `OutputMenuState` both carry under these names.
protocol DeviceMenuState {
    associatedtype Item: DeviceMenuItem
    var title: String { get }
    var isEnabled: Bool { get }
    var items: [Item] { get }
    var checkedUID: String { get }
    var hint: String? { get }
}

/// One device in a device entry's picker.
protocol DeviceMenuItem {
    var uid: String { get }
    var label: String { get }
    var isEnabled: Bool { get }
}

extension MicrophoneMenuState: DeviceMenuState {}
extension MicrophoneMenuState.Item: DeviceMenuItem {}
extension OutputMenuState: DeviceMenuState {}
extension OutputMenuState.Item: DeviceMenuItem {}

/// The Microphone and Output entries: the two devices a recording depends on.
extension MenuBarView {
    /// Which microphone recordings use, switchable in a submenu; with "No
    /// Microphone" on, one disabled line. Choosing one only stores it; nothing
    /// here touches the macOS default input.
    var microphoneSection: some View {
        deviceSection(
            microphoneMenu, icons: (enabled: "mic", disabled: "mic.slash"),
            pickerLabel: "Microphone", pickerID: A11yID.menuMicrophonePicker, select: actions.selectMicrophone,
        )
    }

    /// The Mac's sound output, switchable in a submenu; with no output found,
    /// one disabled line. Unlike the microphone, choosing an item changes the
    /// Mac's default output, system-wide.
    var outputSection: some View {
        deviceSection(
            outputMenu, icons: (enabled: outputIcon, disabled: "speaker.slash"),
            pickerLabel: "Output", pickerID: A11yID.menuOutputPicker, select: actions.selectOutput,
        )
    }

    /// A warning triangle while the output's hint warns about its routing.
    private var outputIcon: String {
        outputMenu?.warning == true ? "exclamationmark.triangle" : "speaker.wave.2"
    }

    /// One device entry: a submenu holding an inline picker, so each device
    /// is an item with the checkmark on the current choice, and the hint
    /// line; or one disabled line. Every string comes from the menu state, so
    /// nothing is assembled here (see the note on `MenuBarView.body`).
    @ViewBuilder
    private func deviceSection(
        _ entry: (some DeviceMenuState)?, icons: (enabled: String, disabled: String),
        pickerLabel: LocalizedStringKey, pickerID: String, select: @escaping (String) -> Void,
    ) -> some View {
        if let entry {
            if entry.isEnabled {
                Menu {
                    devicePicker(entry, label: pickerLabel, id: pickerID, select: select)
                    if let hint = entry.hint {
                        Text(hint)
                    }
                } label: {
                    Label(entry.title, systemImage: icons.enabled)
                }
            } else {
                Label(entry.title, systemImage: icons.disabled)
            }
        }
    }

    private func devicePicker(
        _ entry: some DeviceMenuState, label: LocalizedStringKey, id: String, select: @escaping (String) -> Void,
    ) -> some View {
        Picker(label, selection: Binding(get: { entry.checkedUID }, set: { select($0) })) {
            ForEach(entry.items, id: \.uid) { item in
                Text(item.label)
                    .disabled(!item.isEnabled)
                    .tag(item.uid)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .accessibilityIdentifier(id)
    }
}
