@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring tests for the permission buttons in Settings → Advanced.
/// `PermissionAccessRequestTests` owns the decision and the order of effects;
/// this only proves each row's button runs the injected request for its own
/// permission. No test runs the live requester: it would raise a TCC prompt
/// and open System Settings.
///
/// ViewInspector does not run `.onAppear`, so every row shows its initial
/// status: nothing granted, the microphone not asked yet.
@MainActor
final class AdvancedSettingsPermissionsTests: XCTestCase {
    private func makeView(
        requestAccess: @escaping @MainActor (PermissionKind) async -> Void,
    ) throws -> AdvancedSettingsView {
        let suiteName = "AdvancedSettingsPermissionsTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        return AdvancedSettingsView(settings: AppSettings(defaults: suite), requestAccess: requestAccess)
    }

    /// Taps the row's button and waits for the request, which runs in a `Task`:
    /// an assertion straight after `tap()` would pass or fail by timing.
    private func assertButtonRequestsItsOwnPermission(
        _ kind: PermissionKind,
        title: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async throws {
        let recorder = KindRecorder()
        let requested = expectation(description: "requestAccess ran")
        let view = try makeView { kind in
            recorder.kinds.append(kind)
            requested.fulfill()
        }

        let button = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.permissionRequestButton(kind))
            .button()
        XCTAssertEqual(try button.labelView().text().string(), title, file: file, line: line)
        try button.tap()
        await fulfillment(of: [requested], timeout: 5)

        XCTAssertEqual(recorder.kinds, [kind], "the button requested another permission", file: file, line: line)
    }

    func testScreenRecordingButtonRequestsScreenRecording() async throws {
        try await assertButtonRequestsItsOwnPermission(.screenRecording, title: "Request & Open System Settings")
    }

    func testMicrophoneButtonRequestsMicrophone() async throws {
        try await assertButtonRequestsItsOwnPermission(.microphone, title: "Request & Open System Settings")
    }

    func testAccessibilityButtonRequestsAccessibility() async throws {
        // The sandboxed build never asks for Accessibility, so its button only
        // opens the page; the injected request still receives the click.
        #if APPSTORE
            let title = "Open System Settings"
        #else
            let title = "Request & Open System Settings"
        #endif
        try await assertButtonRequestsItsOwnPermission(.accessibility, title: title)
    }

    func testRestartNoteShownWhileScreenRecordingIsNotGranted() throws {
        let view = try makeView { _ in XCTFail("nothing was tapped") }
        let note = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.screenRecordingRestartNote)
        XCTAssertEqual(
            try note.text().string(),
            "Screen Recording takes effect only after you quit and reopen Meeting Transcriber.",
        )
    }

    func testMicrophoneNotAskedYetReadsNotRequestedYet() throws {
        let view = try makeView { _ in XCTFail("nothing was tapped") }
        XCTAssertNoThrow(try view.inspect().find(text: "Not requested yet"))
    }
}

@MainActor
private final class KindRecorder {
    var kinds: [PermissionKind] = []
}
