import AppKit
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "Launch")

// MARK: - Pure Helpers (testable without @main)

// Split out of `MeetingTranscriberApp.swift`, which the menu's and the All
// Recordings window's wiring took past the file and type length limits. Static
// and free of the scene's state: what they need of it is passed in.
extension MeetingTranscriberApp {
    /// Tell the user when the previous run ended without a quit (issue #703),
    /// the one outcome they cannot see for themselves: a menu bar app that is
    /// gone looks exactly like one that is idle. A clean quit is the normal
    /// launch and stays silent; so does a second instance, which is not a
    /// crash, though it is logged because two instances share one marker and
    /// only the later one is covered from here on.
    static func reportPreviousExit(_ exit: PreviousExit, to notifier: any AppNotifying, now: Date = Date()) {
        switch exit {
        case .clean:
            break

        case let .stillRunning(pid):
            logger.warning("another_instance_running pid=\(pid, privacy: .public)")

        case let .unclean(lastAlive):
            logger.warning("previous_run_ended_without_quit lastAlive=\(lastAlive.description, privacy: .public)")
            let notice = PreviousExitNotice(lastAlive: lastAlive, now: now)
            // `.standard` on purpose, decided rather than defaulted. This is
            // posted at launch, which after a reboot or a login-item start is
            // when nobody is looking, and a banner is gone in seconds; but
            // macOS keeps it in Notification Center until it is dismissed, and
            // that list is where the user finds it when they next look.
            // `.timeSensitive` is reserved for a failure the user can still act
            // on while it is happening (see `NotificationUrgency`), and this
            // one is over: the app is back by the time it is posted, and
            // nothing the user does now recovers the window. Breaking through
            // Focus for a report about the past would spend that entitlement
            // on the wrong notification. It is the only surface carrying the
            // information; a second one (a menu item, a `/state` field) is the
            // follow-up if this proves too easy to miss.
            notifier.notify(title: PreviousExitNotice.title, body: notice.body, urgency: .standard)
        }
    }

    /// Whether auto-watch should be enabled based on CLI flags or user settings.
    static func shouldAutoWatch(
        commandLineArgs: [String] = CommandLine.arguments,
        autoWatchSetting: Bool = UserDefaults.standard.bool(forKey: "autoWatch"),
    ) -> Bool {
        commandLineArgs.contains("--auto-watch") || autoWatchSetting
    }

    /// A job line's Open. A file inside the output folder's security scope:
    /// after a restart a history line can be opened before any queue holds
    /// that scope, which the App Store build needs, and a file that is gone
    /// opens nothing. A Notion page through `openInNotion`.
    static func openJob(_ target: JobOpenTarget, scopeRoot: URL) {
        switch target {
        case let .file(url):
            _ = TranscriptionFileOpener.perform(url, scopeRoot: scopeRoot) { NSWorkspace.shared.open($0) }

        case .notion:
            openInNotion(target)
        }
    }

    /// A Notion page through `ProtocolOpener`, which hands it to a running
    /// Notion app.
    static func openInNotion(_ target: JobOpenTarget) {
        logger.info("Menu protocol open requested")
        Task {
            let opened = await ProtocolOpener().open(target)
            logger.info("Menu protocol open accepted: \(opened)")
        }
    }

    /// "Open Last Protocol": the file inside the output folder's security
    /// scope, through the check the All Recordings window's Open makes. When
    /// the file is gone the window says "The file was moved or deleted."; the
    /// menu has closed by then, so the same sentence arrives as a notification.
    static func openLastProtocol(
        _ url: URL, scopeRoot: URL, notifier: any AppNotifying,
        open: (URL) -> Void = { NSWorkspace.shared.open($0) },
    ) {
        guard !TranscriptionFileOpener.perform(url, scopeRoot: scopeRoot, action: open) else { return }
        notifier.notify(title: "Open Last Protocol", body: "The file was moved or deleted.", urgency: .standard)
    }
}
