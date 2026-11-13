@testable import MeetingTranscriber
import XCTest

final class MeetingPromptMetadataTests: XCTestCase {
    func testApplyVariablesUsesUnknownForMissingMeetingStart() {
        let result = ProtocolGenerator.applyVariables(
            "{LANGUAGE} {MEETING_DATE} {MEETING_TIME}",
            language: "German",
            metadata: nil,
        )

        XCTAssertEqual(result, "German Unknown Unknown")
    }

    func testBuildSystemPromptWithoutMeetingStartDoesNotAddAuthority() {
        let prompt = ProtocolGenerator.buildSystemPrompt(
            diarized: false,
            language: "German",
            meetingStartTime: nil,
            instructions: ProtocolInstructions(template: "Date: {MEETING_DATE}; Time: {MEETING_TIME}.", background: nil),
        )

        XCTAssertEqual(prompt, "Date: Unknown; Time: Unknown.")
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("authoritative"))
    }

    /// Given the date alone, a model that does not reason first resolves "next
    /// Friday" to a wrong day, so the metadata names the weekday as well. In
    /// English, like the rest of the metadata block, whatever the protocol language.
    func testMeetingMetadataNamesTheWeekdayNextToTheDate() throws {
        let zurich = try XCTUnwrap(TimeZone(identifier: "Europe/Zurich"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zurich
        let wednesday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 10)))

        let prompt = ProtocolGenerator.buildSystemPrompt(
            diarized: false,
            language: "German",
            meetingStartTime: wednesday,
            instructions: ProtocolInstructions(template: "{MEETING_DATE}", background: nil),
            timeZone: zurich,
        )

        XCTAssertTrue(prompt.contains("\nDate: 2026-10-07 (Wednesday)\n"), prompt)
        XCTAssertTrue(prompt.hasSuffix("\n\n2026-10-07"), "the template variable keeps the bare date: \(prompt)")
    }
}
