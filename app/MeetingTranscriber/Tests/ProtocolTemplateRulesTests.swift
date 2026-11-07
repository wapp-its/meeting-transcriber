@testable import MeetingTranscriber
import XCTest

/// Which template a meeting title gets from the rule list (`ProtocolTemplateRules`),
/// how a pattern is refused while it is typed, and how the list is stored.
/// Pure: no folder, no settings, no window.
final class ProtocolTemplateRulesTests: XCTestCase {
    private static let names = ["Board", "Daily", "Retro"]
    private let fallback = ProtocolTemplateID.file(name: "Retro")

    private func rule(_ pattern: String, _ template: String) -> ProtocolTemplateRule {
        ProtocolTemplateRule(pattern: pattern, template: .file(name: template))
    }

    private func resolve(
        _ title: String,
        _ rules: [ProtocolTemplateRule],
        names: [String] = names,
        ruleLimit: TimeInterval = ProtocolTemplateRules.ruleTimeLimit,
        titleLimit: TimeInterval = ProtocolTemplateRules.titleTimeLimit,
    ) -> ProtocolTemplateRules.Choice {
        ProtocolTemplateRules.resolve(
            title: title, rules: rules, templateNames: names, defaultTemplate: fallback,
            ruleTimeLimit: ruleLimit, titleTimeLimit: titleLimit,
        )
    }

    /// A pattern that backtracks without end on a long run of a's followed by
    /// something else, and a title that makes it do so.
    private let runaway = "(a+)+$"
    private let runawayTitle = String(repeating: "a", count: 40) + "!"

    // MARK: - Matching

    func testTheFirstMatchingRuleInListOrderWins() {
        let rules = [rule("stand-?up", "Daily"), rule("daily", "Board"), rule("team", "Retro")]

        let choice = resolve("Team Daily Stand-up", rules)

        XCTAssertEqual(choice.template, .file(name: "Daily"))
        XCTAssertEqual(choice.source, .rule(index: 0, pattern: "stand-?up"))
        XCTAssertEqual(choice.timedOutRules, [])
    }

    func testCaseIsIgnoredAndAMatchAnywhereInTheTitleCounts() {
        let choice = resolve("Team Daily Stand-up", [rule("daily", "Board")])

        XCTAssertEqual(choice.template, .file(name: "Board"))
        XCTAssertEqual(choice.source, .rule(index: 0, pattern: "daily"))
    }

    func testNoMatchGivesTheDefault() {
        let choice = resolve("Microsoft Teams Call", [rule("daily|stand-?up", "Daily")])

        XCTAssertEqual(choice, ProtocolTemplateRules.Choice(template: fallback, source: .defaultTemplate, timedOutRules: []))
    }

    func testAnEmptyTitleGetsTheDefault() {
        XCTAssertEqual(resolve("", [rule(".*", "Daily")]).source, .defaultTemplate)
    }

    func testNoRulesGiveTheDefault() {
        XCTAssertEqual(resolve("Team Daily", []).template, fallback)
    }

    func testARuleWhoseTemplateIsMissingIsSkipped() {
        let choice = resolve("Team Daily", [rule("daily", "Gone"), rule("team", "Board")])

        XCTAssertEqual(choice.template, .file(name: "Board"))
        XCTAssertEqual(choice.source, .rule(index: 1, pattern: "team"))
    }

    /// After a Finder rename that changed only the case, the rule names the
    /// file in the old spelling; it still counts, and the template comes back
    /// spelt as the folder lists it, so a picker keyed by the listing shows it.
    func testARuleTemplateIsMatchedWithoutRegardToCaseAndSpeltAsListed() {
        let choice = resolve("Team Daily", [rule("daily", "board")])

        XCTAssertEqual(choice.template, .file(name: "Board"))
    }

    func testTheBuiltInIsNeverMissing() {
        let choice = resolve("Team Daily", [ProtocolTemplateRule(pattern: "daily", template: .builtIn)], names: [])

        XCTAssertEqual(choice.template, .builtIn)
        XCTAssertEqual(choice.source, .rule(index: 0, pattern: "daily"))
    }

    /// Written by another build, or empty: never compiled, so skipped like a
    /// missing template. An empty pattern would otherwise match every title.
    func testAStoredPatternThatDoesNotCompileOrIsEmptyIsSkipped() {
        let choice = resolve("Team Daily", [rule("(daily", "Board"), rule("", "Board"), rule("team", "Daily")])

        XCTAssertEqual(choice.template, .file(name: "Daily"))
        XCTAssertEqual(choice.source, .rule(index: 2, pattern: "team"))
        XCTAssertEqual(choice.timedOutRules, [])
    }

    // MARK: - Time limits

