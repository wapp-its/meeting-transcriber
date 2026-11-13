import Combine
import SwiftUI

// Split out of `MeetingTranscriberApp.swift`, which the fork's menu bar
// overlays (pause, watching, question, meeting-end countdown) took past the
// file length limit.

/// Renders the menu-bar icon and ticks the animation frame in its own
/// view body. Keeping the timer + frame @State scoped here means the
/// surrounding `MeetingTranscriberApp` scene body never re-evaluates on
/// each tick — only this view does. Without this isolation, animating
/// badges (recording, transcribing, …) would cascade re-renders through
/// every open Window.
struct AnimatedMenuBarIcon: View {
    let badge: BadgeKind
    let pausedOverlay: Bool
    let watchingOverlay: Bool
    let questionOverlay: Bool
    let meetingEndCountdownOverlay: Bool
    let permissionOverlay: Bool
    let recordOnlyOverlay: Bool
    let micSilentOverlay: Bool
    let appSilentOverlay: Bool

    @State private var animationFrame = 0
    // `.default` (not `.common`) so the timer never fires inside the status-bar
    // menu's tracking loop — see MenuBarIcon.animationRunLoopMode for why. Built
    // once per view value, as the plain timer was, and empty for a static
    // badge so an idle icon schedules no timer at all.
    private let iconTimer: AnyPublisher<Date, Never>

    init(
        badge: BadgeKind,
        pausedOverlay: Bool,
        watchingOverlay: Bool,
        questionOverlay: Bool,
        meetingEndCountdownOverlay: Bool,
        permissionOverlay: Bool,
        recordOnlyOverlay: Bool,
        micSilentOverlay: Bool,
        appSilentOverlay: Bool,
    ) {
        self.badge = badge
        self.pausedOverlay = pausedOverlay
        self.watchingOverlay = watchingOverlay
        self.questionOverlay = questionOverlay
        self.meetingEndCountdownOverlay = meetingEndCountdownOverlay
        self.permissionOverlay = permissionOverlay
        self.recordOnlyOverlay = recordOnlyOverlay
        self.micSilentOverlay = micSilentOverlay
        self.appSilentOverlay = appSilentOverlay
        iconTimer = MenuBarIcon.animationTicks(for: badge)
    }

    var body: some View {
        Image(nsImage: MenuBarIcon.image(
            badge: badge,
            animationFrame: animationFrame,
            pausedOverlay: pausedOverlay,
            watchingOverlay: watchingOverlay,
            questionOverlay: questionOverlay,
            meetingEndCountdownOverlay: meetingEndCountdownOverlay,
            permissionOverlay: permissionOverlay,
            recordOnlyOverlay: recordOnlyOverlay,
            micSilentOverlay: micSilentOverlay,
            appSilentOverlay: appSilentOverlay,
        ))
        .onReceive(iconTimer) { _ in
            let next = MenuBarIcon.nextFrame(animationFrame, badge: badge)
            if next != animationFrame {
                animationFrame = next
            }
        }
    }
}
