import AudioTapLib
import Foundation

/// What the menu bar's Microphone entry shows: its title, whether it opens a
/// submenu, the submenu's items with the checked one, and an optional hint line.
///
/// Decided here rather than in `MenuBarView` for the reason
/// `MicrophoneRecordingAvailability` gives: the dropdown itself is manual QA,
/// so every arm worth checking lives in this pure value. Every string the
/// entry shows is here too, so a wording change happens in one place.
struct MicrophoneMenuState: Equatable {
    /// One line of the submenu.
    struct Item: Equatable {
        /// What choosing it stores in `AppSettings.micDeviceUID`: empty for
        /// System Default.
        let uid: String
        let label: String
        /// False only for a stored choice whose device is not connected. The
        /// item is there so the checkmark has somewhere to sit.
        let isEnabled: Bool
    }

    let title: String
    /// False with "No Microphone (app audio only)" on: the entry is then one
    /// disabled line with no submenu.
    let isEnabled: Bool
    let items: [Item]
    /// The item carrying the checkmark: the stored choice, empty for System Default.
    let checkedUID: String
    /// A disabled line under the items, about the meeting app's microphone.
    let hint: String?

    /// - Parameters:
    ///   - selectedUID: `AppSettings.micDeviceUID`, empty for System Default.
    ///   - devices: the list Settings → Audio → Microphone shows, in its order.
    ///   - defaultInputName: the macOS default input's name, from Core Audio.
    ///   - recordedDevice: the device the running recording reports it
    ///     captures from; nil while nothing records the microphone.
    static func resolve(
        noMic: Bool,
        selectedUID: String,
        devices: [MicrophoneDevice],
        defaultInputName: String?,
        recordedDevice: MicInputDevice?,
        meetingAppHint: String? = nil,
    ) -> Self {
        if noMic {
            return Self(
                title: "Microphone: Off (app audio only)",
                isEnabled: false, items: [], checkedUID: selectedUID, hint: meetingAppHint,
            )
        }
        let systemDefault = systemDefaultLabel(defaultInputName)
        let chosen = devices.first { $0.uid == selectedUID }
        let chosenMissing = !selectedUID.isEmpty && chosen == nil

        var items = [Item(uid: "", label: systemDefault, isEnabled: true)]
        items += devices.map { Item(uid: $0.uid, label: $0.name, isEnabled: true) }
        if chosenMissing {
            items.append(Item(uid: selectedUID, label: "Selected microphone (not connected)", isEnabled: false))
        }

        let title = if let recordedName = recordedDevice?.name {
            Self.title(naming: recordedName, chosenMissing: chosenMissing)
        } else if devices.isEmpty, defaultInputName == nil {
            "Microphone: None available"
        } else {
            // Not connected falls back to the system default, which is what
            // the next recording opens.
            Self.title(naming: chosen?.name ?? systemDefault, chosenMissing: chosenMissing)
        }
        return Self(title: title, isEnabled: true, items: items, checkedUID: selectedUID, hint: meetingAppHint)
    }

    private static func systemDefaultLabel(_ defaultInputName: String?) -> String {
        guard let defaultInputName else { return "System Default" }
        return "System Default (\(defaultInputName))"
    }

    private static func title(naming device: String, chosenMissing: Bool) -> String {
        chosenMissing
            ? "Microphone: \(device) — selected microphone not connected"
            : "Microphone: \(device)"
    }
}
