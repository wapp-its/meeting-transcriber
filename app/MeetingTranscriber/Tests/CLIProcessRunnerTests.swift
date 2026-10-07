#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The shared process core every CLI protocol provider runs on, driven
    /// with `#!/bin/sh` fake programs that report what they received or
    /// misbehave on purpose.
    final class CLIProcessRunnerTests: XCTestCase {
        /// Working directory of every run, holding the fake programs too.
        private var scratch = FileManager.default.temporaryDirectory

        /// Fake programs that leave a background `sleep` behind append its
        /// pid here, so the test can end it.
        private var backgroundPIDs: URL {
            scratch.appendingPathComponent("background.pids")
        }

        override func setUpWithError() throws {
            try super.setUpWithError()
            scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("cli-runner-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        }

        override func tearDownWithError() throws {
            let pids = (try? String(contentsOf: backgroundPIDs, encoding: .utf8)) ?? ""
            for pid in pids.split(separator: "\n").compactMap({ Int32($0) }) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: scratch)
            try super.tearDownWithError()
        }

        // MARK: - Arguments, input, output

        /// No shell: every argument arrives as one unchanged argument and
        /// nothing in it is executed.
        func testArgumentsArriveVerbatimAndAreNeverExecuted() async throws {
            let arguments = ["plain", "a b;touch x", "it's \"quoted\"", "$(touch y)", "`touch z`", "a|b", ""]
            let program = try makeProgram(#"for arg in "$@"; do printf '%s\n' "$arg"; done"#)

            let output = try await CLIProcessRunner.run(request(program, arguments: arguments))

            XCTAssertEqual(output.status, 0)
            XCTAssertEqual(output.stdout, Data(arguments.map { $0 + "\n" }.joined().utf8))
            for name in ["x", "y", "z"] {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: scratch.appendingPathComponent(name).path),
                    "an argument was executed: \(name) exists",
                )
            }
        }

        func testLargeInputArrivesInFull() async throws {
            let program = try makeProgram("wc -c | tr -d ' '")

            let output = try await CLIProcessRunner.run(request(program, input: Data(count: 1 << 20)))

            XCTAssertEqual(output.stdout, Data("1048576\n".utf8))
        }

        /// No input means end-of-file at once, not an inherited stdin.
        func testNoInputGivesEndOfFileAtOnce() async throws {
            let program = try makeProgram("cat\necho end")

            let output = try await CLIProcessRunner.run(request(program, timeout: 5))

            XCTAssertEqual(output.stdout, Data("end\n".utf8))
        }

        func testStatusStdoutAndStderrComeBackSeparately() async throws {
            let program = try makeProgram("printf out\nprintf err >&2\nexit 7")

            let output = try await CLIProcessRunner.run(request(program))

            XCTAssertEqual(output, CLIProcessRunner.Output(status: 7, stdout: Data("out".utf8), stderr: Data("err".utf8)))
        }

        /// The write end has SIGPIPE suppressed, so a program that exits
        /// without reading its input leaves the app running.
        func testProgramThatExitsWithoutReadingItsInputEndsTheRunCleanly() async throws {
            let program = try makeProgram("exit 3")

            let output = try await CLIProcessRunner.run(request(program, input: Data(count: 4 << 20)))

            XCTAssertEqual(output.status, 3)
        }

        func testProgramRunsInTheGivenWorkingDirectory() async throws {
            let program = try makeProgram("pwd -P")

            let output = try await CLIProcessRunner.run(request(program))

            try XCTAssertEqual(output.stdout, Data((Self.physicalPath(scratch) + "\n").utf8))
        }

        func testMissingExecutableCannotStart() async throws {
            let missing = scratch.appendingPathComponent("no-such-program")
            do {
                _ = try await CLIProcessRunner.run(request(missing))
                XCTFail("Expected .couldNotStart")
            } catch let CLIProcessRunner.Failure.couldNotStart(reason) {
                XCTAssertFalse(reason.isEmpty)
            }
        }

        // MARK: - Timeout, caps, background processes

        /// The deadline stops a program that prints nothing, including one
        /// that ignores SIGTERM, and the run does not wait for it to die.
        func testTimeoutStopsASilentProgram() async throws {
            for body in ["sleep 30", "trap '' TERM\nsleep 30"] {
                let program = try makeProgram(body)
                let start = Date()
                do {
                    _ = try await CLIProcessRunner.run(request(program, timeout: 1))
                    XCTFail("Expected .timedOut for: \(body)")
                } catch CLIProcessRunner.Failure.timedOut {}
                XCTAssertLessThan(Date().timeIntervalSince(start), 3, "the run outlived its timeout for: \(body)")
            }
        }

        /// A background process holding stdout open must not hold up the
        /// run once the program itself has exited: the run ends about two
        /// seconds after the exit, long before the 20 s timeout. The bound
        /// leaves room for a slow launch on a loaded machine.
        func testBackgroundProcessHoldingTheOutputDoesNotHoldUpTheRun() async throws {
            let program = try makeProgram("sleep 30 &\necho $! >> '\(backgroundPIDs.path)'\necho done\nexit 0")
            let start = Date()

            let output = try await CLIProcessRunner.run(request(program, timeout: 20))

            XCTAssertEqual(output.status, 0)
            XCTAssertEqual(output.stdout, Data("done\n".utf8))
            XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        }

        func testStdoutOverItsCapFailsTheRun() async throws {
            let program = try makeProgram("head -c 100000 /dev/zero")
            do {
                _ = try await CLIProcessRunner.run(request(program, maxStdoutBytes: 1024))
                XCTFail("Expected .stdoutTooLarge")
            } catch CLIProcessRunner.Failure.stdoutTooLarge {}
        }

        func testStderrOverItsCapKeepsItsFirstBytesAndTheRunSucceeds() async throws {
            let program = try makeProgram("{ printf BEGIN; head -c 100000 /dev/zero; } >&2\nprintf ok")

            let output = try await CLIProcessRunner.run(request(program, maxStderrBytes: 1024))

            XCTAssertEqual(output.status, 0)
            XCTAssertEqual(output.stdout, Data("ok".utf8))
            XCTAssertEqual(output.stderr.count, 1024)
            XCTAssertEqual(output.stderr.prefix(5), Data("BEGIN".utf8))
        }

        /// No thread may stay parked on a pipe. Twice as many runs as there
        /// are cores each leave a background process holding stdin, stdout
        /// and stderr open, with input nobody reads; if any part of a run
        /// waited on a pipe from Swift's cooperative pool, the pool would
        /// starve and neither a fresh task nor another run would complete.
        /// The pool is split by priority, so the probe runs both detached
        /// (the default priority, where a `Task.detached` reader would park)
        /// and inheriting the test's priority. (`sh` gives a background job
        /// `/dev/null` as stdin unless it is redirected explicitly, hence the
        /// detour through descriptor 3.)
        func testRunsLeaveNoWaitersBehind() async throws {
            let program = try makeProgram(
                "exec 3<&0\nsleep 30 <&3 3<&- &\necho $! >> '\(backgroundPIDs.path)'\nexit 0",
            )
            let runs = 2 * ProcessInfo.processInfo.activeProcessorCount
            let runRequest = request(program, input: Data(count: 1 << 20), timeout: 20)

            let results = try await withThrowingTaskGroup(of: (status: Int32, seconds: TimeInterval).self) { group in
                for _ in 0 ..< runs {
                    group.addTask {
                        let start = Date()
                        let output = try await CLIProcessRunner.run(runRequest)
                        return (output.status, Date().timeIntervalSince(start))
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            XCTAssertEqual(results.map(\.status), Array(repeating: 0, count: runs))
            XCTAssertLessThan(results.map(\.seconds).max() ?? .infinity, 5, "a run was held up by its background process")

            let start = Date()
            let detachedRan = expectation(description: "a fresh detached task ran")
            let inheritingRan = expectation(description: "a fresh task ran")
            Task.detached { detachedRan.fulfill() }
            Task { inheritingRan.fulfill() }
            let waited = await XCTWaiter.fulfillment(of: [detachedRan, inheritingRan], timeout: 2)
            XCTAssertEqual(waited, .completed, "the cooperative pool was starved after the runs")
            let trivial = try await CLIProcessRunner.run(request(makeProgram("echo ok")))
            XCTAssertEqual(trivial.stdout, Data("ok\n".utf8))
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, "a fresh run was held up after the runs")
        }

        // MARK: - Helpers

        private func makeProgram(_ body: String) throws -> URL {
            let url = scratch.appendingPathComponent("fake-\(UUID().uuidString).sh")
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        private func request(
            _ program: URL,
            arguments: [String] = [],
            input: Data? = nil,
            timeout: TimeInterval = 10,
            maxStdoutBytes: Int = CLIProcessRunner.defaultMaxStdoutBytes,
            maxStderrBytes: Int = CLIProcessRunner.defaultMaxStderrBytes,
        ) -> CLIProcessRunner.Request {
            CLIProcessRunner.Request(
                executable: program,
                arguments: arguments,
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: scratch,
                standardInput: input,
                timeout: timeout,
                maxStdoutBytes: maxStdoutBytes,
                maxStderrBytes: maxStderrBytes,
            )
        }

        /// `url` with every symlink resolved, as `pwd -P` reports it.
        private static func physicalPath(_ url: URL) throws -> String {
            let resolved = try XCTUnwrap(realpath(url.path, nil))
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
#endif
