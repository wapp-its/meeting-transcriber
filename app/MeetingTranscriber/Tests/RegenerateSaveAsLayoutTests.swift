import AppKit
@testable import MeetingTranscriber
import SnapshotTesting
import SwiftUI
import XCTest

/// The "Save as:" group makes the regenerate sheet taller, never wider: it keeps
/// its 440 pt width, so the longest small line wraps instead of being clipped.
/// Checked on the view hosted in a real `NSWindow`, since ViewInspector never lays
/// out. The snapshots (dev-only) are the pixel record of the sheet's three forms.
@MainActor
final class RegenerateSaveAsLayoutTests: XCTestCase {
    private static let basename = "20261013_0900_regional_leadership_weekly_check_in_ab12cd34"
    private static let choices = ProtocolTemplateChoices(
        templates: [.builtIn, .file(name: "Short"), .file(name: "Board summary for the partners")],
        defaultTemplate: .file(name: "Board summary for the partners"),
    )
    private static let use = ProtocolOptionsUse(destination: .remote(name: "Anthropic (Claude)"), recordOnly: false)
    private static let report = "\(basename) (Board summary for the partners).md"

    private var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    override func invokeTest() {
        withSnapshotTesting(record: .missing) {
            super.invokeTest()
        }
    }

    private static func target(hasProtocol: Bool = true, names: Set<String> = [], otherMeetings: Set<String> = []) -> ProtocolRegenerationTarget {
        ProtocolRegenerationTarget(
            folder: URL(fileURLWithPath: "/out/protocols"),
            basename: basename,
            title: "Regional leadership weekly check-in",
            meetingStartTime: Date(timeIntervalSince1970: 1_791_000_000),
            jobID: nil,
            files: ProtocolRegenerationFiles(
                transcriptFile: Data("[Anna] Hello".utf8), protocolFile: hasProtocol ? Data("# Old".utf8) : nil,
            ),
            reportFolder: MeetingReportFolder(
                basename: basename, names: names.union(["\(basename).txt", "\(basename).md"]), transcriptStems: otherMeetings,
            ),
        )
    }

    /// The sheet hosted in a window at its fitting size, in the light appearance so
    /// a snapshot does not depend on the time of day.
    private func host(_ target: ProtocolRegenerationTarget) -> NSHostingView<AnyView> {
        let draft = RegenerateProtocolDraft()
        let close: () -> Void = {}
        let sheet = RegenerateProtocolView(
            phase: .idle, templateChoices: { Self.choices }, optionsUse: { Self.use }, initialTarget: target,
            allowsChooseFile: true, chooseFile: { nil }, resolveFile: { _ in target }, draft: draft,
            onGenerate: { _, _, _ in }, onClose: close,
        )
        let hosting = NSHostingView(rootView: AnyView(sheet))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        pump(timeout: 0.5) { false }
        hosting.setFrameSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    func testTheSaveAsGroupKeepsTheSheetsWidthAndAddsHeight() {
        let without = host(Self.target(hasProtocol: false))
        let free = host(Self.target())
        let taken = host(Self.target(names: [Self.report]))

        XCTAssertEqual(without.fittingSize.width, 440)
        XCTAssertEqual(free.fittingSize.width, 440)
        XCTAssertEqual(taken.fittingSize.width, 440)
        XCTAssertGreaterThan(free.fittingSize.height, without.fittingSize.height + 3 * 12, "the group's label, two choices and their lines")
        XCTAssertGreaterThan(taken.fittingSize.height, free.fittingSize.height, "the orange line wraps to more lines")
    }

    // MARK: - Snapshots (dev-only)

    func testSnapshotOfTheSheetSavingAnAdditionalReport() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")

        assertSnapshot(of: host(Self.target(names: ["\(Self.basename) (Short).md"])), as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testSnapshotOfTheSheetReplacingTheTemplatesReport() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")

        assertSnapshot(of: host(Self.target(names: [Self.report])), as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testSnapshotOfTheSheetOfAMeetingWithoutNotes() throws {
        try XCTSkipIf(isCI, "Snapshot tests are machine-dependent")

        assertSnapshot(of: host(Self.target(hasProtocol: false)), as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }
}
