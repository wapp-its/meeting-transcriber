@testable import MeetingTranscriber
import XCTest

/// The local model generator end to end against fake helpers: `#!/bin/sh`
/// scripts that play the real helper's exit statuses and stderr lines
/// (`tools/local-llm-helper/README.md`). No test here starts the real helper.
@MainActor
final class LocalModelGeneratorTests: XCTestCase {
    #if APPSTORE
        func testAppStoreVariantOffersNoLocalModelProvider() {
            XCTAssertEqual(ProtocolProvider.allCases, [.openAICompatible, .none])
        }

    #else
        func testEachExitStatusMapsToItsOutcomeAndLeavesNoRunDirectory() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGenerator"))
            let cases: [(body: String, expected: LocalModelTestEnd)] = [
                (#"printf 'Protocol' > "$out"; exit 0"#, .written("Protocol")),
                ("exit 0", .outcome(.failure(.emptyOutput))),
                (#"printf 'Partial' > "$out"; exit 10"#, .outcome(.incomplete(text: "Partial"))),
                ("exit 11", .outcome(.noModel)),
                ("exit 12", .outcome(.promptTooLong)),
                ("exit 13", .outcome(.failure(.exitStatus(13)))),
                ("exit 1", .outcome(.failure(.exitStatus(1)))),
                ("kill -KILL $$", .outcome(.failure(.signal(SIGKILL)))),
            ]
            for (body, expected) in cases {
                let end = try await bench.end(bench.helper(body))
                XCTAssertEqual(end, expected, body)
                XCTAssertEqual(bench.runDirectoryNames, [], "a run directory is left after: \(body)")
            }
        }

        func testRequestReachesTheHelperOnStandardInputInAnOwnerOnlyRunDirectory() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGenerator"))
            let seen = bench.scratch.appendingPathComponent("seen", isDirectory: true)
            try FileManager.default.createDirectory(at: seen, withIntermediateDirectories: false)
            let helper = try bench.helper("""
            printf '%s' "$req" > '\(seen.path)/request.json'
            printf '%s\\n' "$@" > '\(seen.path)/arguments'
            stat -f '%Lp' . > '\(seen.path)/directory-mode'
            stat -f '%Lp' request.json > '\(seen.path)/request-mode'
            printf 'Protocol' > "$out"
            """)

            let end = await bench.end(helper, transcript: "Alice: hello")

            XCTAssertEqual(end, .written("Protocol"))
            let data = try Data(contentsOf: seen.appendingPathComponent("request.json"))
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            // The six fields of the helper's request and nothing else: no sampling settings (spec A10).
            XCTAssertEqual(Set(request.keys), ["modelFolder", "systemPrompt", "userPrompt", "contextLimit", "outputLimit", "outputPath"])
            XCTAssertEqual(request["modelFolder"] as? String, bench.modelFolder.path)
            XCTAssertEqual(request["userPrompt"] as? String, "Alice: hello")
            XCTAssertEqual(
                request["systemPrompt"] as? String,
                ProtocolGenerator.buildSystemPrompt(
                    diarized: true, language: LocalModelTestBench.language, meetingStartTime: nil, instructions: LocalModelTestBench.instructions,
                ),
            )
            XCTAssertEqual(request["contextLimit"] as? Int, 32768)
            XCTAssertEqual(request["outputLimit"] as? Int, 16000)
            let output = try URL(fileURLWithPath: XCTUnwrap(request["outputPath"] as? String))
            XCTAssertEqual(output.deletingLastPathComponent().deletingLastPathComponent().path, bench.runParent.path)
            XCTAssertEqual(try bench.contents(of: seen.appendingPathComponent("arguments")), "run\n")
            XCTAssertEqual(try bench.contents(of: seen.appendingPathComponent("directory-mode")), "700\n")
            XCTAssertEqual(try bench.contents(of: seen.appendingPathComponent("request-mode")), "600\n")
        }

