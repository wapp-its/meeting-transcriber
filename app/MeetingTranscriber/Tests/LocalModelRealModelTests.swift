#if !APPSTORE

    @testable import MeetingTranscriber
    import XCTest

    /// The local model with real weights, through the app's own generator, gate
    /// and memory guard: one protocol from a synthetic transcript, and a
    /// recording started through the automation API while the model writes.
    ///
    /// Skipped unless `LOCAL_LLM_HELPER_TEST_MODEL` names a model folder, the
    /// variable the helper package's real-model tests read, so one setting runs
    /// both. The helper must be built first (`swift build -c release` in
    /// `tools/local-llm-helper`). Each test loads the model's weights (about
    /// 17 GB for the tested 27B 4-bit model) and runs for a minute or more.
    ///
    /// The helper runs under `sandbox-exec` with every network operation
    /// denied, so a written protocol shows it needs no network. A refusal by
    /// the memory guard skips with the readings behind it: the Mac had no room
    /// for the model then, which says nothing about the model path.
    @MainActor
    final class LocalModelRealModelTests: XCTestCase {
        private static let environmentKey = "LOCAL_LLM_HELPER_TEST_MODEL"
        private static let noNetworkProfile = "(version 1)(allow default)(deny network*)"
        private static let token = "real-model-test-token"
        private static let transcript = """
        [00:00:02] Anna: Good morning. Today we decide when the new booking page goes live and who tests it.
        [00:00:09] Ben: The page is finished except for the payment step. The payment provider needs two more days.
        [00:00:17] Anna: Then the launch moves from Monday to Thursday. Ben, does that hold?
        [00:00:22] Ben: Thursday holds if the provider delivers on Tuesday.
        [00:00:27] Chris: I can test on Wednesday, the whole day. I need test accounts for the payment step.
        [00:00:34] Ben: I will create three test accounts today and send them to Chris.
        [00:00:39] Anna: Good. Who tells the support team about the new date?
        [00:00:43] Chris: I do that this afternoon, together with a short guide for the new page.
        [00:00:49] Anna: One open point: the old page stays online for a week after the launch, as a fallback.
        [00:00:56] Ben: Agreed. I will switch it off on the Thursday after.
        [00:01:01] Anna: Then we have it. Launch on Thursday, testing on Wednesday, support informed today.
        """

        func testRealModelWritesAProtocolWithoutThinkingOrNetwork() async throws {
            let folder = try modelFolder()
            let scratch = try makeTempDirectory(prefix: "LocalModelRealModel")
            let helper = try sandboxedHelper(in: scratch)
            try assertTheProfileDeniesNetwork()
            let diagnostics = RecordingDiagnostics()
            // The system's memory readings and the production limits; only the
            // log lines are recorded, and the run directory is the test's own.
            let gate = LocalModelGate(configuration: .init(runDirectoryParent: scratch, diagnostics: diagnostics))

            let text = try await generate(with: gate, folder: folder, helper: helper.wrapper)

            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("<think>") || text.contains("</think>"), "thinking text in the protocol")
            let lifecycle = diagnostics.lines.map(\.line).joined(separator: "\n")
            print("Real model run: \(text.count) characters written. Lifecycle lines:\n\(lifecycle)")
        }

        /// The gate is the one the pipeline holds and the recording comes
        /// through `POST /v1/record`, so this is the path a recording started
        /// by a hotkey or Stream Deck takes in the app.
        func testRecordingStartedThroughTheAutomationAPIEndsTheHelperWithinFiveSeconds() async throws {
            let folder = try modelFolder()
            let scratch = try makeTempDirectory(prefix: "LocalModelRealModel")
            let helper = try sandboxedHelper(in: scratch)
            let controller = makeWatchingController(logDir: scratch, permissionHealth: .allHealthy)
            addTeardownBlock { await controller.stopManualRecording() }
            let api = try await automationAPI(recordingWith: controller)
            let gate = controller.pipeline.localModelGate
            let generation = GenerationRun { try await self.generate(with: gate, folder: folder, helper: helper.wrapper) }
            // A test that fails before the helper ended must not leave the
            // model loaded for the tests after it.
            addTeardownBlock { await generation.cancelAndWait() }

            guard let pid = try await waitForWriting(helper.started, or: generation) else { return }
            let recordingStart = ContinuousClock.now
            let status = try await post(["action": "start"], to: api.appendingPathComponent("v1/record"))
            try await waitUntil("the helper to end") { kill(pid, 0) != 0 }
            let elapsed = ContinuousClock.now - recordingStart

            XCTAssertEqual(status, 200)
            XCTAssertTrue(controller.isRecordingMicrophoneOnly, "the recording did not start")
            XCTAssertLessThan(elapsed, .seconds(5))
            try await waitUntil("the generation to end") { generation.result != nil }
            XCTAssertEqual(try LocalModelTestEnd(XCTUnwrap(generation.result)), .outcome(.deferredForRecording))
            print("Real model run: the helper ended \(elapsed) after POST /v1/record started a recording.")
        }

        // MARK: - Helpers

        private func modelFolder() throws -> URL {
            let path = ProcessInfo.processInfo.environment[Self.environmentKey] ?? ""
            try XCTSkipIf(path.isEmpty, "set \(Self.environmentKey) to a model folder to run this test")
            return URL(fileURLWithPath: path)
        }

        /// The helper `swift build -c release` produced in this checkout.
        private static var builtHelper: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("tools/local-llm-helper/.build/release/local-llm-helper")
        }

        /// A wrapper the generator starts in place of the helper. It notes its
        /// pid and working directory (the private run directory), then becomes
        /// the built helper, under a sandbox profile that denies every network
        /// operation. `sandbox-exec` execs in place, so the pid is the helper's.
        private func sandboxedHelper(in scratch: URL) throws -> (wrapper: URL, started: URL) {
            let helper = try XCTUnwrap(
                FileManager.default.isExecutableFile(atPath: Self.builtHelper.path) ? Self.builtHelper : nil,
                "no helper at \(Self.builtHelper.path); build it with `swift build -c release` in tools/local-llm-helper",
            )
            let wrapper = scratch.appendingPathComponent("sandboxed-helper")
            let started = scratch.appendingPathComponent("started")
            let script = """
            #!/bin/sh
            printf '%s\\n%s\\n' "$$" "$PWD" > '\(started.path).tmp' && mv '\(started.path).tmp' '\(started.path)'
            exec /usr/bin/sandbox-exec -p '\(Self.noNetworkProfile)' '\(helper.path)' "$@"

            """
            try script.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            return (wrapper, started)
        }

        /// One protocol with the app's default prompt; a refusal by the memory
        /// guard, at the start or from its watchdog, skips the test.
        private func generate(with gate: LocalModelGate, folder: URL, helper: URL) async throws -> String {
            let generator = LocalModelProtocolGenerator(
                folder: LocalModelFolderSelection(path: folder.path, bookmark: nil), language: "English", gate: gate,
            ) { helper }
            do {
                return try await generator.generate(
                    transcript: Self.transcript, title: "Booking page launch", diarized: true, meetingStartTime: nil,
                    instructions: ProtocolInstructions(template: ProtocolGenerator.protocolPrompt, background: nil),
                )
            } catch let LocalModelOutcome.lowMemory(reading) {
                throw XCTSkip("the app's memory guard refused the run: \(reading.logFields)")
            }
        }

        /// The helper's pid once it has written its first protocol text. A
        /// generation that fails first rethrows its error (a memory guard
        /// refusal skips); one that finishes first fails the test and gives nil.
        private func waitForWriting(_ started: URL, or generation: GenerationRun) async throws -> pid_t? {
            let deadline = ContinuousClock.now + .seconds(300)
            while ContinuousClock.now < deadline {
                if let result = generation.result {
                    _ = try result.get()
                    XCTFail("the protocol was finished before a recording could start")
                    return nil
                }
                if let lines = try? String(contentsOf: started, encoding: .utf8).split(separator: "\n"), lines.count == 2,
                   let pid = pid_t(lines[0]) {
                    let output = URL(fileURLWithPath: String(lines[1])).appendingPathComponent("protocol.md")
                    let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
                    if size > 0 { return pid }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw LocalModelBenchTimeout(waitingFor: "the helper to write")
        }

        /// The automation API in this process, its record control wired to
        /// `controller` the way the app wires it.
        private func automationAPI(recordingWith controller: WatchingController) async throws -> URL {
            let server = DebugRPCServer(
                port: 0, token: Self.token, snapshot: { .empty },
                recordControl: { action in await controller.applyRecordAction(action) },
            )
            server.start()
            addTeardownBlock { await server.stop() }
            for _ in 0 ..< 100 {
                if let port = server.boundPort, let url = URL(string: "http://127.0.0.1:\(port)") { return url }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw LocalModelBenchTimeout(waitingFor: "the automation API to listen")
        }

        private func post(_ body: [String: String], to url: URL) async throws -> Int {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }

        /// The profile is what makes the protocol evidence of no network use,
        /// so it is checked first: `nc` reaches a listener on the loopback
        /// interface without it and does not reach it under it.
        private func assertTheProfileDeniesNetwork() throws {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(listener, 0)
            defer { close(listener) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let listening = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(listener, socketAddress, length) == 0 && Darwin.listen(listener, 4) == 0
                        && getsockname(listener, socketAddress, &length) == 0
                }
            }
            XCTAssertTrue(listening, "no loopback listener")
            let probe = ["/usr/bin/nc", "-z", "-G", "2", "127.0.0.1", String(UInt16(bigEndian: address.sin_port))]

            XCTAssertEqual(try exitStatus(probe), 0, "nc cannot reach the listener even without the profile")
            XCTAssertNotEqual(try exitStatus(["/usr/bin/sandbox-exec", "-p", Self.noNetworkProfile] + probe), 0, "the profile lets nc connect")
        }

        private func exitStatus(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: arguments[0])
            process.arguments = Array(arguments.dropFirst())
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    /// One generation the test runs in the background, so it can watch the
    /// helper while it writes and read how the generation ended.
    @MainActor
    private final class GenerationRun {
        private(set) var result: Result<String, any Error>?
        private var task: Task<Void, Never>?

        /// Starts `body` in a task of its own.
        init(_ body: @escaping @MainActor () async throws -> String) {
            task = Task { await self.finish(body) }
        }

        /// Cancels the generation, which ends its helper, and returns once it
        /// has ended. Nothing to do for one that has already ended.
        func cancelAndWait() async {
            task?.cancel()
            await task?.value
        }

        private func finish(_ body: () async throws -> String) async {
            do {
                result = try await .success(body())
            } catch {
                result = .failure(error)
            }
        }
    }

#endif
