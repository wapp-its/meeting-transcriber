@testable import MeetingTranscriber
import XCTest

/// The real opener, without assuming which apps this Mac has: the app is one
/// made in a temp folder, and the Markdown lookups are only checked against
/// each other. Nothing here opens a file, reveals one or shows a panel.
@MainActor
final class TemplateOpenerTests: XCTestCase {
    func testAnAppIsKnownByItsBundleIdentifierAndItsName() throws {
        let app = try makeTempDirectory(prefix: "template-opener").appendingPathComponent("Notes Writer.app")
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "invalid.meetingtranscriber.notes-writer", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let editor = try XCTUnwrap(TemplateEditorApp(appAt: app))

        XCTAssertEqual(editor.bundleIdentifier, "invalid.meetingtranscriber.notes-writer")
        XCTAssertEqual(editor.name, "Notes Writer")
        XCTAssertEqual(editor.url, app)
    }

    /// An app is remembered by its bundle identifier, so one without it is none.
    func testAFolderWithoutABundleIdentifierIsNoApp() throws {
        let folder = try makeTempDirectory(prefix: "template-opener").appendingPathComponent("Plain.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertNil(TemplateEditorApp(appAt: folder))
    }

    func testAnUnknownBundleIdentifierResolvesToNone() {
        XCTAssertNil(TemplateOpener.live.installedApp("invalid.meetingtranscriber.no-such-app"))
    }

    /// No template file exists anywhere here: the lookups go by the Markdown
    /// content type, not by a file. Whatever this Mac has installed, a default
    /// app is one of the apps offered.
    func testTheDefaultMarkdownAppIsAmongTheOfferedOnes() {
        let offered = TemplateOpener.live.markdownApps()

        if let defaultApp = TemplateOpener.live.defaultMarkdownApp() {
            XCTAssertTrue(offered.contains { $0.bundleIdentifier == defaultApp.bundleIdentifier })
        }
    }
}