        /// Lifecycle lines are not progress: a helper that prints only those
        /// still runs into the no-progress deadline.
        func testDeadlinesEndAHelperThatStopsReportingOrNeverFinishes() async throws {
            let silent = """
            echo 'progress phase=loading' >&2
            trap 'exit 13' TERM
            while :; do echo 'lifecycle event=prompt tokens=5 context=32768 output=16000' >&2; sleep 0.05; done
            """
            let busy = "trap 'exit 13' TERM; while :; do echo 'progress phase=writing tokens=32' >&2; sleep 0.05; done"
            let cases: [(body: String, limits: LocalModelLimits, expected: LocalModelDeadline)] = [
                (silent, .fast(totalDeadline: .seconds(30), noProgressDeadline: .milliseconds(500)), .noProgress),
                (busy, .fast(totalDeadline: .seconds(1), noProgressDeadline: .seconds(5)), .total),
            ]
            for (body, limits, expected) in cases {
                let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGenerator"), limits: limits)
                let end = try await bench.end(bench.helper(body))
                XCTAssertEqual(end, .outcome(.deadline(expected)))
                XCTAssertEqual(bench.runDirectoryNames, [])
            }
        }

        func testCancellingTheCallingTaskEndsTheHelperWithinTheGrace() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGenerator"))
            let started = bench.scratch.appendingPathComponent("started")
            let helper = try bench.helper("trap 'exit 13' TERM; echo $$ > '\(started.path)'; while :; do sleep 0.05; done")
            let task = Task { await bench.end(helper) }
            let pid = try await bench.pid(writtenTo: started)

            let cancelledAt = ContinuousClock.now
            task.cancel()
            let end = await task.value

