import Foundation

/// Whether the start dialog can start a recording, and if not, why.
///
/// A value rather than booleans in the view because the blockers are not
/// interchangeable. A missing selection is visible on screen; a recording already
/// running is invisible from the dialog and is the reason a press would
/// otherwise appear to do nothing. So the recording case outranks the selection
/// case: picking a source would not help, and saying "pick one" there would send
/// the user the wrong way.
enum AppPickerStartState: Equatable {
    /// Nothing in the way.
    case ready
    /// No source picked yet.
    case noSelection
    /// A manual recording owns the watch loop, or is on its way to owning it.
    /// Starting a second one used to abandon the first: its audio was never
    /// enqueued while its recorder kept capturing, retained by its own monitor
    /// task (issue #624).
    case manualRecordingActive
    /// "Microphone only" is picked while "No Microphone" is set, which the
    /// controller refuses too (`WatchingController.startMicrophoneRecording`).
    case microphoneBlockedByNoMic

    /// - Parameter startWouldBeRefused: `WatchingController.isManualRecording`,
    ///   the *wide* predicate. The dialog asks whether a start would be refused,
    ///   and it is refused in both halves: while a manual start is still in
    ///   flight, and once its loop exists. The loop-only predicate is the menu
    ///   bar's different question, "is there a recording I can stop".
    ///
    ///   Both halves are reachable, because the menu gates *opening* this
    ///   window, not its persistence. It closes only on its own Start or Cancel,
    ///   so a dialog opened during an in-flight start is still there once the
    ///   loop exists, and re-renders through both states. Getting this wrong in
    ///   either direction is silent: the loop-only predicate leaves a lingering
    ///   dialog offering Start during a live recording, where the press is
    ///   refused and the window closes as if it had worked.
    static func resolve(source: StartRecordingSource?, noMic: Bool, startWouldBeRefused: Bool) -> Self {
        if startWouldBeRefused { return .manualRecordingActive }
        guard let source else { return .noSelection }
        if source == .microphone, noMic { return .microphoneBlockedByNoMic }
        return .ready
    }

    var allowsStart: Bool {
        self == .ready
    }

    /// What to tell the user, or nil when nothing is in the way. The spec's
    /// R5 asks for an explanation on every disabled Start, the missing
    /// selection included.
    var explanation: String? {
        switch self {
        case .ready:
            nil

        case .noSelection:
            "Choose what to record: the microphone only, or one of the running apps."

        case .manualRecordingActive:
            "Another recording is already starting or under way. The menu bar shows it once it is running."

        case .microphoneBlockedByNoMic:
            MicrophoneRecordingAvailability.blockedByNoMicSetting.disabledReason
        }
    }
}
