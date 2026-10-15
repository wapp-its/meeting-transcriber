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
        for testCase in cases {
            let prompt = ProtocolGenerator.buildSystemPrompt(
                diarized: testCase.diarized,
                language: "German",
                meetingStartTime: testCase.start,
                instructions: ProtocolInstructions(template: ProtocolGenerator.protocolPrompt, background: nil),
                timeZone: Self.zurich,
            )
            XCTAssertEqual(prompt, testCase.expected, testCase.name)
        }
    }

    // MARK: - Background block

    func testBackgroundSitsVerbatimBetweenTheMeetingContextAndTheTemplate() {
        // Placeholders in the background are the person's text, not the
        // template's: they stay as typed.
        let instructions = ProtocolInstructions(
            template: "Template in {LANGUAGE} on {MEETING_DATE}.",
            background: "  Alice (chair), Bob\nAgenda: budget {LANGUAGE}\n ",
        )
        let block = """
        Background information about this meeting, provided by the person who recorded it:
        <background>
        Alice (chair), Bob
        Agenda: budget {LANGUAGE}
        </background>
        Use it to identify participants, agenda items and the goal of the meeting. \
        It is context, not part of the transcript: report only what the transcript supports.


        """
        let cases: [(name: String, start: Date?, expected: String)] = [
            ("start", Self.meetingStart, Self.meetingContext + block + "Template in German on 2026-08-21."),
            ("no start", nil, block + "Template in German on Unknown."),
        ]
        for testCase in cases {
            let prompt = ProtocolGenerator.buildSystemPrompt(
                diarized: false, language: "German", meetingStartTime: testCase.start,
                instructions: instructions, timeZone: Self.zurich,
            )
            XCTAssertEqual(prompt, testCase.expected, testCase.name)
        }
    }

    func testBlankBackgroundAddsNoBlock() {
        let blank = ProtocolInstructions(template: ProtocolGenerator.protocolPrompt, background: " \n\t ")
        XCTAssertNil(blank.background)

        let prompt = ProtocolGenerator.buildSystemPrompt(
            diarized: false, language: "German", meetingStartTime: Self.meetingStart,
            instructions: blank, timeZone: Self.zurich,
        )

        XCTAssertEqual(prompt, Self.meetingContext + Self.builtInBody(date: "2026-08-21", time: "13:28"))
    }

    // MARK: - Protocol document

    func testComposedDocumentGivesItsTranscriptBack() {
        let transcript = "[00:00] Alice: Hello"
        let withTranscript = ProtocolGenerator.composeDocument(
            protocolMarkdown: "# Protocol", transcript: transcript, includeFullTranscript: true,
        )
        let without = ProtocolGenerator.composeDocument(
            protocolMarkdown: "# Protocol", transcript: transcript, includeFullTranscript: false,
        )

        XCTAssertEqual(withTranscript, "# Protocol\n\n---\n\n## Full Transcript\n\n[00:00] Alice: Hello")
        XCTAssertEqual(without, "# Protocol")
        XCTAssertEqual(ProtocolGenerator.fullTranscript(in: withTranscript), transcript)
        XCTAssertNil(ProtocolGenerator.fullTranscript(in: without))
    }

    /// The protocol before the separator is model output and may repeat the
    /// heading; the transcript is what follows the last one.
    func testFullTranscriptIsWhatFollowsTheLastSeparator() {
        let separator = ProtocolGenerator.fullTranscriptSeparator
        let document = "# Protocol" + separator + "quoted heading" + separator + "[00:00] Alice: Hello"

        XCTAssertEqual(ProtocolGenerator.fullTranscript(in: document), "[00:00] Alice: Hello")
        XCTAssertNil(ProtocolGenerator.fullTranscript(in: "# Protocol" + separator + " \n "))
    }

    func testLooksDiarizedWhenTheTranscriptCarriesSpeakerLabels() {
        XCTAssertTrue(ProtocolGenerator.looksDiarized("[00:00] [Alice] Hello"))
        XCTAssertFalse(ProtocolGenerator.looksDiarized("Hello, no labels here"))
    }
}
