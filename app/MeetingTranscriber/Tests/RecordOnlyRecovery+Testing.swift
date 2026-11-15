import Foundation
@testable import MeetingTranscriber

/// The record-only side of a staged recovery pass, as tests hand it in.
@MainActor
extension RecordOnlyRecovery {
    /// Record-only off: the pass queues what it recovers. Its destination
    /// cannot be created, so a pass that wrote anyway would fail, never
    /// reach a real folder.
    static var off: Self {
        Self(
            isOn: { false },
            quitHasBegun: { false },
            destination: { .unscoped(URL(fileURLWithPath: "/dev/null/record-only-off")) },
            notifier: RecordingNotifier(),
        )
    }

    /// Record-only `on` (or off), writing into `<output>/recordings`.
    static func writing(
        into output: URL,
        on: Bool = true,
        notifier: any AppNotifying = RecordingNotifier(),
    ) -> Self {
        Self(
            isOn: { on },
            quitHasBegun: { false },
            destination: { .production(parent: output) },
            notifier: notifier,
        )
    }
}
