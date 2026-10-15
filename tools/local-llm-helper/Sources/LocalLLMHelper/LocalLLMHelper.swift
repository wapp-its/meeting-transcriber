import Darwin
import Foundation

/// The app's local-model helper: runs one protocol through an MLX model in its
/// own process, so the model's memory and any crash stay out of the app.
///
///     local-llm-helper run              request as JSON on stdin (see RunRequest)
///     local-llm-helper check <folder>   validates a model folder without loading weights
///     local-llm-helper selftest         proves the Metal shaders load and compute
///
/// Exit statuses: `ExitStatus`. Lines on stderr: `StderrLine`.
@main
enum LocalLLMHelper {
    static let usage = "usage: local-llm-helper run | check <model folder> | selftest"

    static func main() async {
        // A reader that went away must not kill the helper before it reports.
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch (arguments.first, arguments.count) {
        case ("run", 1):
            await RunCommand.run()

        case ("check", 2):
            await CheckCommand.run(folder: arguments[1])

        case ("selftest", 1):
            SelfTest.run()

        default:
            Console.error(usage)
            HelperExit.now(.failure, .failed(.usage))
        }
    }
}

/// `check <folder>`: one JSON line on stdout (`ModelFolderReport`), exit
/// status 0 when the folder is usable and `ExitStatus.modelUnusable` when not.
enum CheckCommand {
    static func run(folder: String) async -> Never {
        let (report, _) = await ModelFolderCheck.inspect(URL(fileURLWithPath: folder))
        Console.out(report.jsonLine())
        _exit(report.usable ? 0 : ExitStatus.modelUnusable.rawValue)
    }
}
