import Foundation

/// When the permission check runs, wired at launch. Its own file because
/// `AppState.swift` sits at the 600-line cap.
extension AppState {
    /// The launch check, and the system events that run it again besides an
    /// activation: a wake from sleep and a change of the default input device.
    /// A menu-bar app rarely comes to the front, so without these a false
    /// verdict could outlive the condition behind it by days.
    ///
    /// Called from the menu-bar `.task`, not from `init`, so constructing an
    /// `AppState` (as the tests do) installs no observer.
    func startPermissionChecks() async {
        permissions.recheckAfterWake()
        microphone.onDefaultInputChanged = { [weak self] in self?.permissions.recheck() }
        await permissions.check()
    }
}
