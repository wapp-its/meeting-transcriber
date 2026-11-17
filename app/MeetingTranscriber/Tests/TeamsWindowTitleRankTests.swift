@testable import MeetingTranscriber
import XCTest

/// Which Teams window names a detected Teams meeting: window lists in, title
/// out, through the detector's own poll. Teams ends most window titles with
/// " | Microsoft Teams", so the suffix alone does not single out the meeting
/// window; the windows are ranked instead (meeting window, compact call
/// window, other Teams window, any other window), and within a rank the first
/// window in list order wins. Every name below is made up.
@MainActor
final class TeamsWindowTitleRankTests: XCTestCase {
    private static let meetingWindow = "Sprint Review | Contoso | user@contoso.com | Microsoft Teams"
    private static let compactWindow = "Meeting compact view | Meeting in General | Microsoft Teams"

    private func win(title: String?, owner: String = "Microsoft Teams", pid: Int32 = 1438) -> [String: Any] {
        var w: [String: Any] = ["kCGWindowOwnerName": owner, "kCGWindowOwnerPID": pid]
        if let title { w["kCGWindowName"] = title }
        return w
    }

    private func teamsMeeting(_ title: String) -> DetectedMeeting {
        DetectedMeeting(pattern: .teams, windowTitle: title, ownerName: "MSTeams", windowPID: 1438)
    }

    /// The title a Teams call detected with `titles` open, in that list order.
    private func teamsTitle(_ titles: [String]) -> String? {
        let detector = PowerAssertionDetector(confirmationCount: 1)
        detector.assertionProvider = {
            makeAssertionDict(pid: 1438, processName: "MSTeams", assertName: "Microsoft Teams Call in progress")
        }
        detector.windowListProvider = { titles.map { self.win(title: $0) } }
        return detector.checkOnce()?.windowTitle
    }

    // MARK: - One test per rank

    func testTheMeetingWindowOutranksEveryOtherWindowWhereverItIsInTheList() {
        XCTAssertEqual(
            teamsTitle(["Some Popup", "Jane Doe | Microsoft Teams", Self.compactWindow, Self.meetingWindow]),
            Self.meetingWindow,
        )
    }

    func testTheCompactCallWindowOutranksOtherTeamsWindowsAndAnyOtherWindow() {
        XCTAssertEqual(teamsTitle(["Some Popup", "Jane Doe | Microsoft Teams", Self.compactWindow]), Self.compactWindow)
    }

    func testAnotherTeamsWindowOutranksAnyOtherWindow() {
        XCTAssertEqual(teamsTitle(["Some Popup", "Jane Doe | Microsoft Teams"]), "Jane Doe | Microsoft Teams")
    }

    func testAnyOtherWindowStillNamesTheMeetingBeforeThePlaceholder() {
        XCTAssertEqual(teamsTitle(["Some Popup"]), "Some Popup")
    }

    // MARK: - Ties go to list order

    func testWithinARankTheFirstWindowInListOrderWins() {
        let rows: [(name: String, titles: [String], expected: String)] = [
            (
                "two meeting windows",
                ["Design Sync | Fabrikam | someone@example.org | Microsoft Teams", Self.meetingWindow],
                "Design Sync | Fabrikam | someone@example.org | Microsoft Teams",
            ),
            (
                "two compact call windows",
                ["Meeting compact view | Meeting in Design | Microsoft Teams", Self.compactWindow],
                "Meeting compact view | Meeting in Design | Microsoft Teams",
            ),
            ("two other Teams windows", ["A | Microsoft Teams", "B | Microsoft Teams"], "A | Microsoft Teams"),
            ("two other windows", ["Some Popup", "Another Popup"], "Some Popup"),
        ]
        for row in rows {
            XCTAssertEqual(teamsTitle(row.titles), row.expected, row.name)
        }
    }

    // MARK: - Windows that never count

    func testIdleTabsEmptyTitlesAndTheAppNameNeverCount() {
        let titles = [
            "Chat | Contoso | user@contoso.com | Microsoft Teams",
            "Calendar | Contoso | user@contoso.com | Microsoft Teams",
            "",
            "Microsoft Teams",
            "Jane Doe | Microsoft Teams",
        ]
        XCTAssertEqual(teamsTitle(titles), "Jane Doe | Microsoft Teams")
    }

    func testACompactCallWindowWithNothingAfterItsPrefixIsSkipped() {
        XCTAssertEqual(
            teamsTitle(["Meeting compact view | Microsoft Teams", "Meeting compact view", "Some Popup"]),
            "Some Popup",
        )
        XCTAssertEqual(teamsTitle(["Meeting compact view | Microsoft Teams"]), "Microsoft Teams Call", "alone: the placeholder")
    }

    func testNoUsableWindowGivesThePlaceholder() {
        XCTAssertEqual(teamsTitle([]), "Microsoft Teams Call")
        XCTAssertEqual(teamsTitle(["Calendar | Contoso | user@contoso.com | Microsoft Teams"]), "Microsoft Teams Call")
    }

    // MARK: - The three reported cases

    func testAMeetingWindowBehindAnotherTeamsWindowNamesTheMeeting() {
        XCTAssertEqual(teamsTitle(["Design Channel | Microsoft Teams", Self.meetingWindow]), Self.meetingWindow)
    }

