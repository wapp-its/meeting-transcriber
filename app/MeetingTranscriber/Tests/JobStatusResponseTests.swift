#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The `/v1` wire shape is a stability contract. `JobStatusResponse` flattens
    /// the persisted `JobStatusDTO` plus an opt-in inline `transcript` onto one
    /// JSON object (issue #431). These lock that: with no transcript the bytes are
    /// exactly a `JobStatusDTO` (no `transcript` key), so a client sees no change
    /// unless it passes `?include=transcript`; with one it is a top-level sibling.
    final class JobStatusResponseTests: XCTestCase {
        private let dto = JobStatusDTO(
            jobID: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
            state: .done,
            meetingTitle: "Daily Standup",
            transcriptPath: "/out/call.txt",
            protocolPath: nil,
            error: nil,
            warnings: [],
        )

        func testTranscriptKeyOmittedWhenNil() throws {
            let json = try XCTUnwrap(String(data: JSONEncoder().encode(JobStatusResponse(dto, transcript: nil)), encoding: .utf8))
            XCTAssertFalse(json.contains("\"transcript\""), "nil transcript must not appear in the JSON: \(json)")
            // The status fields are flattened onto the same object, not nested.
            XCTAssertTrue(json.contains("\"jobID\""))
            XCTAssertTrue(json.contains("\"transcriptPath\""))
            XCTAssertFalse(json.contains("\"status\""), "the base DTO must be flattened, not nested under a key")
        }

        func testTranscriptIsATopLevelSiblingWhenSet() throws {
            let data = try JSONEncoder().encode(JobStatusResponse(dto, transcript: "[00:00] S1: hello"))
            // Decodes back into the same envelope: status fields + transcript.
            let decoded = try JSONDecoder().decode(JobStatusResponse.self, from: data)
            XCTAssertEqual(decoded.transcript, "[00:00] S1: hello")
            XCTAssertEqual(decoded.status, dto)
            // And a plain JobStatusDTO decode still sees the flattened status fields.
            XCTAssertEqual(try JSONDecoder().decode(JobStatusDTO.self, from: data), dto)
        }

        /// A recording carries its start; an import has none and the key stays off the wire.
        func testMeetingStartedAtIsSentForARecordingAndOmittedForAnImport() throws {
            let recording = PipelineJob(
                meetingTitle: "Standup", appName: "Teams",
                mixPath: URL(fileURLWithPath: "/rec/mix.wav"), appPath: nil, micPath: nil, micDelay: 0,
                meetingStartTime: Date(timeIntervalSince1970: 1_760_000_000),
            )
            let imported = PipelineJob(
                meetingTitle: "call", appName: "File",
                mixPath: URL(fileURLWithPath: "/in/call.m4a"), appPath: nil, micPath: nil, micDelay: 0,
            )

            let sent = try wireObject(JobStatusDTO(job: recording))
            let omitted = try wireObject(JobStatusDTO(job: imported))

            XCTAssertEqual(sent["meetingStartedAt"] as? String, "2025-10-09T08:53:20Z")
            XCTAssertNil(omitted["meetingStartedAt"], "an import has no recording start: \(omitted)")
        }

        private func wireObject(_ status: JobStatusDTO) throws -> [String: Any] {
            let data = try JSONEncoder().encode(JobStatusResponse(status, transcript: nil))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }
#endif
