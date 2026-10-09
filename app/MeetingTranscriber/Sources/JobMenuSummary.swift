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
    /// `progress` is the running stage with its elapsed time, used while the
    /// job is transcribing, diarizing or generating its protocol.
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

    static func status(of job: PipelineJob, progress: String) -> String {
        status(state: job.state, hasWarnings: !job.warnings.isEmpty, progress: progress)
    }

    static func symbol(of job: PipelineJob) -> String {
        symbol(state: job.state, hasWarnings: !job.warnings.isEmpty)
    }
}
