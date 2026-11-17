@testable import MeetingTranscriber
import XCTest

/// The name a current transcript or notes file takes when a re-run's new one takes
/// its place (`EarlierVersionName`).
final class EarlierVersionNameTests: XCTestCase {
    private let stamp = DateComponents(
        calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 13, hour: 9, minute: 15, second: 2,
    ).date ?? Date()
    private let transcript = "/out/protocols/20261113_0900_weekly-team-sync.txt"

    func testTheStampGoesBeforeTheExtensionInLocalTime() {
        XCTAssertEqual(
            EarlierVersionName.name(for: transcript, stamp: stamp, taken: []), "20261113_0900_weekly-team-sync.until-20261113_091502.txt",
        )
        XCTAssertEqual(
            EarlierVersionName.name(for: "/out/protocols/notes.md", stamp: stamp, taken: []), "notes.until-20261113_091502.md",
        )
    }

    func testATakenNameOrACaseVariantOfOneGetsTheNextNumber() {
        let first = "20261113_0900_weekly-team-sync.until-20261113_091502.txt"
        let second = "20261113_0900_weekly-team-sync.until-20261113_091502-2.txt"
        let rows: [(name: String, taken: [String], expected: String)] = [
            ("taken", [first], second),
            ("a case variant taken", [first.uppercased()], second),
            ("two taken", [first, second.uppercased()], "20261113_0900_weekly-team-sync.until-20261113_091502-3.txt"),
        ]
        for row in rows {
            let taken = Set(row.taken.map(MeetingReportFolder.folded))
            XCTAssertEqual(EarlierVersionName.name(for: transcript, stamp: stamp, taken: taken), row.expected, row.name)
        }
    }

    func testNoNameEndsInAParenthesisOrHoldsOneAfterASpace() {
        var taken = Set<String>()
        for _ in 1 ... 5 {
            let name = try? XCTUnwrap(EarlierVersionName.name(for: transcript, stamp: stamp, taken: taken))
            let stem = URL(filePath: name ?? ")").deletingPathExtension().lastPathComponent
            XCTAssertFalse(stem.hasSuffix(")"), stem)
            XCTAssertFalse(stem.contains(" ("), stem)
            XCTAssertNil(AdditionalReport.owner(ofStem: stem) { _ in true }, "read as a report: \(stem)")
            taken.insert(MeetingReportFolder.folded(name ?? ""))
        }
    }

    func testPastTheUpperBoundThereIsNoName() {
        var taken = Set<String>()
        for _ in 1 ... EarlierVersionName.maxAttempt {
            guard let name = EarlierVersionName.name(for: transcript, stamp: stamp, taken: taken) else {
                XCTFail("no name before the bound")
                return
            }
            taken.insert(MeetingReportFolder.folded(name))
        }

        XCTAssertNil(EarlierVersionName.name(for: transcript, stamp: stamp, taken: taken))
    }
}
