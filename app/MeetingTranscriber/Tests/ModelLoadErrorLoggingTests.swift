@testable import MeetingTranscriber
import XCTest

/// A model-load error's text can name the model folder, and through the home
/// folder the account name: WhisperKit's `modelsUnavailable("Model file not
/// found at <path>")`, its Hub errors that carry a file URL, FluidAudio's
/// `AsrModelsError.modelNotFound`. `PersistentDiagnosticLog` writes these lines
/// to the file Settings offers as a redacted log, and that redaction is os_log
/// privacy. So in the ASR engines' files an error's type may be logged public,
/// its text only private.
///
/// A source scan, so it covers every log line in these files, not only the one
/// failure a test can provoke.
final class ModelLoadErrorLoggingTests: XCTestCase {
    func testEngineLogLinesKeepTheErrorTextPrivate() throws {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let prefixes = ["WhisperKit", "Parakeet", "HubTokenScoped"]
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter { name in name.hasSuffix(".swift") && prefixes.contains { name.hasPrefix($0) } }
            .sorted()
        XCTAssertGreaterThan(files.count, 10, "Expected the engines' files under \(sources.path)")

        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() where Self.logsErrorTextPublicly(line) {
                offenders.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertEqual(offenders, [], "Log lines that make an error's text public:\n" + offenders.joined(separator: "\n"))
    }

    /// The scan finds what it is looking for, so an empty result means something.
    func testTheScanCatchesPublicErrorText() {
        let caught = [
            #"logger.error("load failed (\(kind, privacy: .public): \(String(reflecting: error), privacy: .public))")"#,
            #"logger.error("load failed: \(error.localizedDescription, privacy: .public)")"#,
            #"logger.error("load failed: \(error, privacy: .public)")"#,
        ]
        let allowed = [
            #"logger.error("load failed (\(String(describing: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .private))")"#,
        ]

        XCTAssertEqual(caught.filter(Self.logsErrorTextPublicly), caught)
        XCTAssertEqual(allowed.filter(Self.logsErrorTextPublicly), [])
    }

    private static func logsErrorTextPublicly(_ line: String) -> Bool {
        let publicErrorText = #"\\\((String\((reflecting|describing):\s*error\)|error(\.localizedDescription)?)\s*,\s*privacy:\s*\.public\s*\)"#
        return line.range(of: publicErrorText, options: .regularExpression) != nil
    }
}
