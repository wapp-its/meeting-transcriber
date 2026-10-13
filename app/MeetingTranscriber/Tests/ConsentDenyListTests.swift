@testable import MeetingTranscriber
import XCTest

/// The "never ask about this app again" list behind the consent prompt's third
/// action. It is the only durable answer a user can give: Ignore is per call,
/// Record starts one recording, Never is the one that has to survive.
final class ConsentDenyListTests: XCTestCase {
    func testEmptyListDeniesNothing() {
        // The control case: an untouched install must let every browser through
        // to the prompt, or the feature silently records nothing.
        let list = ConsentDenyList(denied: [])
        XCTAssertFalse(list.isDenied("Aside"))
        XCTAssertFalse(list.isDenied(""))
    }

    func testDenyingMarksExactlyThatApp() {
        let list = ConsentDenyList(denied: []).denying("Slack")
        XCTAssertTrue(list.isDenied("Slack"))
        XCTAssertFalse(list.isDenied("Brave Browser"))
    }

    func testDenyingIsIdempotent() {
        // Two Nevers for the same app can happen: the prompt is re-posted for
        // each detected call, and a second answer must not grow the list.
        let once = ConsentDenyList(denied: []).denying("Slack")
        let twice = once.denying("Slack")
        XCTAssertEqual(twice.denied, ["Slack"])
        XCTAssertEqual(once, twice)
    }

    func testDenyingIsExactAndCaseSensitive() {
        // The entries are process names as the assertion reports them, matched
        // the same way the detector matches them. A looser rule here would
        // silence an app the user never answered about.
        let list = ConsentDenyList(denied: []).denying("Brave Browser")
        XCTAssertFalse(list.isDenied("brave browser"))
        XCTAssertFalse(list.isDenied("Brave"))
    }

    func testRevertingRemovesOnlyThatApp() {
        let list = ConsentDenyList(denied: ["Slack", "Discord", "Aside"])
            .reverting("Discord")
        XCTAssertEqual(list.denied, ["Slack", "Aside"])
    }

    func testRevertingAnAbsentAppChangesNothing() {
        // Settings can only offer Remove for listed apps, but a stale view or a
        // concurrent edit must not corrupt the list.
        let list = ConsentDenyList(denied: ["Slack"])
        XCTAssertEqual(list.reverting("Discord"), list)
        XCTAssertEqual(ConsentDenyList(denied: []).reverting("Slack").denied, [])
    }

    func testOrderIsPreservedSoTheSettingsListDoesNotReshuffle() {
        // The list is shown to the user; an unstable order would make rows jump
        // between renders.
        var list = ConsentDenyList(denied: [])
        for app in ["Slack", "Discord", "Aside"] {
            list = list.denying(app)
        }
        XCTAssertEqual(list.denied, ["Slack", "Discord", "Aside"])
    }

    func testAnAddedAppsKeyReadsAsItsNameMarkedAsAdded() {
        let resolve = { (bundleID: String) in ["com.example.zoom": "Zoom"][bundleID] ?? "unresolved \(bundleID)" }
        XCTAssertEqual(
            ConsentDenyList.displayName(for: AddedAppIdentity.key(bundleID: "com.example.zoom"), resolveAppName: resolve),
            "Zoom (added app)",
        )
        // The production resolver falls back to the bundle ID for an app that
        // is not installed.
        XCTAssertEqual(
            ConsentDenyList.displayName(for: AddedAppIdentity.key(bundleID: "com.example.not-installed")),
            "com.example.not-installed (added app)",
        )
    }

    func testABuiltInOrBrowserEntryReadsAsStored() {
        for entry in ["Zoom", "Microsoft Teams", "Google Chrome"] {
            XCTAssertEqual(ConsentDenyList.displayName(for: entry) { _ in "resolved" }, entry)
        }
    }

    /// The carry-over to added-app keys. The resolver stands in for
    /// `MicInputDetector.appDisplayName(bundleID:)`, which answers the bundle
    /// ID for an app that is not installed.
    func testMigrationAddsTheKeyOfEveryAddedAppItsEntriesNameAndRemovesNothing() {
        let installed = ["com.example.zoom": "Zoom", "com.a.meet": "Meet", "com.b.meet": "Meet", "com.example.slack": "Slack"]
        let zoomKey = AddedAppIdentity.key(bundleID: "com.example.zoom")
        let cases: [(String, denied: [String], added: [String], expected: [String])] = [
            ("a name entry gains the same-named added app's key", ["Zoom"], ["com.example.zoom"], ["Zoom", zoomKey]),
            ("no added app named on the list", ["Zoom"], ["com.example.slack"], ["Zoom"]),
            ("an entry equal to the bundle ID", ["com.example.zoom"], ["com.example.zoom"], ["com.example.zoom", zoomKey]),
            (
                "two added apps with the same name",
                ["Meet"], ["com.a.meet", "com.b.meet"],
                ["Meet", AddedAppIdentity.key(bundleID: "com.a.meet"), AddedAppIdentity.key(bundleID: "com.b.meet")],
            ),
            ("a key already listed", ["Zoom", zoomKey], ["com.example.zoom"], ["Zoom", zoomKey]),
            (
                "built-in and browser entries keep their order",
                ["Google Chrome", "Zoom", "WeChat"], ["com.example.zoom"],
                ["Google Chrome", "Zoom", "WeChat", zoomKey],
            ),
        ]
        for (label, denied, added, expected) in cases {
            let migrated = ConsentDenyList.migratingAddedAppNames(denied, addedBundleIDs: added) { installed[$0] ?? $0 }
            XCTAssertEqual(migrated, expected, label)
        }

        // The first case's added Zoom, not installed while the migration runs:
        // its name resolves to the bundle ID, so the name entry cannot match.
        XCTAssertEqual(ConsentDenyList.migratingAddedAppNames(["Zoom"], addedBundleIDs: ["com.example.zoom"]) { $0 }, ["Zoom"])
    }
}
