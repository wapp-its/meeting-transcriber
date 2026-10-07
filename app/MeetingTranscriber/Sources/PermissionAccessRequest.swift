// swiftlint:disable:this file_name
//
// The file holds the four types behind one permission request (kind, state,
// step, requester); none of them alone names it.

import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// The permissions Settings → Advanced → Permissions shows, one row each.
enum PermissionKind: String, CaseIterable {
    case screenRecording
    case microphone
    case accessibility

    /// The Privacy & Security page in System Settings that lists this
    /// permission.
    var settingsURL: URL {
        let pane = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        }
        // A constant scheme plus a fixed pane name always parses.
        // swiftlint:disable:next force_unwrapping
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// What macOS says about one permission, reduced to what the button needs.
///
/// Screen Recording and Accessibility only ever read `granted` or
/// `notGranted`: macOS has no public "not asked yet" state for them.
enum PermissionAccessState: Equatable {
    case granted
    case notDetermined
    case notGranted

    init(microphone status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        case .denied, .restricted: self = .notGranted
        @unknown default: self = .notGranted
        }
    }
}

/// What a click on a permission's button does.
enum PermissionAccessStep: Equatable {
    case openSettings
    case requestThenOpenSettings

    /// Ask only where asking can still list the app or grant in place:
    /// anything granted just opens the page, so no dialog appears. A denied
    /// or restricted microphone only opens the page, since macOS asks for the
    /// microphone only while it is not determined. Accessibility is asked only
    /// where the build may request it (`canRequestAccessibility`), which the
    /// sandboxed build may not.
    static func decide(
        kind: PermissionKind,
        state: PermissionAccessState,
        canRequestAccessibility: Bool,
    ) -> Self {
        if state == .granted { return .openSettings }
        switch kind {
        case .screenRecording:
            return .requestThenOpenSettings

        case .microphone:
            return state == .notDetermined ? .requestThenOpenSettings : .openSettings

        case .accessibility:
            return canRequestAccessibility ? .requestThenOpenSettings : .openSettings
        }
    }

    var buttonTitle: String {
        switch self {
        case .openSettings: "Open System Settings"
        case .requestThenOpenSettings: "Request & Open System Settings"
        }
    }
}

/// Runs one permission button: asks macOS where `PermissionAccessStep.decide`
/// says to, then opens the permission's System Settings page.
///
/// Every effect is injected so the order can be tested without a TCC prompt;
/// production uses `live`.
@MainActor
struct PermissionAccessRequester {
    let currentState: (PermissionKind) -> PermissionAccessState
    let request: (PermissionKind) async -> Void
    let openURL: (URL) -> Void
    let canRequestAccessibility: Bool

    /// Reads the state now rather than trusting the row's last refresh, so a
    /// permission granted in System Settings meanwhile only opens the page.
    /// Awaits the request before opening, so the app is already listed on the
    /// page that opens.
    func run(_ kind: PermissionKind) async {
        let step = PermissionAccessStep.decide(
            kind: kind,
            state: currentState(kind),
            canRequestAccessibility: canRequestAccessibility,
        )
        if step == .requestThenOpenSettings {
            await request(kind)
        }
        openURL(kind.settingsURL)
    }

    static var live: Self {
        #if APPSTORE
            let canRequestAccessibility = false
        #else
            let canRequestAccessibility = true
        #endif
        return Self(
            currentState: { kind in
                switch kind {
                case .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .notGranted
                case .microphone: PermissionAccessState(microphone: AVCaptureDevice.authorizationStatus(for: .audio))
                case .accessibility: AXIsProcessTrusted() ? .granted : .notGranted
                }
            },
            request: { kind in
                switch kind {
                case .screenRecording:
                    Permissions.requestScreenRecordingAccess()

                case .microphone:
                    _ = await Permissions.ensureMicrophoneAccess()

                case .accessibility:
                    #if !APPSTORE
                        Permissions.ensureAccessibilityAccess()
                    #endif
                }
            },
            openURL: { NSWorkspace.shared.open($0) },
            canRequestAccessibility: canRequestAccessibility,
        )
    }
}
