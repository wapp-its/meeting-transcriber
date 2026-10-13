import Foundation

extension AppSettings {
    private static let consentDenyMigratedKey = "consentDeniedAppsAddedAppKeysMigrated"

    /// The stored deny list for `init`, after the one-time carry-over of
    /// name-based "Never" entries to the keys added apps are now filed under
    /// (`ConsentDenyList.migratingAddedAppNames`). Writes defaults itself,
    /// because an assignment in `init` does not run `didSet`.
    ///
    /// Once per defaults domain, never again. A name entry denied after this
    /// build is installed was answered for that name only: a new Never for the
    /// built-in Zoom must not be copied onto an added app called "Zoom". The
    /// flag is set on a fresh install too, so nothing is migrated later.
    ///
    /// An added app that is not installed when this runs has no display name
    /// to match, only its bundle ID. A legacy entry under its old name is then
    /// not carried over: once reinstalled, the app asks again (the safe
    /// direction), and the name entry stays listed and removable.
    static func loadConsentDeniedApps(from defaults: UserDefaults, addedBundleIDs: [String]) -> [String] {
        let stored = defaults.stringArray(forKey: "consentDeniedApps") ?? []
        guard !defaults.bool(forKey: consentDenyMigratedKey) else { return stored }
        let migrated = ConsentDenyList.migratingAddedAppNames(
            stored,
            addedBundleIDs: addedBundleIDs,
            displayName: MicInputDetector.appDisplayName(bundleID:),
        )
        if migrated != stored {
            defaults.set(migrated, forKey: "consentDeniedApps")
        }
        defaults.set(true, forKey: consentDenyMigratedKey)
        return migrated
    }
}
