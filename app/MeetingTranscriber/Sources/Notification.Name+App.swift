import Foundation

/// Names of the in-process notifications the menu bar scene in
/// `MeetingTranscriberApp.swift` observes: start watching at launch, bring the
/// speaker-naming window or Settings to the front, close Settings. The
/// pipeline, Settings and the debug RPC post them. Split out of that file to
/// keep it under the lint cap.
extension Notification.Name {
    static let autoWatchStart = Notification.Name("autoWatchStart")
    static let showSpeakerNaming = Notification.Name("showSpeakerNaming")
    static let showSettings = Notification.Name("showSettings")
    static let closeSettings = Notification.Name("closeSettings")
}
