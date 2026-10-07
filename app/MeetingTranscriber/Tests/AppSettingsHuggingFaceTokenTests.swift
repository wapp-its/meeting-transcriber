import Foundation
@testable import MeetingTranscriber
import XCTest

/// A `HuggingFaceTokenStore` held in memory, with switches that make a save or a
/// delete fail the way a refusing Keychain would. Shared with
/// `TranscriptionSettingsHuggingFaceTokenTests`.
final class HuggingFaceTokenStoreFake {
    var token: String?
    var saveSucceeds = true
    var deleteSucceeds = true

    var store: HuggingFaceTokenStore {
        HuggingFaceTokenStore(
            read: { self.token },
            save: { value in
                guard self.saveSucceeds else { return false }
                self.token = value
                return true
            },
            delete: {
                guard self.deleteSucceeds else { return false }
                self.token = nil
                return true
            },
            exists: { self.token != nil },
        )
    }
}

/// The Hugging Face token on `AppSettings`: saved through an injected store, never
/// to `UserDefaults`. Its own file because `AppSettingsTests` sits at the 600-line
/// cap. Every case but the Keychain round trip uses `HuggingFaceTokenStoreFake`,
/// and that one uses an account of its own, so no test touches the token saved in
/// the app.
final class AppSettingsHuggingFaceTokenTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keychainAccount: String!
    private var fake: HuggingFaceTokenStoreFake!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsHuggingFaceTokenTests-\(getpid())-\(UUID().uuidString)"
        keychainAccount = "AppSettingsHuggingFaceTokenTests-huggingFaceToken-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
        fake = HuggingFaceTokenStoreFake()
        settings = AppSettings(defaults: defaults, huggingFaceTokenStore: fake.store)
    }

    override func tearDown() {
        settings = nil
        fake = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        KeychainHelper.delete(key: keychainAccount)
        keychainAccount = nil
        super.tearDown()
    }

    func testSaveStoresTheTrimmedDraftAndClearsTheField() {
        settings.huggingFaceTokenDraft = "  hf_abc\n"

        settings.saveHuggingFaceTokenDraft()

        XCTAssertEqual(fake.token, "hf_abc")
        XCTAssertEqual(settings.huggingFaceToken, "hf_abc")
        XCTAssertTrue(settings.huggingFaceTokenSaved)
        XCTAssertEqual(settings.huggingFaceTokenDraft, "")
        XCTAssertNil(settings.huggingFaceTokenProblem)
    }

    func testAWhitespaceOnlyDraftStoresNothing() {
        settings.huggingFaceTokenDraft = " \n\t "

        settings.saveHuggingFaceTokenDraft()

        XCTAssertNil(fake.token)
        XCTAssertEqual(settings.huggingFaceToken, "")
        XCTAssertFalse(settings.huggingFaceTokenSaved)
    }

    func testRemoveDeletesTheTokenAndClearsTheFlag() {
        fake.token = "hf_old"
        settings.refreshHuggingFaceTokenSaved()
        settings.huggingFaceTokenDraft = "hf_half_typed"

        settings.removeHuggingFaceToken()

        XCTAssertNil(fake.token)
        XCTAssertEqual(settings.huggingFaceToken, "")
        XCTAssertFalse(settings.huggingFaceTokenSaved)
        XCTAssertEqual(settings.huggingFaceTokenDraft, "")
        XCTAssertNil(settings.huggingFaceTokenProblem)
    }

    /// The flag starts false and follows the store only when asked, so building
    /// `AppSettings` never queries the Keychain.
    func testRefreshReflectsTheStore() {
        fake.token = "hf_old"
        XCTAssertFalse(settings.huggingFaceTokenSaved)

        settings.refreshHuggingFaceTokenSaved()
        XCTAssertTrue(settings.huggingFaceTokenSaved)

        fake.token = nil
        settings.refreshHuggingFaceTokenSaved()
        XCTAssertFalse(settings.huggingFaceTokenSaved)
    }

    /// A failed replacement keeps what was typed for a retry and still reports the
    /// older token as saved; the next successful save clears the problem.
    func testAFailedSaveKeepsTheDraftAndReportsTheOlderToken() {
        fake.token = "hf_old"
        fake.saveSucceeds = false
        settings.huggingFaceTokenDraft = "hf_new"

        settings.saveHuggingFaceTokenDraft()

        XCTAssertEqual(settings.huggingFaceTokenDraft, "hf_new")
        XCTAssertEqual(settings.huggingFaceTokenProblem, "The token could not be saved to the Keychain.")
        XCTAssertTrue(settings.huggingFaceTokenSaved)
        XCTAssertEqual(settings.huggingFaceToken, "hf_old")

        fake.saveSucceeds = true
        settings.saveHuggingFaceTokenDraft()

        XCTAssertEqual(settings.huggingFaceToken, "hf_new")
        XCTAssertNil(settings.huggingFaceTokenProblem)
    }

    func testAFailedRemoveSaysSo() {
        fake.token = "hf_old"
        fake.deleteSucceeds = false

        settings.removeHuggingFaceToken()

        XCTAssertEqual(settings.huggingFaceTokenProblem, "The token could not be removed from the Keychain.")
        XCTAssertTrue(settings.huggingFaceTokenSaved)
    }

    func testTheTokenNeverLandsInUserDefaults() {
        let token = "hf_sentinel_\(UUID().uuidString)"
        settings.huggingFaceTokenDraft = token

        settings.saveHuggingFaceTokenDraft()

        XCTAssertEqual(fake.token, token, "precondition: the token was saved")
        let leaked = defaults.dictionaryRepresentation().filter { String(describing: $0.value).contains(token) }
        XCTAssertTrue(leaked.isEmpty, "token found under \(leaked.keys.sorted())")
    }

    /// The production store, end to end through `AppSettings`, on an account of
    /// this test's own.
    func testKeychainStoreRoundTrip() {
        settings = AppSettings(defaults: defaults, huggingFaceTokenStore: .keychain(account: keychainAccount))
        settings.huggingFaceTokenDraft = "hf_round_trip"

        settings.saveHuggingFaceTokenDraft()

        XCTAssertNil(settings.huggingFaceTokenProblem, "KeychainHelper.save reported a failure")
        XCTAssertEqual(KeychainHelper.read(key: keychainAccount), "hf_round_trip")
        XCTAssertEqual(settings.huggingFaceToken, "hf_round_trip")
        XCTAssertTrue(settings.huggingFaceTokenSaved)

        settings.removeHuggingFaceToken()

        XCTAssertNil(settings.huggingFaceTokenProblem, "KeychainHelper.delete reported a failure")
        XCTAssertNil(KeychainHelper.read(key: keychainAccount))
        XCTAssertFalse(settings.huggingFaceTokenSaved)
        XCTAssertTrue(KeychainHelper.delete(key: keychainAccount), "deleting an absent item counts as success")
    }
}
