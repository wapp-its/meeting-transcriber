import Foundation

/// What a job's single line in the menu bar menu says about it: a short
/// status after the title, and a symbol in place of the coloured dot the
/// menu cannot draw. The full error or warning text sits in the job's
/// submenu, so the line itself stays short.
///
/// Keyed on the state and whether there are warnings, not on a live job, so
/// the Transcriptions window and a job known only from the history read the
/// same as the menu.
enum JobMenuSummary {
    /// `progress` is the running stage's line (`stageProgress` in the menu),
    /// used while the job is transcribing, diarizing or generating its protocol.
    static func status(state: JobState, hasWarnings: Bool, progress: String) -> String {
        switch state {
        case .waiting: state.label
        case .transcribing, .diarizing, .generatingProtocol: progress
        case .speakerNamingPending: "Speaker names needed"
        case .done: hasWarnings ? "Done, with warnings" : "Done"
        case .error: "Failed"
        }
    }

    static func symbol(state: JobState, hasWarnings: Bool) -> String {
        switch state {
        case .waiting: "clock"
        case .transcribing: "waveform"
        case .diarizing: "person.2"
        case .generatingProtocol: "doc.text"
        case .speakerNamingPending: "person.crop.circle.badge.questionmark"
        case .done: hasWarnings ? "exclamationmark.triangle" : "checkmark.circle"
        case .error: "xmark.octagon"
        }
    }

    /// A running stage's line, `Transcribing · since 09:17 · ready about
    /// 09:21`, or without the last part while the stage has no expected
    /// finish. Built from the clock's two fixed times and nothing else, so it
    /// reads the same however much time passes; once the clock has passed the
    /// expected finish, the stage is simply taking longer than usual. Times in
    /// the system's short time format, which shows a finish on the next day as
    /// its time only. Without a clock (a stage the queue did not see start),
    /// the stage label alone.
    static func stageProgress(
        state: JobState, clock: StageClock?,
        locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent,
    ) -> String {
        // The state's label without its trailing "...": the line goes on after it.
        let label = state.label.hasSuffix("...") ? String(state.label.dropLast(3)) : state.label
        guard let clock else { return label }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let since = "\(label) · since \(formatter.string(from: clock.startedAt))"
        guard let finish = clock.expectedFinish else { return since }
        return "\(since) · ready about \(formatter.string(from: finish))"
    }

    static func status(of job: PipelineJob, progress: String) -> String {
        status(state: job.state, hasWarnings: !job.warnings.isEmpty, progress: progress)
    }

    static func symbol(of job: PipelineJob) -> String {
        symbol(state: job.state, hasWarnings: !job.warnings.isEmpty)
    }
}
