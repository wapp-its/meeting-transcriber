@testable import MeetingTranscriber
import XCTest

/// The log lines of a record-only write, which live stops and the crash
/// recovery share, and of the recovery's filing carry counts and error
/// domains and codes only: never a recording's stem, title, path or
/// participants, which an error's text can also carry.
///
/// A source scan, so it covers every line, not only the failures a test can
/// provoke.
final class RecordOnlyLogPrivacyTests: XCTestCase {
    func testRecordOnlyWriteAndRecoveryLogLinesCarryNoRecordingDetails() throws {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let write = try String(contentsOf: sources.appendingPathComponent("WatchLoop+RecordOnly.swift"), encoding: .utf8)
        let start = try XCTUnwrap(write.range(of: "struct RecordOnlyWrite"), "the write moved")
        let recovery = try String(contentsOf: sources.appendingPathComponent("RecordOnlyRecovery.swift"), encoding: .utf8)
        let statements = Self.logStatements(in: String(write[start.lowerBound...])) + Self.logStatements(in: recovery)
        XCTAssertGreaterThanOrEqual(statements.count, 5, "expected the write's three log lines and the recovery's two")

        XCTAssertEqual(statements.filter(Self.carriesRecordingDetails), [])
    }

    /// The scan finds what it is looking for, so an empty result means something.
    func testTheScanCatchesRecordingDetails() {
        let caught = [
            #"logger.info("Record-only: wrote sidecar + WAVs to \(destDir.path) for \(title, privacy: .private)")"#,
            #"logger.error("Record-only: \(source.lastPathComponent) stays in staging")"#,
            #"logger.error("Record-only: a step failed: \(error.localizedDescription)")"#,
        ]
        let allowed = [
            #"logger.error("Record-only: failed (\(code.domain, privacy: .public) \(code.code, privacy: .public))")"#,
            #"logger.info("Record-only recovery: filed \(filed, privacy: .public), failed \(failed, privacy: .public)")"#,
        ]

        XCTAssertEqual(caught.filter(Self.carriesRecordingDetails), caught)
        XCTAssertEqual(allowed.filter(Self.carriesRecordingDetails), [])
    }

    /// Each `logger.` call in `source`, from its name to its closing
    /// parenthesis, however many lines it spans.
    private static func logStatements(in source: String) -> [String] {
        var statements: [String] = []
        var rest = source[...]
        while let call = rest.range(of: "logger.") {
            var depth = 0
            var end = call.upperBound
            for index in rest[call.upperBound...].indices {
                if rest[index] == "(" { depth += 1 }
                if rest[index] == ")" {
                    depth -= 1
                    if depth == 0 { end = rest.index(after: index); break }
                }
            }
            statements.append(String(rest[call.lowerBound ..< end]))
            rest = rest[end...]
        }
        return statements
    }

    /// Whether an interpolation in `statement` is anything but a count, a
    /// tally or an error's domain or code.
    private static func carriesRecordingDetails(_ statement: String) -> Bool {
        let interpolation = try? NSRegularExpression(pattern: #"\\\(\s*([^,()]+)"#)
        let range = NSRange(statement.startIndex..., in: statement)
        let values = (interpolation?.matches(in: statement, range: range) ?? []).compactMap { match in
            Range(match.range(at: 1), in: statement).map { statement[$0].trimmingCharacters(in: .whitespaces) }
        }
        return values.contains { value in
            value.range(of: #"^((\w+\.)*(count|domain|code)|filed|failed)$"#, options: .regularExpression) == nil
        }
    }
}
