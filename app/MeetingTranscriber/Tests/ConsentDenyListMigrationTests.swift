@testable import MeetingTranscriber
import XCTest

/// The one-shot carry-over of name-based "Never" entries to the keys added
/// apps are now denied under, driven through `AppSettings(defaults:)` the way a
/// launch runs it. `ConsentDenyListTests` owns the matching rule; this proves
/// the init applies it, persists it and never applies it again.
@MainActor
final class ConsentDenyListMigrationTests: XCTestCase {
    /// The persisted flag's key, spelled out rather than read from the app: it
    /// is a stored format, and a renamed key would re-run the migration on every
    /// existing install.
    private let migratedFlag = "consentDeniedAppsAddedAppKeysMigrated"

    /// A defaults suite of its own per test, torn down at the end, so tests
    /// cannot see each other's writes and none of them touch the real domain.
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ConsentDenyListMigrationTests.\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    func testFirstLaunchAddsTheAddedAppsKeyAndNeverMigratesAgain() throws {
        let defaults = try makeDefaults()
        defaults.set(["Finder", "Zoom"], forKey: "consentDeniedApps")
        defaults.set(["com.apple.finder"], forKey: "watchCustomApps")

        let settings = AppSettings(defaults: defaults)
        let migrated = ["Finder", "Zoom", "custom:com.apple.finder"]
        XCTAssertEqual(settings.consentDeniedApps, migrated, "every entry kept, the added Finder's key appended")
        XCTAssertEqual(defaults.stringArray(forKey: "consentDeniedApps"), migrated, "the migrated list is persisted")
        XCTAssertTrue(defaults.bool(forKey: migratedFlag))

        // The user takes the added app's Never back, keeping the name entry. A
        // second migration pass would put the key straight back.
        settings.consentDeniedApps = ["Finder"]
        XCTAssertEqual(AppSettings(defaults: defaults).consentDeniedApps, ["Finder"])
    }

    func testFreshInstallOnlySetsTheFlag() throws {
        let defaults = try makeDefaults()
        XCTAssertEqual(AppSettings(defaults: defaults).consentDeniedApps, [])
        XCTAssertTrue(defaults.bool(forKey: migratedFlag), "nothing to migrate is still a completed migration")
        XCTAssertNil(defaults.object(forKey: "consentDeniedApps"), "an unchanged list is not written back")
    }
}
