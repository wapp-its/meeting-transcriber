import Foundation

/// The menu bar icon's countdown pulse. A single-member accessor like
/// `awaitingUserAnswer`: the menu-bar body reads this named member, so the
/// `watching.watchLoop?` chain resolves here and not inside its type-check
/// budget.
extension AppState {
    /// Whether a "meeting seems to have ended" countdown runs: the single
    /// input for the icon's pulse. The loop's open question id is set exactly
    /// while one runs (`WatchLoopMeetingEndDeadlineTests`). Derived from the
    /// loop alone, so the pulse shows whatever the notification settings.
    var meetingEndCountdownOverlay: Bool {
        watching.watchLoop?.meetingEndQuestionID != nil
    }
}
