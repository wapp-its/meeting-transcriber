---
satisfies: [R4, R5, R6, R8]
---
# gh-52-keep-added-apps-apart-from-same-named.2 Deny list: keyed rows in Settings, readiness warning and one-shot migration

## Description
Make the stored deny list work with the new keys on the settings side: show an added app's entry by name in Settings → General, count an added app as asking by its own key in the notification warning, and carry every existing name-based "Never" over once (spec §Architecture "Deny list", "One-shot migration", "Readiness warning"; R4 Settings part, R5, R6). Split from .1 because it owns the persisted list and its UI, disjoint from the detector files, and it only needs the key helper .1 adds.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/ConsentDenyList.swift`, `Sources/AppSettings.swift` (init only), `Sources/AppSettings+ConsentDenyMigration.swift` (new), `Sources/AppSettings+Computed.swift`, `Sources/Settings/GeneralSettingsView.swift`; tests listed below
**Touches:** [app/MeetingTranscriber/Sources/ConsentDenyList.swift, app/MeetingTranscriber/Sources/AppSettings.swift, app/MeetingTranscriber/Sources/AppSettings+ConsentDenyMigration.swift, app/MeetingTranscriber/Sources/AppSettings+Computed.swift, app/MeetingTranscriber/Sources/Settings/GeneralSettingsView.swift, app/MeetingTranscriber/Tests/ConsentDenyListTests.swift, app/MeetingTranscriber/Tests/ConsentDenyListMigrationTests.swift, app/MeetingTranscriber/Tests/AppSettingsRecordWithoutAskingTests.swift, app/MeetingTranscriber/Tests/GeneralSettingsConsentDenyListTests.swift]

### Approach
Tests first for the two pure functions and the migration (clear contracts), then implement.

1. `Sources/ConsentDenyList.swift:21-45`, two pure statics:
   - `displayName(for entry: String, resolveAppName: (String) -> String = MicInputDetector.appDisplayName(bundleID:)) -> String`: for an entry `AddedAppIdentity.bundleID(fromKey:)` recognises, `"<resolved name> (added app)"`; any other entry unchanged.
   - `migratingAddedAppNames(_ denied: [String], addedBundleIDs: [String], displayName: (String) -> String) -> [String]`: returns `denied` with every entry kept in order, plus `AddedAppIdentity.key(bundleID:)` appended for each added bundle ID whose `displayName(bundleID)` or bundle ID itself is in `denied`, unless that key is already present. Never removes anything (spec A2).
2. New `Sources/AppSettings+ConsentDenyMigration.swift`: a static loader (e.g. `loadConsentDeniedApps(from defaults: UserDefaults, addedBundleIDs: [String]) -> [String]`). When `defaults.bool(forKey: "consentDeniedAppsAddedAppKeysMigrated")` is true, return the stored list as is. Otherwise run `migratingAddedAppNames` with `MicInputDetector.appDisplayName(bundleID:)`, write the list back to `consentDeniedApps` only if it changed, set the flag to true (also on a fresh install with nothing to migrate) and return the list. Doc comment: why once (a later name entry, such as a new Never for the built-in Zoom, must never be copied onto an added "Zoom"), and the uninstalled-app limit (spec A3).
3. `Sources/AppSettings.swift:649, 659` (init): read the stored `watchCustomApps` into a local before assigning `consentDeniedApps`, then assign `consentDeniedApps` from the loader. Swift forbids reading `self.watchCustomApps` before every stored property is initialised, and an init assignment does not fire `didSet`, so the loader writes defaults itself. Follow the in-init migration at `:721-735`. Keep the init change to a few lines (the file is long and the init carries a lint exemption).
4. `Sources/AppSettings+Computed.swift:60-62`: the added-app branch of `anyWatchedAppAsksFirst` checks `consentDeniedApps.contains(AddedAppIdentity.key(bundleID:))` (no NSWorkspace lookup any more); update the doc comment at `:47-53`.
5. `Sources/Settings/GeneralSettingsView.swift:235-238`: the row shows `Text(ConsentDenyList.displayName(for: app))`. Keep `ForEach` keyed by the stored entry, keep the index-based `A11yID.consentDeniedAppRemove(index)` (an identifier must never carry an app name or key, `Tests/GeneralSettingsConsentDenyListTests.swift:60-71`), and keep Remove reverting the stored entry through `ConsentDenyListStore`.

