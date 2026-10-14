import Foundation
@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The vocabulary-source controls in Settings → Transcription, rendered through
/// `TranscriptionSettingsView` so the controller's hand-over is part of what is
/// tested. Each test has its own defaults suite, Keychain account and cache
/// directory: rendering the URL source reads the token from the Keychain, and
/// the injected account keeps that read away from the token saved in the app.
@MainActor
final class VocabularySourceSettingsTests: XCTestCase {
    private static let address = "https://lists.example.org/team/vocabulary.txt"
    private static let checkDate = Date(timeIntervalSince1970: 1_791_288_120)

    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tokenAccount: String!
    private var cacheDirectory: URL!
    private var settings: AppSettings!
    private var fetcher: RemoteVocabularyFetcherFake!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "VocabularySourceSettingsTests-\(getpid())-\(UUID().uuidString)"
        tokenAccount = "VocabularySourceSettingsTests-token-\(getpid())-\(UUID().uuidString)"
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabularySourceSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = AppSettings(
            defaults: defaults,
            remoteVocabularyTokenAccount: tokenAccount,
            remoteVocabularyCacheDirectory: cacheDirectory,
        )
        fetcher = RemoteVocabularyFetcherFake()
    }

    override func tearDown() async throws {
        fetcher.releaseAll()
        fetcher = nil
        settings = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        cacheDirectory = nil
        KeychainHelper.delete(key: tokenAccount)
        tokenAccount = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testSourcePickerSelectionWritesTheSource() throws {
        XCTAssertEqual(settings.vocabularySource, .file, "precondition: Local file is the default")

        try makeView(nil).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.vocabularySourcePicker)
            .find(ViewType.Picker.self)
            .select(value: VocabularySource.url)

        XCTAssertEqual(settings.vocabularySource, .url)
    }

    func testEachSourceShowsOnlyItsOwnControls() throws {
        let fileOnly = [A11yID.customVocabularyFileRow, A11yID.customVocabularyPathField]
        let urlOnly = [
            A11yID.remoteVocabularyURLField, A11yID.remoteVocabularyTokenField,
            A11yID.remoteVocabularyUpdateButton, A11yID.remoteVocabularyStatus,
        ]
        let fileValidation = settings.customVocabularyValidation.message
        let controller = makeController()

        for source in VocabularySource.allCases {
            settings.vocabularySource = source
            let view = try makeView(controller).inspect()

            XCTAssertNoThrow(try view.find(viewWithAccessibilityIdentifier: A11yID.vocabularySourcePicker), "\(source)")
            for identifier in fileOnly {
                XCTAssertEqual(
                    (try? view.find(viewWithAccessibilityIdentifier: identifier)) != nil, source == .file,
                    "\(identifier) for \(source)",
                )
            }
            XCTAssertEqual((try? view.find(text: fileValidation)) != nil, source == .file, "validation line for \(source)")
            for identifier in urlOnly {
                XCTAssertEqual(
                    (try? view.find(viewWithAccessibilityIdentifier: identifier)) != nil, source == .url,
                    "\(identifier) for \(source)",
                )
            }
            XCTAssertEqual(
                (try? view.find(text: VocabularySourceSettingsView.addressFormsCaption)) != nil, source == .url,
                "address-forms caption for \(source)",
            )
        }
    }

    func testURLFieldWritesTheAddress() throws {
        settings.vocabularySource = .url

        try makeView(nil).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.remoteVocabularyURLField)
            .find(ViewType.TextField.self)
            .setInput(Self.address)

        XCTAssertEqual(settings.remoteVocabularyURL, Self.address)
    }

    func testTokenFieldWritesTheKeychainAndClearingItDeletesTheItem() throws {
        settings.vocabularySource = .url
        let field = try makeView(nil).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.remoteVocabularyTokenField)
            .find(ViewType.SecureField.self)

        try field.setInput("glpat-secret-token")
        XCTAssertEqual(KeychainHelper.read(key: tokenAccount), "glpat-secret-token")

        try field.setInput("")
        XCTAssertNil(KeychainHelper.read(key: tokenAccount), "clearing the field deletes the Keychain item")
    }

    func testUpdateNowAsksTheControllerForACheck() async throws {
        settings.vocabularySource = .url
        settings.remoteVocabularyURL = Self.address
        let controller = makeController()

        try makeView(controller).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.remoteVocabularyUpdateButton)
            .find(ViewType.Button.self)
            .tap()
        await waitFor(fetcher.requests.count == 1, timeout: .seconds(2))

        XCTAssertEqual(fetcher.requests.map(\.url.absoluteString), [Self.address])
    }

    func testStatusLineShowsTheControllersMessage() async throws {
        settings.vocabularySource = .url
        settings.remoteVocabularyURL = Self.address
        fetcher.answer = .modified(body: Data("Northstar\nAster\n".utf8), validators: nil)
        let controller = makeController()
        controller.refreshNow()
        await waitFor(fetcher.requests.count == 1 && !controller.isChecking, timeout: .seconds(2))
        XCTAssertEqual(
            controller.status, .current(termCount: 2, updatedAt: Self.checkDate, checkedAt: Self.checkDate),
            "precondition: a current copy, so the line carries dates",
        )

        let line = try makeView(controller).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.remoteVocabularyStatus)
            .find(ViewType.Text.self)
            .string()

        XCTAssertEqual(line, controller.status.message { $0.formatted(date: .abbreviated, time: .shortened) })
    }

    func testUpdateNowIsDisabledWithoutAControllerWhileCheckingAndForAnInvalidAddress() async throws {
        settings.vocabularySource = .url
        settings.remoteVocabularyURL = Self.address
        XCTAssertTrue(try updateButton(nil).isDisabled(), "no controller")
        XCTAssertThrowsError(
            try makeView(nil).inspect().find(viewWithAccessibilityIdentifier: A11yID.remoteVocabularyStatus),
            "no controller, no status line",
        )

        let controller = makeController()
        XCTAssertFalse(try updateButton(controller).isDisabled(), "idle, valid address")

        settings.remoteVocabularyURL = "http://lists.example.org/team/vocabulary.txt"
        XCTAssertTrue(try updateButton(controller).isDisabled(), "address without https")

        settings.remoteVocabularyURL = Self.address
        fetcher.holds = true
        controller.refreshNow()
        await waitFor(fetcher.heldCount == 1, timeout: .seconds(2))
        XCTAssertTrue(controller.isChecking, "precondition: a check is running")
        XCTAssertTrue(try updateButton(controller).isDisabled(), "while a check runs")
    }

    #if !APPSTORE
        /// A secure field must never be typable, and nothing here needs a live
        /// driver, so none of these may join the `/ui/type` or `/ui/press` lists.
        func testNoVocabularySourceIdentifierIsOnTheUIDriverAllowlists() {
            let identifiers = [
                A11yID.vocabularySourcePicker, A11yID.remoteVocabularyURLField, A11yID.remoteVocabularyTokenField,
                A11yID.remoteVocabularyUpdateButton, A11yID.remoteVocabularyStatus, A11yID.customVocabularyFileRow,
            ]
            for identifier in identifiers {
                XCTAssertFalse(DebugRPCServer.isIdentifierAllowedForUIType(identifier), identifier)
                XCTAssertFalse(DebugRPCServer.isIdentifierAllowedForUIPress(identifier), identifier)
            }
        }
    #endif

    // MARK: - Helpers

    private func makeView(_ controller: RemoteVocabularyController?) -> TranscriptionSettingsView {
        TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            remoteVocabulary: controller,
        )
    }

    private func makeController() -> RemoteVocabularyController {
        RemoteVocabularyController(settings: settings, fetcher: fetcher) { Self.checkDate }
    }

    private func updateButton(_ controller: RemoteVocabularyController?) throws -> InspectableView<ViewType.ClassifiedView> {
        try makeView(controller).inspect().find(viewWithAccessibilityIdentifier: A11yID.remoteVocabularyUpdateButton)
    }
}
