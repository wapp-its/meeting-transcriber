import AppKit
@testable import MeetingTranscriber
import SnapshotTesting
import SwiftUI
import XCTest

/// The line under Template makes the start dialog and the Record Meeting
/// window taller, never wider: both keep their 440 pt width and grow by the
/// line's height, so a long title and pattern wrap instead of being clipped.
/// Checked on the views hosted in a real `NSWindow`, as
/// `SpeakerNamingRerunLayoutTests` does, since ViewInspector never lays out.
/// The snapshots at the end (dev-only) are the pixel record of the longest
/// line and of Settings with a missing template and an invalid pattern.
@MainActor
final class TemplateRulesLayoutTests: XCTestCase {
    private struct NoApps: RunningAppsProvider {
        func runningApps() -> [RunningApp] {
            [RunningApp(id: 100, name: "Zoom", bundleIdentifier: "us.zoom.xos", icon: nil)]
        }
    }

    /// A long pattern and a long title: the longest line a window shows.
    private static let longPattern = "daily|stand-?up|scrum|sync|weekly check-?in"
    private static let longTitle = "Weekly Check-in of the Regional Leadership Team and the Project Partners"

    private static let choices = ProtocolTemplateChoices(
        templates: [.builtIn, .file(name: "Daily")], defaultTemplate: .builtIn,
        rules: [ProtocolTemplateRule(pattern: longPattern, template: .file(name: "Daily"))],
    )

    private static let noRules = ProtocolTemplateChoices(templates: [.builtIn, .file(name: "Daily")], defaultTemplate: .builtIn)
    private static let use = ProtocolOptionsUse(destination: .remote(name: "Anthropic (Claude)"), recordOnly: false)

    private var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    override func invokeTest() {
        withSnapshotTesting(record: .missing) {
            super.invokeTest()
        }
    }

    /// Hosts `view` in a window at its fitting size, in the light appearance
    /// so a snapshot does not depend on the time of day.
    private func host(_ view: some View) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        return hosting
    }

    /// Lets SwiftUI apply the measured line height, then sizes the view to fit.
    private func settle(_ hosting: NSHostingView<AnyView>, until condition: () -> Bool = { true }) {
        pump(timeout: 2) { condition() }
        pump(timeout: 0.3) { false }
        hosting.setFrameSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
    }

    private func startDialog(choices: ProtocolTemplateChoices, draft: StartRecordingDraft) -> AppPickerView {
        AppPickerView(
            appsProvider: NoApps(), startWouldBeRefused: false, noMic: false,
            templateChoices: { choices }, optionsUse: { Self.use }, draft: draft,
            onStartRecording: { _, _ in }, onCancel: {},
        )
    }

    private func recordMeetingWindow(choices: ProtocolTemplateChoices, meetingTitle: String) -> ConsentOptionsView {
        ConsentOptionsView(
            question: ConsentQuestion(
                app: "Zoom", title: "Record Zoom meeting?",
                body: "A meeting is active in Zoom. Everyone must agree to being recorded.",
                meetingTitle: meetingTitle,
            ),
            templateChoices: { choices }, optionsUse: { Self.use },
            onRecord: { _, _ in true }, onClose: {},
        )
    }

    /// The opened start dialog, its app selected and the long title typed.
    private func hostStartDialog(choices: ProtocolTemplateChoices) -> (NSHostingView<AnyView>, StartRecordingDraft) {
        let draft = StartRecordingDraft()
        let hosting = host(startDialog(choices: choices, draft: draft))
        pump(timeout: 2) { draft.protocolOptions.line != nil || choices.rules.isEmpty }
        draft.source = .app(NoApps().runningApps()[0])
        draft.title = Self.longTitle
        settle(hosting)
        return (hosting, draft)
    }

    // MARK: - Width kept, height grown

    func testTheStartDialogGrowsByTheLineAndKeepsItsWidth() {
        let (plain, _) = hostStartDialog(choices: Self.noRules)
        let (withLine, draft) = hostStartDialog(choices: Self.choices)

        XCTAssertEqual(draft.protocolOptions.line, .rule(number: 1, pattern: Self.longPattern, title: Self.longTitle))
        XCTAssertEqual(plain.fittingSize, NSSize(width: 440, height: 620), "no rules: the dialog as before")
        XCTAssertEqual(withLine.fittingSize.width, 440)
        // The long line wraps to two caption lines, plus the form's spacing.
        XCTAssertGreaterThan(withLine.fittingSize.height, 620 + 2 * 12)
    }

    func testTheRecordMeetingWindowGrowsByTheLineAndKeepsItsWidth() {
        let plain = host(recordMeetingWindow(choices: Self.noRules, meetingTitle: Self.longTitle))
        settle(plain)
        let withLine = host(recordMeetingWindow(choices: Self.choices, meetingTitle: Self.longTitle))
        settle(withLine)

        XCTAssertEqual(plain.fittingSize.width, 440)
        XCTAssertEqual(withLine.fittingSize.width, 440)
        XCTAssertGreaterThan(withLine.fittingSize.height, plain.fittingSize.height + 2 * 12)
    }

    // MARK: - Snapshots (dev-only)

    func testSnapshotOfTheStartDialogWithTheLongestLine() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        let (hosting, _) = hostStartDialog(choices: Self.choices)

        assertSnapshot(of: hosting, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testSnapshotOfTheRecordMeetingWindowWithTheLongestLine() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        let hosting = host(recordMeetingWindow(choices: Self.choices, meetingTitle: Self.longTitle))
        settle(hosting)

        assertSnapshot(of: hosting, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    /// At the narrowest the Settings detail pane gets (760 pt window less the
    /// widest sidebar), with a rule whose template is gone, one whose field
    /// holds an invalid pattern, and a typed title.
    func testSnapshotOfSettingsWithAMissingTemplateAndAnInvalidPattern() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")
        let suite = "TemplateRulesLayoutTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)))
        settings.protocolTemplateRules = [
            ProtocolTemplateRule(pattern: Self.longPattern, template: .file(name: "Daily")),
            ProtocolTemplateRule(pattern: "retro", template: .file(name: "Retrospective")),
            ProtocolTemplateRule(pattern: "board", template: .builtIn),
        ]
        let store = try ProtocolTemplateStore(directory: makeTempDirectory(prefix: "template-rules-snapshot"))
        try "Daily".write(to: store.fileURL(named: "Daily"), atomically: true, encoding: .utf8)
        let templates = ProtocolTemplatesModel(store: store, settings: settings)
        templates.reload()
        let model = TemplateRulesModel(templates: templates, settings: settings)
        try model.setText("(board", of: XCTUnwrap(model.rows.last?.id))
        model.tryTitle = "Team Daily"

        let hosting = host(Form { TemplateRulesSettingsView(model: model) }.formStyle(.grouped).frame(width: 520))
        settle(hosting)

        assertSnapshot(of: hosting, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }
}
