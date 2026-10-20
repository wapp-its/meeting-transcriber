import Foundation

/// What the items of the menu bar menu do, handed to `MenuBarView` as one
/// value instead of one callback per item. Built in
/// `MeetingTranscriberApp.menuBarContent`.
///
/// An optional member is optional because nil changes the menu: it hides
/// "Stop Recording", "Pause/Resume Recording" and "Name Speakers...", and
/// disables "Install Update".
@MainActor
struct MenuActions {
    /// Starts an mt-update install; nil disables the menu's install item.
    var installUpdate: (() -> Void)?
    var startStop: () -> Void
    /// Opens the start dialog, "Start Recording with Options…".
    var recordApp: () -> Void
    var recordMicrophone: () -> Void
    /// Stops whatever is recording, a detected meeting included; set only while a recording runs.
    var stopManualRecording: (() -> Void)?
    /// Pauses a running recording or resumes a paused one, whatever kind it is;
    /// set only while a recording's capture is running.
    var togglePause: (() -> Void)?
    /// A job line's Open: the job's protocol, else its transcript.
    var openProtocol: (URL) -> Void
    /// "Open Last Protocol": the newest finished job's protocol, else its
    /// transcript. Separate from a job line's Open because a file that is
    /// gone is reported here, as the Transcriptions window reports it.
    var openLastProtocol: (URL) -> Void
    var openProtocolsFolder: () -> Void
    var openSettings: () -> Void
    /// Opens the naming window; set only while a job waits for speaker names.
    var nameSpeakers: (() -> Void)?
    var processFiles: () -> Void
    /// Opens the Transcriptions window.
    var showAllTranscriptions: () -> Void
    /// Opens the Regenerate Protocol window.
    var regenerateProtocol: () -> Void
    /// Remove on a failed job: off the menu and out of the history for good.
    var removeFailedJob: (UUID) -> Void
    /// Dismiss on a job waiting for speaker names.
    var dismissJob: (UUID) -> Void
    /// Answers the question the menu displayed, true for Record. Handed the
    /// question rather than reading the open one, so a click on a menu that
    /// went stale answers nothing (`WatchLoop.answerParkedConsent`).
    var answerConsent: ((ConsentQuestion, Bool) -> Void)?
    /// Opens the Record Meeting window for the question the menu displayed.
    var recordConsentWithOptions: ((ConsentQuestion) -> Void)?
    var quit: () -> Void
    /// Stores a chosen microphone's UID, empty for System Default.
    var selectMicrophone: (String) -> Void
    /// Makes a chosen output the Mac's default output.
    var selectOutput: (String) -> Void

    /// Every action does nothing and every optional one is nil, so a test
    /// sets only the actions it asserts on.
    static let noop = Self(
        startStop: {},
        recordApp: {},
        recordMicrophone: {},
        openProtocol: { _ in },
        openLastProtocol: { _ in },
        openProtocolsFolder: {},
        openSettings: {},
        processFiles: {},
        showAllTranscriptions: {},
        regenerateProtocol: {},
        removeFailedJob: { _ in },
        dismissJob: { _ in },
        quit: {},
        selectMicrophone: { _ in },
        selectOutput: { _ in },
    )
}
