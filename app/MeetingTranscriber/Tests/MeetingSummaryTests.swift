@testable import MeetingTranscriber
import XCTest

/// The summary rules (spec R8): which section of saved notes is their summary and
/// how it reads once cleaned, what a summary call sends, and what each save does to
/// a meeting's two summaries. Every note and summary here is made up.
final class MeetingSummaryTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - The summary section rule

    /// The built-in template's notes in English and German, with the label lines and
    /// sections around the summary it asks for.
    func testTheBuiltInTemplatesSummarySectionInEnglishAndGerman() {
        let english = """
        # Meeting Notes: Weekly sync

        **Date:** 2026-11-16
        **Participants:** Ana, Ben

        ## Summary
        The team agreed to ship the beta on Friday.
        Ben checks the release notes.

        ## Topics Discussed
        ### Release
        - Beta on Friday
        """
        let german = """
        # Protokoll: Wochenrunde

        ## Zusammenfassung

        Das Team gibt die Beta am Freitag frei.

        ## Besprochene Themen
        - Beta
        """

        XCTAssertEqual(MeetingSummary.section(in: english), "The team agreed to ship the beta on Friday. Ben checks the release notes.")
        XCTAssertEqual(MeetingSummary.section(in: german), "Das Team gibt die Beta am Freitag frei.")
    }

    /// Each notes language the app offers has a heading word the rule finds, compared
    /// without case and diacritics, at any heading level, with a number and a colon.
    func testEveryNotesLanguageHasAHeadingTheRuleFinds() {
        XCTAssertEqual(Set(MeetingSummary.headingNames.keys), Set(AppSettings.protocolLanguages))
        for (language, names) in MeetingSummary.headingNames {
            for name in names {
                let notes = "# Notes\n\n### 1. \(name.uppercased()):\nPlan agreed.\n\n## Next\nOther."
                XCTAssertEqual(MeetingSummary.section(in: notes), "Plan agreed.", "\(language): \(name)")
            }
        }
        XCTAssertEqual(MeetingSummary.section(in: "## Resume\nPlan agreed."), "Plan agreed.", "French without its accents")
        XCTAssertEqual(MeetingSummary.section(in: "## Summary and decisions\nPlan agreed."), "Plan agreed.", "a heading that begins with the name")
    }

    /// A custom template without the section, an executive heading that only ends with
    /// the name, a hashtag that is no heading, and a section the clean-up empties.
    func testNotesWithoutASummarySectionHaveNone() {
        let cases = [
            "# Minutes\n\n## Decisions\n- Ship on Friday",
            "## Executive Summary\nPlan agreed.",
            "#summary Plan agreed.",
            "## Summary\n[3-5 sentence summary of the meeting]\n\n## Topics\nRelease.",
            "## Summary\n\n## Topics\nRelease.",
        ]
        for notes in cases {
            XCTAssertNil(MeetingSummary.section(in: notes), notes)
        }
    }

    /// A list section reads as one paragraph, its markers and Markdown marks gone.
    func testAListSectionReadsAsOneParagraphWithoutItsMarks() {
        let notes = """
        ## Summary
        - Budget **approved** for _Q1_
        * Hiring of a `snake_case` expert
        1. See [the plan](https://example.com/plan) and ~~the old one~~
        > Quoted *remark*
        """

        XCTAssertEqual(
            MeetingSummary.section(in: notes),
            "Budget approved for Q1 Hiring of a snake_case expert See the plan and the old one Quoted remark",
        )
    }

    /// Tables, HTML comments, horizontal rules, label lines and a paragraph wholly in
    /// square brackets are dropped; a paragraph that only begins with one stays.
    func testTheCleanUpDropsWhatIsNoSummaryText() {
        let notes = """
        ## Summary
        <!-- written by the model -->
        **Date:** 2026-11-16
        __Time__: 09:00

        | Topic | Owner |
        |---|---|
        | Beta | Ben |

        ---

        [Write the summary here]

        [Ana] and [Ben] agreed on the plan.
        """

        XCTAssertEqual(MeetingSummary.section(in: notes), "[Ana] and [Ben] agreed on the plan.")
    }

    /// A table without outer pipes is dropped as one with them is; a section that
    /// holds only a table has no summary.
    func testATableWithoutOuterPipesIsDropped() {
        let table = "Topic | Owner\n:--- | ---:\nBudget | Ana\nHiring | Ben"

        XCTAssertEqual(MeetingSummary.section(in: "## Summary\n\(table)\n\nPlan agreed."), "Plan agreed.")
        XCTAssertNil(MeetingSummary.section(in: "## Summary\n\(table)\n\n## Topics\nRelease."))
        XCTAssertEqual(MeetingSummary.section(in: "## Summary\nRelease A | B on Friday."), "Release A | B on Friday.", "a pipe in a sentence")
    }

    /// A heading inside an HTML comment neither starts the section nor ends a real one.
    func testAHeadingInsideAnHTMLCommentIsNoHeading() {
        let commented = "# Notes\n<!--\n## Summary\nHidden template instructions.\n-->\n## Topics\nRelease."
        let inside = "## Summary\nPlan agreed.\n<!-- ## Topics -->\nBen checks the notes.\n\n## Topics\nRelease."

        XCTAssertNil(MeetingSummary.section(in: commented))
        XCTAssertEqual(MeetingSummary.section(in: inside), "Plan agreed. Ben checks the notes.")
    }

    /// An appended full transcript is never read: neither a summary heading inside it
    /// nor its lines after a section that runs to the end of the notes.
    func testAnAppendedFullTranscriptIsNeverPartOfTheSummary() {
        let separator = ProtocolGenerator.fullTranscriptSeparator
        let withoutSection = "# Notes\n## Topics\nRelease." + separator + "## Summary\nAna: hello"
        let sectionAtTheEnd = "# Notes\n## Summary\nPlan agreed." + separator + "Ana: hello"

        XCTAssertNil(MeetingSummary.section(in: withoutSection))
        XCTAssertEqual(MeetingSummary.section(in: sectionAtTheEnd), "Plan agreed.")
    }

    /// Longer than 600 characters: cut at a word end, with "…", 600 at most.
    func testALongSummaryIsCutAtAWordEnd() throws {
        let words = Array(repeating: "decision", count: 80).joined(separator: " ")
        let summary = try XCTUnwrap(MeetingSummary.section(in: "## Summary\n\(words)"))

        XCTAssertLessThanOrEqual(summary.count, MeetingSummary.maxLength)
        XCTAssertTrue(summary.hasSuffix("decision…"), summary)
        XCTAssertEqual(MeetingSummary.cut(String(repeating: "a", count: 600)), String(repeating: "a", count: 600))
    }

    // MARK: - The call's text and answer

    func testTheCallSendsTheNotesWithoutTranscriptCutAtALineEnd() {
        let line = String(repeating: "x", count: 99) + "\n"
        let notes = String(repeating: line, count: 400) + ProtocolGenerator.fullTranscriptSeparator + "Ana: hello"

        let sent = MeetingSummary.notesForCall(notes)

        XCTAssertEqual(sent.count, 31999, "320 lines of 100 characters, without the last line break")
        XCTAssertFalse(sent.contains("Ana"))
        XCTAssertEqual(MeetingSummary.notesForCall("# Notes\nShort."), "# Notes\nShort.")
    }

    /// An answer goes through the clean-up a section does; one left empty is none.
    func testAnAnswerIsCleanedLikeASection() {
        XCTAssertEqual(MeetingSummary.clean("**Summary:** none\n\nThe team *agreed* on the plan.\n"), "The team agreed on the plan.")
        XCTAssertNil(MeetingSummary.clean("  \n---\n"))
        XCTAssertTrue(MeetingSummary.instruction.contains("{LANGUAGE}"))
    }

    // MARK: - Replace or keep

    /// Every notes save point goes through this rule: a found summary replaces the notes
    /// summary and keeps a typed one; none keeps both (A18).
    func testANotesSaveReplacesTheNotesSummaryAndKeepsATypedOne() {
        let earlier = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let typed = MeetingSummaries(notes: .init(text: "Old", writtenAt: earlier), typed: .init(text: "Mine", writtenAt: earlier))

        XCTAssertEqual(
            MeetingSummary.afterNotesSaved(typed, notesSummary: "New", at: date),
            MeetingSummaries(notes: .init(text: "New", writtenAt: date), typed: typed.typed),
        )
        XCTAssertEqual(MeetingSummary.afterNotesSaved(typed, notesSummary: nil, at: date), typed)
        XCTAssertEqual(
            MeetingSummary.afterNotesSaved(nil, notesSummary: "New", at: date),
            MeetingSummaries(notes: .init(text: "New", writtenAt: date)),
        )
        XCTAssertNil(MeetingSummary.afterNotesSaved(nil, notesSummary: nil, at: date))
    }

    /// Save in the sheet: trimmed and joined, the notes summary's own text stays the
    /// notes summary, and an empty field removes both.
    func testTheSheetsSaveStoresATypedSummaryOrTheNotesOneOrNone() {
        let notes = MeetingSummaries(notes: .init(text: "From the notes.", writtenAt: date))

        XCTAssertEqual(
            MeetingSummary.afterTyped(notes, field: "  My own\n\n  summary. \n", at: date),
            MeetingSummaries(notes: notes.notes, typed: .init(text: "My own summary.", writtenAt: date)),
        )
        XCTAssertEqual(MeetingSummary.afterTyped(notes, field: "From the notes.\n", at: date), notes)
        let typed = MeetingSummaries(notes: notes.notes, typed: .init(text: "Mine", writtenAt: date))
        XCTAssertEqual(MeetingSummary.afterTyped(typed, field: "From the notes.", at: date), notes)
        XCTAssertNil(MeetingSummary.afterTyped(typed, field: " \n ", at: date))
        XCTAssertEqual(typed.shown, "Mine")
        XCTAssertEqual(notes.shown, "From the notes.")
    }
}
