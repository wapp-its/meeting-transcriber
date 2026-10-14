import Foundation

/// Whether the Mac's sound output keeps a meeting's audio out of the
/// recording, and what the app says about it.
///
/// Microsoft Teams can make its own virtual device, "Microsoft Teams Audio",
/// the Mac's default output while it plays the call through another device.
/// The app-audio tap follows the default output, so with that routing the app
/// track records digital silence for the whole meeting, and the user learns
/// it only afterwards. The warning comes when it can still be fixed: at the
/// start of the recording, or when the routing changes during it.
///
/// Matched on the device UID, never on the display name: the name is
/// localisable, the UID is the driver's identity. Any other virtual output is
/// not a fault and never warns.
enum OutputRoutingWarning {
    /// The Microsoft Teams loopback driver's device UID.
    static let teamsLoopbackUID = "MSLoopbackDriverDevice_UID"
    /// What the warning calls the device when Core Audio gives no name.
    static let teamsDeviceName = "Microsoft Teams Audio"

    static let notificationTitle = "Meeting Audio May Not Be Recorded"
    /// The Output entry's disabled line while the routing holds.
    static let menuHint = "Meeting audio may not be recorded. Choose your speakers or headset."

    /// What made the app look at the routing, named in the log line.
    enum Trigger: String {
        case start
        case outputChange = "output change"
    }

    /// One reading's verdict, and the memory the recording keeps for the next.
    struct Decision: Equatable {
        let warn: Bool
        /// Whether this recording has warned for the routing it is on now.
        let warnedForCurrentRouting: Bool
    }

    static func isTeamsLoopback(_ uid: String?) -> Bool {
        uid == teamsLoopbackUID
    }

    /// Whether to warn now, from one reading of the default output's UID.
    ///
    /// - Parameters:
    ///   - uid: the default output's UID; nil when Core Audio does not answer,
    ///     which proves nothing either way, so it neither warns nor clears
    ///     the memory.
    ///   - capturesApp: whether the recording has an app track; without one
    ///     the routing cannot affect it.
    ///   - warnedForCurrentRouting: what the previous decision returned, false
    ///     at the start of a recording.
    static func decide(uid: String?, capturesApp: Bool, warnedForCurrentRouting: Bool) -> Decision {
        guard let uid else { return Decision(warn: false, warnedForCurrentRouting: warnedForCurrentRouting) }
        // Away from the Teams device: a later change back is a new routing.
        guard isTeamsLoopback(uid) else { return Decision(warn: false, warnedForCurrentRouting: false) }
        guard capturesApp, !warnedForCurrentRouting else {
            return Decision(warn: false, warnedForCurrentRouting: warnedForCurrentRouting)
        }
        return Decision(warn: true, warnedForCurrentRouting: true)
    }

    static func notificationBody(deviceName: String?) -> String {
        "\(deviceName ?? teamsDeviceName) is your Mac's sound output, so the meeting's audio may not reach the "
            + "recording. Choose your speakers or headset under Output in the menu bar menu, or in Control Center."
    }

    /// The unconditional diagnostics line for each warning. The UID is the
    /// Teams driver's fixed one, so it carries nothing personal.
    static func logLine(trigger: Trigger, uid: String) -> String {
        "Output routing: default output is \(uid) at \(trigger.rawValue); "
            + "the app track may record silence; warned the user"
    }
}