    func testTheCompactCallWindowAloneNamesTheMeetingWithoutItsPrefix() {
        let title = teamsTitle([Self.compactWindow])
        XCTAssertEqual(title, Self.compactWindow)
        XCTAssertEqual(title.map { WatchLoop.cleanTitle(of: teamsMeeting($0)) }, "Meeting in General")
    }

    func testTheCompactCallWindowInFrontOfTheMeetingWindowLosesToIt() {
        XCTAssertEqual(teamsTitle([Self.compactWindow, Self.meetingWindow]), Self.meetingWindow)
    }

    // MARK: - The recording's title text

    func testTheTitleTextKeepsTheOrganisationAndAccountAndDropsTheCompactPrefix() {
        let rows: [(raw: String, expected: String)] = [
            (Self.meetingWindow, "Sprint Review | Contoso | user@contoso.com"),
            (Self.compactWindow, "Meeting in General"),
            ("Meeting compact view | Meeting in General", "Meeting in General"),
            ("Jane Doe | Microsoft Teams", "Jane Doe"),
        ]
        for row in rows {
            XCTAssertEqual(WatchLoop.cleanTitle(of: teamsMeeting(row.raw)), row.expected, row.raw)
        }
    }

    /// The compact prefix is Teams' own: another app's title keeps it.
    func testAnotherAppsTitleKeepsTheCompactPrefix() {
        let zoom = DetectedMeeting(pattern: .zoom, windowTitle: "Meeting compact view | Q4 planning - Zoom", ownerName: "zoom.us", windowPID: 2020)
        XCTAssertEqual(WatchLoop.cleanTitle(of: zoom), "Meeting compact view | Q4 planning")
    }

    // MARK: - Other apps keep today's pick

    /// Zoom keeps the first meeting-pattern title: ranked like Teams, the
    /// three-part title would win.
    func testZoomKeepsTodaysPick() {
        let detector = PowerAssertionDetector(confirmationCount: 1)
        detector.assertionProvider = {
            makeAssertionDict(pid: 2020, processName: "zoom.us", assertName: "Zoom Video Communication")
        }
        detector.windowListProvider = {
            [self.win(title: "A | B | C", owner: "zoom.us", pid: 2020), self.win(title: "Zoom Meeting", owner: "zoom.us", pid: 2020)]
        }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Zoom Meeting")
    }

    // MARK: - The read a running recording's refresh makes

    func testTheDetectorAnswersTheBestTeamsWindowForATeamsMeetingOnly() {
        let detector = PowerAssertionDetector(confirmationCount: 1)
        detector.windowListProvider = {
            [self.win(title: "Jane Doe | Microsoft Teams"), self.win(title: Self.meetingWindow), self.win(title: "Zoom Meeting", owner: "zoom.us", pid: 2020)]
        }
        let teams = DetectedMeeting(pattern: .teams, windowTitle: "Some Popup", ownerName: "MSTeams", windowPID: 1438)
        let zoom = DetectedMeeting(pattern: .zoom, windowTitle: "Zoom Meeting", ownerName: "zoom.us", windowPID: 2020)

        XCTAssertEqual(detector.rankedWindowTitle(for: teams), RankedWindowTitle(title: Self.meetingWindow, rank: .meetingWindow))
        XCTAssertNil(detector.rankedWindowTitle(for: zoom), "other apps keep their detection title")
        detector.windowListProvider = { [self.win(title: nil)] }
        XCTAssertNil(detector.rankedWindowTitle(for: teams), "no titles without the Screen Recording grant")
    }

    func testTheCompositeDetectorPassesTheAssertionChannelsAnswerOn() {
        let assertions = PowerAssertionDetector(confirmationCount: 1)
        assertions.windowListProvider = { [self.win(title: Self.compactWindow)] }
        let composite = CompositeMeetingDetector([ImmediatelyInactiveDetector(), assertions])
        let teams = DetectedMeeting(pattern: .teams, windowTitle: "Some Popup", ownerName: "MSTeams", windowPID: 1438)

        XCTAssertEqual(composite.rankedWindowTitle(for: teams), RankedWindowTitle(title: Self.compactWindow, rank: .compactCallWindow))
    }

    /// Each ask reads a fresh window list, so the composite asks the strategy
    /// that answers once: a second read could find the window gone.
    func testTheCompositeDetectorAsksTheAnsweringStrategyOnce() {
        let answer = RankedWindowTitle(title: Self.compactWindow, rank: .compactCallWindow)
        let once = AnsweringOnce(answer)
        let composite = CompositeMeetingDetector([ImmediatelyInactiveDetector(), once])

        XCTAssertEqual(composite.rankedWindowTitle(for: teamsMeeting("Some Popup")), answer)
        XCTAssertEqual(once.asks, 1)
    }
}

/// A strategy whose window closes right after its first answer.
private final class AnsweringOnce: MeetingDetecting {
    private let answer: RankedWindowTitle
    private(set) var asks = 0

    init(_ answer: RankedWindowTitle) {
        self.answer = answer
    }

    func checkOnce() -> DetectedMeeting? {
        nil
    }

    func isMeetingActive(_: DetectedMeeting) -> Bool {
        true
    }

    func reset(appName _: String?) {}

    func rankedWindowTitle(for _: DetectedMeeting) -> RankedWindowTitle? {
        asks += 1
        return asks == 1 ? answer : nil
    }
}
