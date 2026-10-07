import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// The decision and the executor behind the Settings → Advanced → Permissions
/// buttons. Every effect is injected: no test here may raise a real TCC prompt
/// or open System Settings, so none builds `PermissionAccessRequester.live`.
@MainActor
final class PermissionAccessRequestTests: XCTestCase {
    // MARK: - Decision table

    private static let states: [PermissionAccessState] = [.granted, .notDetermined, .notGranted]

    /// The spec's table, one row per kind and `canRequestAccessibility` value,
    /// steps in `states` order. Screen Recording and Microphone carry both flag
    /// values to prove the flag only moves Accessibility.
    func testDecideFollowsTheDecisionTable() {
        let table: [(kind: PermissionKind, canRequestAccessibility: Bool, steps: [PermissionAccessStep])] = [
            (.screenRecording, true, [.openSettings, .requestThenOpenSettings, .requestThenOpenSettings]),
            (.screenRecording, false, [.openSettings, .requestThenOpenSettings, .requestThenOpenSettings]),
            (.microphone, true, [.openSettings, .requestThenOpenSettings, .openSettings]),
            (.microphone, false, [.openSettings, .requestThenOpenSettings, .openSettings]),
            (.accessibility, true, [.openSettings, .requestThenOpenSettings, .requestThenOpenSettings]),
            (.accessibility, false, [.openSettings, .openSettings, .openSettings]),
        ]
        XCTAssertEqual(Set(table.map(\.kind)), Set(PermissionKind.allCases))

        for row in table {
            for (state, expected) in zip(Self.states, row.steps) {
                XCTAssertEqual(
                    PermissionAccessStep.decide(
                        kind: row.kind,
                        state: state,
                        canRequestAccessibility: row.canRequestAccessibility,
                    ),
                    expected,
                    "\(row.kind) / \(state) / canRequestAccessibility \(row.canRequestAccessibility)",
                )
            }
        }
    }

    func testMicrophoneStatusMapsToAccessState() {
        XCTAssertEqual(PermissionAccessState(microphone: .authorized), .granted)
        XCTAssertEqual(PermissionAccessState(microphone: .notDetermined), .notDetermined)
        XCTAssertEqual(PermissionAccessState(microphone: .denied), .notGranted)
        XCTAssertEqual(PermissionAccessState(microphone: .restricted), .notGranted)
    }

    func testSettingsURLOpensEachPermissionsPrivacyPane() {
        let prefix = "x-apple.systempreferences:com.apple.preference.security?"
        XCTAssertEqual(PermissionKind.screenRecording.settingsURL.absoluteString, prefix + "Privacy_ScreenCapture")
        XCTAssertEqual(PermissionKind.microphone.settingsURL.absoluteString, prefix + "Privacy_Microphone")
        XCTAssertEqual(PermissionKind.accessibility.settingsURL.absoluteString, prefix + "Privacy_Accessibility")
    }

    func testButtonTitleSaysWhetherAClickAsks() {
        XCTAssertEqual(PermissionAccessStep.requestThenOpenSettings.buttonTitle, "Request & Open System Settings")
        XCTAssertEqual(PermissionAccessStep.openSettings.buttonTitle, "Open System Settings")
    }

    // MARK: - Executor

    /// The recorded request yields before it records, so a `run` that opened
    /// the page without awaiting the request would record the open first.
    func testRequestStepAwaitsTheRequestThenOpensThatPageOnce() async {
        let cases: [(kind: PermissionKind, state: PermissionAccessState)] = [
            (.screenRecording, .notGranted),
            (.microphone, .notDetermined),
            (.accessibility, .notGranted),
        ]
        for (kind, state) in cases {
            let recorder = EffectRecorder()
            await recorder.requester { _ in state }.run(kind)

            XCTAssertEqual(
                recorder.effects,
                ["request(\(kind))", "open(\(kind.settingsURL.absoluteString))"],
                "\(kind) / \(state)",
            )
        }
    }

    /// Granted is the "no extra dialog" case of the issue; a denied microphone
    /// and Accessibility in the App Store build cannot be asked either.
    func testOpenStepOpensThatPageOnceAndNeverRequests() async {
        let cases: [(kind: PermissionKind, state: PermissionAccessState, canRequestAccessibility: Bool)] = [
            (.screenRecording, .granted, true),
            (.microphone, .granted, true),
            (.accessibility, .granted, true),
            (.microphone, .notGranted, true),
            (.accessibility, .notGranted, false),
        ]
        for (kind, state, canRequestAccessibility) in cases {
            let recorder = EffectRecorder()
            let requester = recorder.requester(state: { _ in state }, canRequestAccessibility: canRequestAccessibility)
            await requester.run(kind)

            XCTAssertEqual(
                recorder.effects,
                ["open(\(kind.settingsURL.absoluteString))"],
                "\(kind) / \(state) / canRequestAccessibility \(canRequestAccessibility)",
            )
        }
    }

    /// The row's status can be stale: a grant made in System Settings while the
    /// Settings window stayed open must still get the page only.
    func testRunReadsTheStateWhenCalledNotWhenBuilt() async {
        let recorder = EffectRecorder()
        var microphoneState = PermissionAccessState.notDetermined
        let requester = recorder.requester { _ in microphoneState }
        microphoneState = .granted

        await requester.run(.microphone)

        XCTAssertEqual(recorder.effects, ["open(\(PermissionKind.microphone.settingsURL.absoluteString))"])
    }
}

/// Builds a requester whose effects land in `effects`, in the order they ran.
@MainActor
private final class EffectRecorder {
    private(set) var effects: [String] = []

    func requester(
        state: @escaping (PermissionKind) -> PermissionAccessState,
        canRequestAccessibility: Bool = true,
    ) -> PermissionAccessRequester {
        PermissionAccessRequester(
            currentState: state,
            request: { kind in
                await Task.yield()
                self.effects.append("request(\(kind))")
            },
            openURL: { self.effects.append("open(\($0.absoluteString))") },
            canRequestAccessibility: canRequestAccessibility,
        )
    }
}
