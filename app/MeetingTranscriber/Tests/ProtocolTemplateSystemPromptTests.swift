@testable import MeetingTranscriber
import XCTest

/// The system prompt a protocol provider receives. The four expected strings
/// below were recorded from the code before protocol templates existed, so a
/// job using the built-in template and no background still sends exactly what
/// it sent then.
final class ProtocolTemplateSystemPromptTests: XCTestCase {
    private static let zurich = TimeZone(identifier: "Europe/Zurich") ?? .gmt

    /// 2026-08-21 13:28 in Zurich.
    private static let meetingStart = Date(timeIntervalSince1970: 1_787_311_680)

    private static let meetingContext = """
    Meeting metadata:
    Date: 2026-08-21
    Time: 13:28
    The date and time above are authoritative. Interpret relative time expressions
    in the transcript relative to this meeting date. Do not rely on the model's
    assumed current date.


    """

    private static let diarizationNote = """

    Note: The transcript contains speaker labels in brackets. Possible label formats:
    - [SPEAKER_00], [SPEAKER_01] — auto-detected speakers (use Speaker 1, Speaker 2)
    - [Me], [Roman] etc. — the local microphone user
    - [Remote] — remote participant(s) without diarization
    - [Name] — a recognized or named speaker
    Use these labels to identify participants. In the Participants section, list them by name where possible. \
    In the Topics Discussed section, attribute key statements to speakers.
    """

    private static func builtInBody(date: String, time: String) -> String {
        """
        You are a professional meeting minute taker.
        Create a structured meeting protocol in German from the following transcript.

        Return ONLY the finished Markdown document - no explanations, no introduction,
        no comments before or after.

        Use exactly this structure:

        # Meeting Protocol - [Meeting Title]
        **Date:** \(date)
        **Time:** \(time)

        ---

        ## Summary
        [3-5 sentence summary of the meeting]

        ## Participants
        - [Name 1]
        - [Name 2]

        ## Topics Discussed

        ### [Topic 1]
        [What was discussed]

        ### [Topic 2]
        [What was discussed]

        ## Decisions
        - [Decision 1]
        - [Decision 2]

        ## Tasks
        | Task | Responsible | Deadline | Priority |
        |------|-------------|----------|----------|
        | [Description] | [Name] | [Date or open] | 🔴 high / 🟡 medium / 🟢 low |

        ## Open Questions
        - [Question 1]
        - [Question 2]

        Do NOT include the full transcript in the output.

        ---
        Transcript:
        """
    }

    func testBuiltInTemplateWithoutBackgroundSendsThePreTemplatePrompt() {
        let withStart = Self.meetingContext + Self.builtInBody(date: "2026-08-21", time: "13:28")
        let withoutStart = Self.builtInBody(date: "Unknown", time: "Unknown")
        let cases: [(name: String, diarized: Bool, start: Date?, expected: String)] = [
            ("start, plain", false, Self.meetingStart, withStart),
            ("start, diarized", true, Self.meetingStart, withStart + Self.diarizationNote),
            ("no start, plain", false, nil, withoutStart),
            ("no start, diarized", true, nil, withoutStart + Self.diarizationNote),
        ]
        // Never created, so the pre-template code falls back to the built-in
        // prompt instead of reading the developer's own custom prompt file.
        let missingPrompt = makeTempFile(suffix: ".md")
        for testCase in cases {
            let prompt = ProtocolGenerator.buildSystemPrompt(
                diarized: testCase.diarized,
                language: "German",
                meetingStartTime: testCase.start,
                promptURL: missingPrompt,
                timeZone: Self.zurich,
            )
            XCTAssertEqual(prompt, testCase.expected, testCase.name)
        }
    }
}
