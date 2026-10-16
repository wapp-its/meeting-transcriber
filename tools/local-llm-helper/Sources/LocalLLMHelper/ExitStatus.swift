/// How a helper process ended, as its exit status.
///
/// These numbers are the contract with the app, which mirrors them in its own
/// package because the two share no code. They are defined here and documented
/// in README.md, nowhere else in this package. 0 and 1 keep their usual
/// meaning; the others stay clear of the values a shell reports (2, 126, 127,
/// and 128 plus a signal number). A helper killed by a signal (SIGKILL, a crash)
/// has no exit status at all, which the app reads as a failure.
enum ExitStatus: Int32, CaseIterable, Sendable {
    /// The model ended the protocol on its own; the output file holds all of it.
    case written = 0
    /// Anything not listed below: a request the helper cannot read, an output
    /// file it cannot create, a model that fails to load or to generate.
    case failure = 1
    /// Generation stopped at the output limit. The text written so far is kept.
    case incomplete = 10
    /// The model folder is missing, incomplete, unreadable, or holds a model
    /// type the pinned mlx-swift-lm cannot run.
    case modelUnusable = 11
    /// Prompt tokens plus the output limit exceed the context limit. Decided
    /// from the tokenizer alone, before any weights load.
    case promptTooLong = 12
    /// SIGTERM, or the parent process is gone. What was written is flushed first.
    case terminated = 13

    /// The word the exit line on stderr uses for this status.
    var reason: String {
        switch self {
        case .written: "written"
        case .failure: "failure"
        case .incomplete: "incomplete"
        case .modelUnusable: "model-unusable"
        case .promptTooLong: "prompt-too-long"
        case .terminated: "terminated"
        }
    }
}
