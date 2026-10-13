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

    /// What a provider wrote back can echo the prompt it received, so no log
    /// statement may carry a subprocess's or an endpoint's output either:
    /// not its stderr, not its stdout, not an HTTP error body, not the
    /// failure message derived from them.
    func testNoLogStatementReadsProviderOutput() throws {
        let sources = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }

        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for statement in Self.logStatements(in: source) where Self.readsProviderOutput(statement) {
                offenders.append("\(file): \(statement.prefix(160))")
            }
        }

        XCTAssertEqual(offenders, [], "Log statements that read a provider's output:\n" + offenders.joined(separator: "\n"))
    }

    func testTheScanCatchesLoggedProviderOutput() {
        let source = """
        logger.error("claude_cli_failed exit=\\(exitCode, privacy: .public) stderr=\\(stderrText, privacy: .public)")
        logger.error("command_failed_output stdout=\\(Self.logExcerpt(output.stdout), privacy: .private)")
        logger.error("openai_http_error body=\\(errorBody, privacy: .public)")
        logger.error("claude_cli_failed exit=\\(exitCode, privacy: .public) stderr_bytes=\\(stderrData.count, privacy: .public)")
        logger.error("command_failed stdout_bytes=\\(output.stdout.count, privacy: .public) body_length=\\(errorBody.count, privacy: .public)")
        """

        XCTAssertEqual(Self.logStatements(in: source).filter(Self.readsProviderOutput).count, 3)
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

    /// The names the generators give a subprocess's or an endpoint's output
    /// and the messages derived from it.
    /// A byte count of that output is allowed: it says how much came back,
    /// not what.
    private static func readsProviderOutput(_ statement: Substring) -> Bool {
        let names = #"\b(stderrText|stdoutText|errorBody|publicMessage|logExcerpt|output\.stdout|output\.stderr)\b(?!\.count\b)(?!\.utf8\.count\b)"#
        return statement.range(of: names, options: .regularExpression) != nil
    }

    /// The job's field, or the `background` field of its instructions.
    private static func readsBackground(_ statement: Substring) -> Bool {
        statement.contains("protocolBackground")
            || statement.range(of: #"\.background\b"#, options: .regularExpression) != nil
    }
}
