#if !APPSTORE

    @testable import MeetingTranscriber
    import XCTest

    /// The summary call against the real providers that run a program (spec R5, R8):
    /// a custom command gets the instruction on stdin or through `{prompt_file}` and
    /// none with only `{transcript_file}`, and a local model's call yields to meeting
    /// notes at the gate. Fake programs and helpers only; every note is made up.
    @MainActor
    final class MeetingSummaryProviderTests: XCTestCase {
        private static let notes = "# Notes\n\n## Decisions\n- Ship on Friday"
        private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

        private func makeSummarizer() throws -> MeetingSummarizer {
            let path = try makeTempDirectory(prefix: "summary-provider").appendingPathComponent(MeetingSummaryStore.filename)
            return MeetingSummarizer(store: MeetingSummaryStore(path: path)) { [date] in date }
        }

        private func program(_ body: String, in folder: URL) throws -> URL {
            let url = folder.appendingPathComponent("fake-\(UUID().uuidString).sh")
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        // MARK: - Custom command

        /// Stdin and `{prompt_file}` receive the instruction in the notes language and the
        /// notes; a command reading only `{transcript_file}` is never started.
        func testACustomCommandGetsTheInstructionUnlessItReadsOnlyTheTranscriptFile() async throws {
            let folder = try makeTempDirectory(prefix: "summary-command")
            let received = folder.appendingPathComponent("received")
            let started = folder.appendingPathComponent("started")
            let fromStdin = try program("cat > '\(received.path)'; echo 'Plan agreed.'", in: folder)
            let fromFile = try program("cp \"$1\" '\(received.path)'; echo 'Plan agreed.'", in: folder)
            let transcriptOnly = try program("touch '\(started.path)'; cat \"$1\"", in: folder)
            let instruction = MeetingSummary.instruction.replacingOccurrences(of: "{LANGUAGE}", with: "German")

            for arguments in [[fromStdin.path], [fromFile.path, "{prompt_file}"]] {
                let summarizer = try makeSummarizer()
                let job = UUID()
                let command = CommandProtocolGenerator.custom(arguments: arguments, model: "", language: "German")

                summarizer.notesSaved(jobID: job, notes: .text(Self.notes), title: "Sync") { command }
                await summarizer.awaitCalls()

                XCTAssertEqual(try String(contentsOf: received, encoding: .utf8), instruction + Self.notes, "\(arguments)")
                XCTAssertEqual(summarizer.store.summaries(for: job)?.notes?.text, "Plan agreed.")
            }

            let summarizer = try makeSummarizer()
            let command = CommandProtocolGenerator.custom(arguments: [transcriptOnly.path, "{transcript_file}"], model: "", language: "German")
            summarizer.notesSaved(jobID: UUID(), notes: .text(Self.notes), title: "Sync") { command }
            await summarizer.awaitCalls()

            XCTAssertFalse(FileManager.default.fileExists(atPath: started.path))
            XCTAssertEqual(summarizer.store.summaries, [:])
        }

        // MARK: - Local model

        /// A summary call holding the local model is cancelled by a notes request, which
        /// then runs; the summary stores nothing.
        func testANotesRequestCancelsARunningSummaryCall() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "summary-gate"))
            let started = bench.scratch.appendingPathComponent("started")
            let summaryHelper = try bench.helper("trap 'exit 13' TERM; echo $$ > '\(started.path)'; while :; do sleep 0.05; done")
            let notesHelper = try bench.helper(#"printf 'Protocol' > "$out""#)
            let summarizer = try makeSummarizer()
            let job = UUID()

            summarizer.notesSaved(jobID: job, notes: .text(Self.notes), title: "Sync") { [bench] in
                LocalModelProtocolGenerator(
                    folder: LocalModelFolderSelection(path: bench.modelFolder.path, bookmark: nil), language: "English", gate: bench.gate,
                ) { summaryHelper }
            }
            _ = try await bench.pid(writtenTo: started)
            let notes = await LocalModelGate.$jobID.withValue(UUID()) { await bench.end(notesHelper) }
            await summarizer.awaitCalls()

            XCTAssertEqual(notes, .written("Protocol"))
            XCTAssertEqual(bench.diagnostics.lines(.notice, startingWith: "local_model_yield").count, 1)
            XCTAssertEqual(summarizer.store.summaries, [:])
        }

        /// While notes run, a summary call waits, also behind notes that came after it;
        /// it runs once the model is free.
        func testASummaryCallWaitsWhileNotesRunOrWait() async throws {
            let bench = try LocalModelTestBench(scratch: makeTempDirectory(prefix: "summary-gate"))
            let events = bench.scratch.appendingPathComponent("events")
            let release = bench.scratch.appendingPathComponent("release")
            let started = bench.scratch.appendingPathComponent("started")
            let firstNotes = try bench.helper("""
            echo $$ > '\(started.path)'
            echo notes1 >> '\(events.path)'
            while [ ! -e '\(release.path)' ]; do sleep 0.05; done
            printf 'Protocol' > "$out"
            """)
            let secondNotes = try bench.helper("echo notes2 >> '\(events.path)'; printf 'Protocol' > \"$out\"")
            let summaryHelper = try bench.helper("echo summary >> '\(events.path)'; printf 'Plan agreed.' > \"$out\"")
            let summarizer = try makeSummarizer()
            let job = UUID()

            let first = Task { await LocalModelGate.$jobID.withValue(UUID()) { await bench.end(firstNotes) } }
            _ = try await bench.pid(writtenTo: started)
            summarizer.notesSaved(jobID: job, notes: .text(Self.notes), title: "Sync") { [bench] in
                LocalModelProtocolGenerator(
                    folder: LocalModelFolderSelection(path: bench.modelFolder.path, bookmark: nil), language: "English", gate: bench.gate,
                ) { summaryHelper }
            }
            try await bench.waitForNotices("local_model_waiting", count: 1)
            let second = Task { await LocalModelGate.$jobID.withValue(UUID()) { await bench.end(secondNotes) } }
            try await bench.waitForNotices("local_model_waiting", count: 2)
            FileManager.default.createFile(atPath: release.path, contents: nil)
            let ends = await [first.value, second.value]
            await summarizer.awaitCalls()

            XCTAssertEqual(ends, [.written("Protocol"), .written("Protocol")])
            XCTAssertEqual(try bench.contents(of: events), "notes1\nnotes2\nsummary\n")
            XCTAssertEqual(summarizer.store.summaries(for: job)?.notes?.text, "Plan agreed.")
        }
    }

#endif
