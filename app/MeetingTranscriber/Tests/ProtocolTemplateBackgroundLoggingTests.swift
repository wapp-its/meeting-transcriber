@testable import MeetingTranscriber
import XCTest

/// Background info is meeting content, so no log statement may carry it, not
/// even at `.private`: the persistent diagnostic log is exported as a file.
///
/// A source scan rather than a behavioural test, because a leak cannot be
/// observed from inside the process: what `OSLogStore` hands back has the
/// private values redacted, which is exactly where such a leak would hide.
final class ProtocolTemplateBackgroundLoggingTests: XCTestCase {
    func testNoLogStatementReadsTheBackground() throws {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 100, "Expected to scan the whole app target under \(sources.path)")

        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for statement in Self.logStatements(in: source) where Self.readsBackground(statement) {
                offenders.append("\(file): \(statement.prefix(160))")
            }
        }

        XCTAssertEqual(offenders, [], "Log statements that read the background info:\n" + offenders.joined(separator: "\n"))
    }

    /// A provider's failure text can echo the prompt it rejected, so the
    /// summary the pipeline logs names the case and its code only.
    func testProviderFailuresLogWithoutTheirText() {
        let echoed = "invalid request: <background>\nAlice chairs\n</background>"
        XCTAssertEqual(ProtocolError.httpError(400, echoed).logSummary, "HTTP 400")
        XCTAssertEqual(ProtocolError.connectionFailed(echoed).logSummary, "Connection failed")
        XCTAssertEqual(ProtocolError.emptyProtocol.logSummary, ProtocolError.emptyProtocol.errorDescription)
        #if !APPSTORE
            XCTAssertEqual(ProtocolError.cliFailed(2, echoed).logSummary, "Claude CLI exited with code 2")
            XCTAssertEqual(ProtocolError.commandFailed(tool: "Codex CLI", exitCode: 1, reason: echoed).logSummary, "Codex CLI exited with code 1")
        #endif
        XCTAssertEqual(ProtocolError.httpError(400, echoed).errorDescription, "HTTP 400: \(echoed)", "the person still sees the text")
    }

    /// The scan finds what it is looking for, so an empty result means
    /// something.
    func testTheScanCatchesALoggedBackground() {
        let source = """
        logger.info("[\\(id)] template=\\(name, privacy: .private) text=\\(
            instructions.background ?? "", privacy: .private)")
        print(job.protocolBackground ?? "")
        logger.info("background=\\(presence, privacy: .public)")
        """

        XCTAssertEqual(Self.logStatements(in: source).filter(Self.readsBackground).count, 2)
    }

    /// Every call to a logging method, `debugLog`, `NSLog` or `print`, from
    /// its name to its closing parenthesis.
    private static func logStatements(in source: String) -> [Substring] {
        let call = #"\.(debug|info|notice|warning|error|fault|critical|trace|log)\s*\(|\b(debugLog|NSLog|print)\s*\("#
        var statements: [Substring] = []
        var searchStart = source.startIndex
        while let match = source.range(of: call, options: .regularExpression, range: searchStart ..< source.endIndex) {
            var depth = 0
            var end = match.upperBound
            for index in source.indices[source.index(before: match.upperBound)...] {
                if source[index] == "(" { depth += 1 }
                if source[index] == ")" { depth -= 1 }
                if depth == 0 {
                    end = source.index(after: index)
                    break
                }
            }
            statements.append(source[match.lowerBound ..< end])
            searchStart = match.upperBound
        }
        return statements
    }

    /// The job's field, or the `background` field of its instructions.
    private static func readsBackground(_ statement: Substring) -> Bool {
        statement.contains("protocolBackground")
            || statement.range(of: #"\.background\b"#, options: .regularExpression) != nil
    }
}
