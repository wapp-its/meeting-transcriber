import Foundation

/// What a job's single line in the menu bar menu says about it: a short
/// status after the title, and a symbol in place of the coloured dot the
/// menu cannot draw. The full error or warning text sits in the job's
/// submenu, so the line itself stays short.
enum JobMenuSummary {
    /// `progress` is the running stage with its elapsed time, used while the
    /// job is transcribing, diarizing or generating its protocol.
    static func status(of job: PipelineJob, progress: String) -> String {
        switch job.state {
        case .waiting: job.state.label
        case .transcribing, .diarizing, .generatingProtocol: progress
        case .speakerNamingPending: "Speaker names needed"
        case .done: job.warnings.isEmpty ? "Done" : "Done, with warnings"
        case .error: "Failed"
        }
    }

    static func symbol(of job: PipelineJob) -> String {
        switch job.state {
        case .waiting: "clock"
        case .transcribing: "waveform"
        case .diarizing: "person.2"
        case .generatingProtocol: "doc.text"
        case .speakerNamingPending: "person.crop.circle.badge.questionmark"
        case .done: job.warnings.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}