### Tests
- `Tests/ConsentDenyListTests.swift`: `displayName` for a key with an injected resolver ("Zoom (added app)"), for a key whose resolver falls back to the bundle ID, and for a plain built-in or browser name (unchanged). `migratingAddedAppNames`: "Zoom" denied plus an added `com.example.zoom` named "Zoom" gives `["Zoom", "custom:com.example.zoom"]`; no match leaves the list unchanged; an entry equal to the bundle ID is carried over; two added apps named "Meet" both get keys; an existing key is not duplicated; built-in and browser entries keep their order; an added app whose resolver returns its bundle ID is not matched by an old display-name entry (A3).
- New `Tests/ConsentDenyListMigrationTests.swift` (`@MainActor`, a throwaway defaults suite per test as at `Tests/ConsentDenyListStoreTests.swift:11-20`): with `consentDeniedApps = ["Finder", "Zoom"]` and `watchCustomApps = ["com.apple.finder"]` written to the suite before `AppSettings(defaults:)`, the loaded list is `["Finder", "Zoom", "custom:com.apple.finder"]`, the suite holds the same and the flag; after the user then sets the list to `["Finder"]`, a second `AppSettings` over the same suite keeps `["Finder"]` (runs once); a fresh suite yields `[]` with the flag set. `MicInputDetector.appDisplayName(bundleID: "com.apple.finder") == "Finder"` is already relied on at `Tests/MicInputDetectorTests.swift:291-294`.
- Changed requirement (say so in the commit message): `Tests/AppSettingsRecordWithoutAskingTests.swift:62-72` denies `custom:com.example.not-installed` to count the added app out, and asserts that denying the display name (here the bundle ID) no longer does.
- `Tests/GeneralSettingsConsentDenyListTests.swift` (shape at `:11-26, :73-84`): with `["Zoom", "custom:com.example.not-installed"]` denied, the tab shows the texts "Zoom" and "com.example.not-installed (added app)", and tapping `A11yID.consentDeniedAppRemove(1)` leaves `["Zoom"]`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/ConsentDenyList.swift` — list, store protocol, persisting store
- `app/MeetingTranscriber/Sources/AppSettings.swift:162-201, 636-660, 719-745` — the two stored lists, their init loads, the existing in-init migration
- `app/MeetingTranscriber/Sources/AppSettings+Computed.swift:47-63` — `anyWatchedAppAsksFirst`
- `app/MeetingTranscriber/Sources/Settings/GeneralSettingsView.swift:219-249` — the deny-list rows

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/ConsentDenyListStoreTests.swift` — defaults-suite round-trip pattern
- `app/MeetingTranscriber/Tests/GeneralSettingsCustomAppsTests.swift:9-25` — ViewInspector `find(text:)` on Settings rows

### Key context
- Depends on .1 only for `AddedAppIdentity`. Every new deny entry for an added app comes from .1's consent gate, which stores the key.
- The flag lives in the same defaults domain as the list, so tests over a throwaway suite never touch the real one.
- Commit messages for the original's readers: no fork issue numbers or `gh-`/`fn-` ids; Conventional Commits; stage files explicitly.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/<your scratch>/home swift test --parallel --filter "ConsentDenyList|AppSettings|GeneralSettings|BrowserConsentReadiness|MicInputDetector|SettingsInteraction" > /private/tmp/<your scratch>/t2-tests.log 2>&1` and read the log.
- `./scripts/lint.sh` with the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 fetched per `scripts/tool-versions.sh` into a scratch dir (`PATH="<that dir>:$PATH"`); do not `brew install`.
- Run `swift build -c release` in `app/MeetingTranscriber` once (release mode catches Sendable diagnostics debug tolerates).

## Acceptance
- [ ] Settings → General lists an added app's deny entry as "<display name> (added app)" (bundle ID when not installed), other entries unchanged, and Remove deletes only that stored entry (R4).
- [ ] On the first `AppSettings` init the deny list keeps every entry and gains a `custom:<bundleID>` key for each added app whose display name or bundle ID was denied; the flag is set and a later init never migrates again (R5).
- [ ] `anyWatchedAppAsksFirst` counts an added app as asking unless its own key is denied; a denied same-named name does not count it out (R6).
- [ ] Row accessibility identifiers stay index-based and carry no app name or key.
- [ ] Only `testAnAddedAppCountsAsAskingUntilDenied` changed among existing tests, for the changed requirement as the commit message says; the verification filter passes (R8).
- [ ] `./scripts/lint.sh` passes with the pinned tools.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
