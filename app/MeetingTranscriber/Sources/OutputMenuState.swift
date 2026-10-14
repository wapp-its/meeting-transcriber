import Foundation

/// What the menu bar's Output entry shows: its title, whether it opens a
/// submenu, the submenu's items with the checked one, and an optional hint
/// line. The same shape as `MicrophoneMenuState`, for the same reason: the
/// dropdown itself is manual QA, so every arm and every string lives here.
struct OutputMenuState: Equatable {
    /// One line of the submenu.
    struct Item: Equatable {
        /// What choosing it makes the Mac's default output.
        let uid: String
        let label: String
        /// False only for a current default output the Mac does not offer
        /// (the Teams device). The item is there so the checkmark has
        /// somewhere to sit.
        let isEnabled: Bool
    }

    let title: String
    /// False when no output device was found: the entry is then one disabled
    /// line with no submenu.
    let isEnabled: Bool
    let items: [Item]
    /// The item carrying the checkmark: the current default output, empty when
    /// it is unknown.
    let checkedUID: String
    /// A disabled line under the items, about the Teams routing.
    let hint: String?
    /// Whether the current routing may keep the meeting's audio out of the
    /// recording. The title carries the warning mark then.
    let warning: Bool

    /// - Parameters:
    ///   - devices: the outputs the Mac offers, in Core Audio's order.
    ///   - current: the Mac's default output; nil when Core Audio does not answer.
    static func resolve(devices: [OutputDevice], current: OutputDevice?) -> Self {
        if devices.isEmpty, current == nil {
            return Self(title: "Output: None available", isEnabled: false, items: [], checkedUID: "", hint: nil, warning: false)
        }
        var items = devices.map { Item(uid: $0.uid, label: $0.name, isEnabled: true) }
        if let current, !devices.contains(where: { $0.uid == current.uid }) {
            items.append(Item(uid: current.uid, label: current.name, isEnabled: false))
        }
        let warning = OutputRoutingWarning.isTeamsLoopback(current?.uid)
        let name = current?.name ?? "Unknown"
        return Self(
            title: warning ? "⚠️ Output: \(name)" : "Output: \(name)",
            isEnabled: true,
            items: items,
            checkedUID: current?.uid ?? "",
            hint: warning ? OutputRoutingWarning.menuHint : nil,
            warning: warning,
        )
    }
}