    func testARunawayRuleStopsWithinItsLimitAndALaterRuleStillApplies() {
        let start = Date()

        let choice = resolve(runawayTitle, [rule(runaway, "Board"), rule("!", "Daily")])

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(choice.template, .file(name: "Daily"))
        XCTAssertEqual(choice.source, .rule(index: 1, pattern: "!"))
        XCTAssertEqual(choice.timedOutRules, [0])
        XCTAssertLessThan(elapsed, ProtocolTemplateRules.ruleTimeLimit + 0.1)
    }

    func testTwentyRunawayRulesReturnWithinTheTitleLimitReportEveryPositionAndGiveTheDefault() {
        let rules = Array(repeating: rule(runaway, "Board"), count: 20)
        let start = Date()

        let choice = resolve(runawayTitle, rules)

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(choice.template, fallback)
        XCTAssertEqual(choice.source, .defaultTemplate)
        XCTAssertEqual(choice.timedOutRules, Array(0 ..< 20))
        XCTAssertLessThan(elapsed, ProtocolTemplateRules.titleTimeLimit + 0.1)
    }

    /// The positions of stopped rules are reported also when a later rule wins.
    func testAStoppedRuleIsReportedWhenALaterRuleMatches() {
        let choice = resolve(runawayTitle, [rule(runaway, "Board"), rule("a", "Daily")], ruleLimit: 0.01, titleLimit: 0.05)

        XCTAssertEqual(choice.source, .rule(index: 1, pattern: "a"))
        XCTAssertEqual(choice.timedOutRules, [0])
    }

    func testAnOrdinaryCheckIsFarBelowTheLimits() {
        let rules = [rule("daily|stand-?up", "Daily"), rule("board", "Board")]
        let start = Date()

        for _ in 0 ..< 100 {
            _ = resolve("Microsoft Teams Call", rules)
        }

        XCTAssertLessThan(Date().timeIntervalSince(start) / 100, 0.005)
    }

    // MARK: - Refusing a pattern

    func testAValidPatternIsAccepted() {
        XCTAssertNil(ProtocolTemplateRulePattern.refusal(for: "daily|stand-?up"))
        XCTAssertNil(ProtocolTemplateRulePattern.refusal(for: " "))
    }

    func testAnEmptyPatternIsRefused() {
        XCTAssertEqual(ProtocolTemplateRulePattern.refusal(for: ""), .empty)
        XCTAssertEqual(
            ProtocolTemplateRulePattern.Refusal.empty.message,
            "Enter a pattern. The rule is saved once the pattern is valid.",
        )
    }

    /// The system's error names no reason, so the message names one only for
    /// an opener that is not closed.
    func testAnInvalidPatternIsRefusedWithAReasonOnlyForAnUnclosedOpener() {
        let cases: [(String, String)] = [
            ("(daily", "Not a valid pattern: a “(” is not closed. The rule is saved once the pattern is valid."),
            ("(a(b)", "Not a valid pattern: a “(” is not closed. The rule is saved once the pattern is valid."),
            ("[abc", "Not a valid pattern: a “[” is not closed. The rule is saved once the pattern is valid."),
            ("([abc", "Not a valid pattern: a “[” is not closed. The rule is saved once the pattern is valid."),
            ("*daily", "Not a valid pattern. The rule is saved once the pattern is valid."),
            ("daily)", "Not a valid pattern. The rule is saved once the pattern is valid."),
            ("a{2,1}", "Not a valid pattern. The rule is saved once the pattern is valid."),
            (#"\((daily"#, "Not a valid pattern: a “(” is not closed. The rule is saved once the pattern is valid."),
        ]
        for (pattern, message) in cases {
            XCTAssertEqual(ProtocolTemplateRulePattern.refusal(for: pattern)?.message, message, pattern)
        }
        XCTAssertNil(ProtocolTemplateRulePattern.refusal(for: #"\(daily"#), "an escaped ( is a literal")
    }

    // MARK: - Storage

    func testTheListSurvivesItsStoredFormAndKeepsAnUnknownTemplateName() {
        let rules = [
            rule("daily|stand-?up", "Daily"),
            ProtocolTemplateRule(pattern: "board", template: .builtIn),
            rule("retro", "A Template This Build Does Not Know"),
        ]

        let stored = ProtocolTemplateRule.storedList(rules)

        XCTAssertEqual(ProtocolTemplateRule.list(fromStored: stored), rules)
    }

    func testAMalformedStoredEntryIsDroppedAndTheOthersKept() {
        let stored: [Any] = [
            ["pattern": "daily", "template": "Daily"],
            ["pattern": 3, "template": "Board"],
            "not a rule",
            ["pattern": "retro"],
            ["pattern": "board", "template": ""],
        ]

        XCTAssertEqual(
            ProtocolTemplateRule.list(fromStored: stored),
            [rule("daily", "Daily"), ProtocolTemplateRule(pattern: "board", template: .builtIn)],
        )
        XCTAssertEqual(ProtocolTemplateRule.list(fromStored: []), [])
    }
}
