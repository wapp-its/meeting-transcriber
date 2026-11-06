import Foundation

/// What a job's single line in the menu bar menu says about it: a short
/// status after the title, and a symbol in place of the coloured dot the
/// menu cannot draw. The full error or warning text sits in the job's
/// submenu, so the line itself stays short.
///
/// Keyed on the state, whether there are warnings and an open Notion export,
/// not on a live job, so the Transcriptions window and a job known only from
/// the history read the same as the menu.
enum JobMenuSummary {
    /// `progress` is the running stage's line (`stageProgress` in the menu),
    /// used while the job is transcribing, diarizing or generating its protocol.
    /// `notionExport` is a finished job's export still open
    /// (`TranscriptionEntry.openNotionExport`), which is what such a job's
    /// line is about.
    static func status(
        state: JobState, hasWarnings: Bool, progress: String, notionExport: NotionExportStatus? = nil,
    ) -> String {
        switch state {
        case .waiting: state.label
        case .transcribing, .diarizing, .generatingProtocol: progress
        case .speakerNamingPending: "Speaker names needed"
        case .done: doneStatus(hasWarnings: hasWarnings, notionExport: notionExport)
        case .error: "Failed"
        }
    }

    private static func doneStatus(hasWarnings: Bool, notionExport: NotionExportStatus?) -> String {
        switch notionExport {
        case .inProgress: notionExportRunning
        case .failed: "Notion export failed"
        case .completed, nil: hasWarnings ? "Done, with warnings" : "Done"
        }
    }

    /// The line of a finished job while its Notion export runs, in the
    /// submenu as well as after the title.
    static let notionExportRunning = "Exporting to Notion…"

    static func symbol(state: JobState, hasWarnings: Bool, notionExport: NotionExportStatus? = nil) -> String {
        switch state {
        case .waiting: "clock"
        case .transcribing: "waveform"
        case .diarizing: "person.2"
        case .generatingProtocol: "doc.text"
        case .speakerNamingPending: "person.crop.circle.badge.questionmark"
        case .done: doneSymbol(hasWarnings: hasWarnings, notionExport: notionExport)
        case .error: "xmark.octagon"
        }
    }

    private static func doneSymbol(hasWarnings: Bool, notionExport: NotionExportStatus?) -> String {
        switch notionExport {
        case .inProgress: "icloud.and.arrow.up"
        case .failed: "exclamationmark.icloud"
        case .completed, nil: hasWarnings ? "exclamationmark.triangle" : "checkmark.circle"
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