            XCTAssertEqual(end, .cancelled)
            // Ended by SIGTERM, inside the grace: SIGKILL was never needed.
            XCTAssertEqual(bench.diagnostics.lines(.notice, startingWith: "local_model_killed"), [])
            XCTAssertLessThan(ContinuousClock.now - cancelledAt, LocalModelLimits.fast().killGrace + .seconds(1))
            XCTAssertNotEqual(kill(pid, 0), 0, "the helper still runs")
            XCTAssertEqual(bench.runDirectoryNames, [])
        }

        func testMissingOrNonExecutableHelperIsAFailureOfItsOwn() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGenerator"))
            let notExecutable = bench.scratch.appendingPathComponent(LocalModelHelperLocator.executableName)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: notExecutable)

            for helper in [nil, notExecutable] {
                let end = await bench.end(helper)
                XCTAssertEqual(end, .outcome(.failure(.helperMissing)))
            }
            XCTAssertEqual(bench.diagnostics.lines(.warning, startingWith: "local_model_refused job=none reason=helper_missing").count, 2)
        }

        func testNoChosenOrUnreachableFolderIsNoModelAndStartsNoHelper() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGenerator"))
            let spawned = bench.scratch.appendingPathComponent("spawned")
            let helper = try bench.helper("touch '\(spawned.path)'")
            let folders = [
                LocalModelFolderSelection(path: "", bookmark: nil),
                LocalModelFolderSelection(path: bench.scratch.appendingPathComponent("missing").path, bookmark: nil),
            ]

            for folder in folders {
                let end = await bench.end(helper, folder: folder)
                XCTAssertEqual(end, .outcome(.noModel), folder.path)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawned.path))
        }

        /// An ejected volume takes the helper down with its memory-mapped weights.
        func testFolderThatVanishedDuringTheRunIsNoModel() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGenerator"))
            let gone = bench.scratch.appendingPathComponent("model-gone")
            let helper = try bench.helper("mv '\(bench.modelFolder.path)' '\(gone.path)'; kill -KILL $$")

            let end = await bench.end(helper)

            XCTAssertEqual(end, .outcome(.noModel))
        }

        /// The helper echoes the request (and with it the transcript) and
        /// protocol text to stderr, in lines outside the contract and as extra
        /// fields of contract lines; none of it reaches a log line.
        func testNoLogLineCarriesTranscriptOrProtocolText() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "LocalModelGenerator"))
            let helper = try bench.helper("""
            printf '%s\\n' "$req" >&2
            echo 'progress phase=PROTOCOL-MARKER' >&2
            echo 'progress phase=writing tokens=5 text=PROTOCOL-MARKER' >&2
            printf 'PROTOCOL-MARKER minutes' > "$out"
            exit 10
            """)

            let end = await bench.end(helper, transcript: "TRANSCRIPT-MARKER said hello")

            XCTAssertEqual(end, .outcome(.incomplete(text: "PROTOCOL-MARKER minutes")))
            XCTAssertFalse(String(describing: LocalModelOutcome.incomplete(text: "PROTOCOL-MARKER")).contains("MARKER"))
            let lines = bench.diagnostics.lines.map(\.line)
            XCTAssertTrue(lines.contains { $0.hasPrefix("local_model_phase job=none phase=writing") })
            for line in lines {
                XCTAssertFalse(line.contains("MARKER"), line)
            }
        }

        func testExitStatusesMatchTheHelperReadme() throws {
            let readme = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("tools/local-llm-helper/README.md")
            let rows = try String(contentsOf: readme, encoding: .utf8).split(separator: "\n").compactMap { line -> (String, Int32)? in
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard cells.count >= 2, let status = Int32(cells[0]) else { return nil }
                return (cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`")), status)
            }
            let mirrored: [String: LocalModelHelperExitStatus] = [
                "written": .written, "failure": .failure, "incomplete": .incomplete,
                "model-unusable": .modelUnusable, "prompt-too-long": .promptTooLong, "terminated": .terminated,
            ]

            XCTAssertEqual(Dictionary(rows) { first, _ in first }, mirrored.mapValues(\.rawValue))
        }

        func testOnlyContractLinesAreParsed() {
            let cases: [(line: String, expected: LocalModelHelperLine?)] = [
                ("progress phase=loading", .loading),
                ("progress phase=prefill chunk=2 total=7", .prefill(chunk: 2, total: 7)),
                ("progress phase=writing tokens=64", .writing(tokens: 64)),
                ("lifecycle event=prompt tokens=900 context=32768 output=16000", .prompt(tokens: 900, contextLimit: 32768, outputLimit: 16000)),
                ("lifecycle event=started", nil),
                ("progress phase=writing", nil),
                ("progress phase=writing tokens=many", nil),
                ("progress phase=writing tokens=5 the words", nil),
                ("Alice: progress phase=loading", nil),
            ]
            for (line, expected) in cases {
                XCTAssertEqual(LocalModelHelperLine.parse(line), expected, line)
            }
        }

        /// A cancellation wins over everything; any other stop the app asked
        /// for loses to an exit that carries text, and explains the rest.
        func testWhichEndWinsWhenTheAppAskedForAStop() {
            let cases: [(LocalModelHelperRunner.Termination, LocalModelStopReason?, Bool, LocalModelTestEnd)] = [
                (.exited(0), .cancelled, true, .cancelled),
                (.exited(10), .recording, true, .outcome(.incomplete(text: "Text"))),
                (.exited(13), .recording, true, .outcome(.deferredForRecording)),
                (.signalled(SIGKILL), .deadline(.total), false, .outcome(.deadline(.total))),
                (.exited(1), nil, false, .outcome(.noModel)),
            ]
            for (termination, reason, reachable, expected) in cases {
                let result = LocalModelOutcome.resolve(termination, stopReason: reason, text: "Text") { reachable }
                XCTAssertEqual(LocalModelTestEnd(result), expected, "\(termination) \(String(describing: reason))")
            }
        }

        func testFactoryBuildsTheLocalGeneratorFromTheFolderChosenWhenItIsMade() throws {
            let scratch = try makeTempDirectory(prefix: "LocalModelFactory")
            let (first, second) = (scratch.appendingPathComponent("first"), scratch.appendingPathComponent("second"))
            for folder in [first, second] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            let suite = "LocalModelGeneratorTests-\(getpid())-\(UUID().uuidString)"
            addTeardownBlock { DefaultsSuite.remove(suite) }
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let settings = AppSettings(defaults: defaults, defaultOutputDir: scratch.appendingPathComponent("output"))
            settings.protocolProvider = .localModel
            settings.setLocalModelFolder(first)
            let controller = PipelineController(
                settings: settings, notifier: RecordingNotifier(), queueEnvironment: IsolatedQueueEnvironment.make(logDir: scratch),
            )

            let generator = try XCTUnwrap(controller.makeProtocolGenerator() as? LocalModelProtocolGenerator)
            settings.setLocalModelFolder(second)
            let later = try XCTUnwrap(controller.makeProtocolGenerator() as? LocalModelProtocolGenerator)

            XCTAssertEqual(generator.folder.path, first.path)
            XCTAssertEqual(later.folder.path, second.path)
            XCTAssertNotNil(later.folder.bookmark)
            XCTAssertTrue(generator.gate === controller.localModelGate && later.gate === controller.localModelGate)
            let reread = AppSettings(defaults: defaults, defaultOutputDir: scratch.appendingPathComponent("output"))
            XCTAssertEqual(reread.localModelFolder.path, second.path)
        }

        func testLocalModelSendsTheTranscriptNowhereButThisMac() {
            XCTAssertEqual(
                ProtocolDestination.resolve(provider: .localModel, openAIEndpoint: "https://api.example.com/v1"),
                .local(host: "this Mac"),
            )
        }

        func testRunDirectoriesOfEndedProcessesAreRemovedAtLaunch() throws {
            let parent = try makeTempDirectory(prefix: "LocalModelLeftovers")
            let ended = Process()
            ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try ended.run()
            ended.waitUntilExit()
            let prefix = LocalModelRunDirectory.namePrefix
            // An ended process, this process, launchd (another user's, so alive), no pid, not ours.
            let names = ["\(prefix)\(ended.processIdentifier)-A", "\(prefix)\(getpid())-B", "\(prefix)1-C", "\(prefix)junk", "other-\(ended.processIdentifier)"]
            for name in names {
                try FileManager.default.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: false)
            }
            let diagnostics = RecordingDiagnostics()

            _ = LocalModelGate(configuration: .init(runDirectoryParent: parent, diagnostics: diagnostics))

            XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: parent.path)), Set(names.dropFirst()))
            XCTAssertEqual(diagnostics.lines(.notice, startingWith: "local_model_leftovers"), ["local_model_leftovers removed=1"])
        }
    #endif
}

#if !APPSTORE

    struct LocalModelBenchTimeout: Error {
        let waitingFor: String
    }

    /// How a generation ended, comparable in a test.
    enum LocalModelTestEnd: Equatable {
        case written(String)
        case outcome(LocalModelOutcome)
        case cancelled
        case other(String)

        init(_ result: Result<String, any Error>) {
            switch result {
            case let .success(text): self = .written(text)
            case let .failure(outcome as LocalModelOutcome): self = .outcome(outcome)
            case .failure(is CancellationError): self = .cancelled
            case let .failure(error): self = .other(String(describing: error))
            }
        }
    }

    extension LocalModelMemoryReading {
        /// Far above both of the guard's thresholds.
        static let plenty = LocalModelMemoryReading(pressure: .normal, availableBytes: 64 << 30)
    }

    /// Memory readings a test sets, for the gate's admission check and its watchdog.
    final class FakeMemoryProbe: LocalModelMemoryProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var current = LocalModelMemoryReading.plenty

        var reading: LocalModelMemoryReading {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }

        func read() -> LocalModelMemoryReading {
            reading
        }
    }

    extension LocalModelLimits {
        /// Short enough for a test, with the default context and output limits.
        static func fast(totalDeadline: Duration = .seconds(30), noProgressDeadline: Duration = .seconds(30)) -> Self {
            LocalModelLimits(
                totalDeadline: totalDeadline,
                noProgressDeadline: noProgressDeadline,
                killGrace: .milliseconds(500),
                quitGrace: .milliseconds(300),
                pollInterval: .milliseconds(50),
                drainAfterExit: .milliseconds(500),
            )
        }
    }

    /// A scratch world for one test: a model folder with a small weights file,
    /// a parent for run directories, and a gate over them with injected
    /// memory readings and recorded log lines.
    @MainActor
    struct LocalModelTestBench {
        static let weightBytes: UInt64 = 1024
        static let language = "English"
        static let instructions = ProtocolInstructions(template: "Minutes in {LANGUAGE}.", background: nil)

        let scratch: URL
        let modelFolder: URL
        let runParent: URL
        let probe = FakeMemoryProbe()
        let diagnostics = RecordingDiagnostics()
        let gate: LocalModelGate

        init(scratch: URL, limits: LocalModelLimits = .fast()) throws {
            self.scratch = scratch
            modelFolder = scratch.appendingPathComponent("model", isDirectory: true)
            runParent = scratch.appendingPathComponent("runs", isDirectory: true)
            for folder in [modelFolder, runParent] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            try Data(count: Int(Self.weightBytes)).write(to: modelFolder.appendingPathComponent("model.safetensors"))
            gate = LocalModelGate(configuration: .init(
                memoryProbe: probe, limits: limits, runDirectoryParent: runParent, diagnostics: diagnostics,
            ))
        }

        /// A fake helper: it reads the request from stdin into `$req` and its
        /// output path into `$out`, then runs `body`.
        func helper(_ body: String) throws -> URL {
            let url = scratch.appendingPathComponent("helper-\(UUID().uuidString)")
            let script = """
            #!/bin/sh
            req=$(cat)
            out=$(printf '%s' "$req" | sed -n 's/.*"outputPath":"\\([^"]*\\)".*/\\1/p')
            \(body)

            """
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        /// One generation with `helper` and the bench's model folder unless
        /// `folder` names another.
        func end(_ helper: URL?, transcript: String = "Alice: hello", folder: LocalModelFolderSelection? = nil) async -> LocalModelTestEnd {
            let generator = LocalModelProtocolGenerator(
                folder: folder ?? LocalModelFolderSelection(path: modelFolder.path, bookmark: nil),
                language: Self.language,
                gate: gate,
            ) { helper }
            do {
                return try await .written(generator.generate(
                    transcript: transcript, title: "Weekly", diarized: true, meetingStartTime: nil, instructions: Self.instructions,
                ))
            } catch {
                return LocalModelTestEnd(.failure(error))
            }
        }

        var runDirectoryNames: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: runParent.path)) ?? []
        }

        func contents(of file: URL) throws -> String {
            try String(contentsOf: file, encoding: .utf8)
        }

        /// The pid a helper wrote to `file` once it runs (`echo $$ > file`).
        func pid(writtenTo file: URL) async throws -> pid_t {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if let text = try? contents(of: file), text.hasSuffix("\n"), let pid = pid_t(text.dropLast()) { return pid }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw LocalModelBenchTimeout(waitingFor: "a pid in \(file.lastPathComponent)")
        }

        /// Waits until at least `count` notice lines start with `prefix`.
        func waitForNotices(_ prefix: String, count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while diagnostics.lines(.notice, startingWith: prefix).count < count {
                guard ContinuousClock.now < deadline else { throw LocalModelBenchTimeout(waitingFor: "\(count) \(prefix) lines") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

#endif
