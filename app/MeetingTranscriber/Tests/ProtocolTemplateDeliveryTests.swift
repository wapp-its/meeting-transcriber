#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// What the Claude CLI receives on stdin for a job with a template and
    /// background info, through a `#!/bin/sh` fake that records its input.
    final class ProtocolTemplateDeliveryTests: XCTestCase {
        func testClaudeCLIReceivesTheTemplateAndBackgroundOnStdin() async throws {
            let dir = try makeTempDirectory(prefix: "protocol-template-delivery")
            let received = dir.appendingPathComponent("stdin")
            let script = dir.appendingPathComponent("fake-claude.sh")
            try """
            #!/bin/sh
            cat > '\(received.path)'
            printf '%s\\n' '{"type":"content_block_delta","delta":{"type":"text_delta","text":"Protocol body"}}'
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            let result = try await ClaudeCLIProtocolGenerator(claudeBin: script.path, language: "German").generate(
                transcript: "Speaker 1: hello", title: "Sync", diarized: false, meetingStartTime: nil,
                instructions: ProtocolInstructions(template: "Board template in {LANGUAGE}.", background: "Alice chairs"),
            )

            XCTAssertEqual(result, "Protocol body")
            XCTAssertEqual(
                try String(contentsOf: received, encoding: .utf8),
                """
                Background information about this meeting, provided by the person who recorded it:
                <background>
                Alice chairs
                </background>
                Use it to identify participants, agenda items and the goal of the meeting. \
                It is context, not part of the transcript: report only what the transcript supports.

                Board template in German.Speaker 1: hello
                """,
            )
        }
    }
#endif
