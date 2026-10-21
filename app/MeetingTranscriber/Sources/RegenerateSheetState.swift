import Observation

/// Whether the All Recordings window shows its regenerate sheet, and which
/// meeting the sheet opens with. Owned by the App, which presents it from the
/// window's actions. A reference type, so a test presents it and reads back
/// what the sheet would show (CLAUDE.md, GUI Testing, rung 2).
@Observable
@MainActor
final class RegenerateSheetState {
    /// Bound to the sheet, which sets it to false when it closes.
    var isPresented = false
    /// The meeting the sheet opens with; nil opens it without one.
    private(set) var initialTarget: ProtocolRegenerationTarget?

    /// "Choose File…" is offered only when the sheet opened without a meeting:
    /// a row's sheet is for that row's meeting.
    var allowsChooseFile: Bool {
        initialTarget == nil
    }

    /// Opens the sheet for `entry`'s meeting, or without a meeting for nil
    /// ("Regenerate from File…"). A previous run's result is forgotten first,
    /// here rather than in the sheet: a sheet appears afresh on every
    /// presentation, and a finished run's success must not show for another
    /// meeting. False, with the sheet left closed, when the row's files no
    /// longer hold a transcript, so the window can say the file was moved or
    /// deleted.
    @discardableResult
    func present(entry: TranscriptionEntry?, using regenerator: ProtocolRegenerator) -> Bool {
        regenerator.clearResult()
        if let entry {
            guard let target = try? regenerator.target(for: entry) else { return false }
            initialTarget = target
        } else {
            initialTarget = nil
        }
        isPresented = true
        return true
    }
}
