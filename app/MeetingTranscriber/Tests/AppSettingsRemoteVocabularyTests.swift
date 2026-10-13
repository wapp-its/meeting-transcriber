import Foundation
@testable import MeetingTranscriber
import XCTest

/// The URL source's settings. Each test has its own defaults suite and its own
/// Keychain account, so a parallel run never shares state or touches the token
/// saved in the app.
final class AppSettingsRemoteVocabularyTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tokenAccount: String!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsRemoteVocabularyTests-\(getpid())-\(UUID().uuidString)"
        tokenAccount = "AppSettingsRemoteVocabularyTests-token-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() {
        KeychainHelper.delete(key: tokenAccount)
        tokenAccount = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSourceAndAddressPersistInTheInjectedDefaults() {
        let settings = makeSettings()
        XCTAssertEqual(settings.vocabularySource, .file, "Local file is the default, also for existing installations")
        XCTAssertEqual(settings.remoteVocabularyURL, "")

        settings.vocabularySource = .url
        settings.remoteVocabularyURL = "https://lists.example.org/team/vocabulary.txt"

        XCTAssertEqual(defaults.string(forKey: "vocabularySource"), "url")
        XCTAssertEqual(defaults.string(forKey: "remoteVocabularyURL"), "https://lists.example.org/team/vocabulary.txt")
        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.vocabularySource, .url)
        XCTAssertEqual(reloaded.remoteVocabularyURL, "https://lists.example.org/team/vocabulary.txt")
    }

    func testTokenLivesOnlyInTheKeychainAndEverySetBumpsTheRevision() {
        let settings = makeSettings()
        XCTAssertEqual(settings.remoteVocabularyToken, "")
        XCTAssertEqual(settings.remoteVocabularyTokenRevision, 0)

        settings.remoteVocabularyToken = "glpat-secret-token"

        XCTAssertEqual(KeychainHelper.read(key: tokenAccount), "glpat-secret-token")
        XCTAssertEqual(settings.remoteVocabularyToken, "glpat-secret-token")
        XCTAssertEqual(settings.remoteVocabularyTokenRevision, 1)
        let storedStrings = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        XCTAssertFalse(storedStrings.contains { $0.contains("glpat-secret-token") }, "The token never reaches UserDefaults")

        settings.remoteVocabularyToken = ""

        XCTAssertNil(KeychainHelper.read(key: tokenAccount), "Clearing the token deletes the Keychain item")
        XCTAssertEqual(settings.remoteVocabularyToken, "")
        XCTAssertEqual(settings.remoteVocabularyTokenRevision, 2)
    }

    private func makeSettings() -> AppSettings {
        AppSettings(
            defaults: defaults,
            remoteVocabularyTokenAccount: tokenAccount,
            remoteVocabularyCacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("AppSettingsRemoteVocabularyTests-never-created", isDirectory: true),
        )
    }
}
