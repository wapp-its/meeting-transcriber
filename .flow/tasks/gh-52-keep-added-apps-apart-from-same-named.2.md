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
Settings → General now lists an added app's "Never" entry as "<display name> (added app)" (its bundle ID when the app is not installed). Remove still deletes only that stored entry. The consent-visibility warning counts an added app out only when its own `custom:<bundleID>` key is denied. On the first `AppSettings` init, every added app whose display name or bundle ID was on the deny list gains its key. No entry is removed, and a defaults flag stops the step from ever running again.

stage: impl-review - ran [..2026-10-13T15:45Z] (model: gpt-5.6-sol xhigh; three-draw fan-out in the lane worktree: correctness SHIP, contracts SHIP, integration SHIP, no findings)
stage: plan-sync - skipped(config: planSync.enabled=false)

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

baseline: green (task verification filter, rc 0, 170 tests, pre-edit at 37d24869)

### Commits (base 37d24869)
- b4610d58 fix(app): count an added app out of the consent warning only by its key
- 0d4786a5 feat(app): show an added app's deny entry under its name
- 8aa7450c feat(app): carry name-based deny entries over to added-app keys once

### Acceptance → tests
- R4 Settings row. `ConsentDenyList.displayName(for:resolveAppName:)` turns a key into "<name> (added app)" and leaves every other entry unchanged. Tests are `ConsentDenyListTests.testAnAddedAppsKeyReadsAsItsNameMarkedAsAdded` (injected resolver gives "Zoom (added app)", and the production resolver falls back to the bundle ID) and `testABuiltInOrBrowserEntryReadsAsStored`. The view wiring is `GeneralSettingsConsentDenyListTests.testAnAddedAppsEntryIsListedByNameAndRemovedAlone`: with `["Zoom", "custom:com.example.not-installed"]` the section shows "Zoom" and "com.example.not-installed (added app)", and tapping `consentDeniedAppRemove(1)` leaves `["Zoom"]`. It was red on the old code ("Search did not find a match").
- Row identifiers stay index-based and carry no name or key. `ForEach` and `A11yID.consentDeniedAppRemove(index)` are unchanged, the new test locates the row by index, and `testRemoveIdentifiersCarryNoAppNames` passes unchanged.
- R5 migration. The pure carry-over is `ConsentDenyListTests.testMigrationAddsTheKeyOfEveryAddedAppItsEntriesNameAndRemovesNothing`, with six table rows: a name match, no match, a bundle-ID entry, two added apps named "Meet", a key already listed, and built-in and browser order kept. An extra assertion covers A3, where the same added Zoom is not installed, so its name cannot match. The init round trip is `ConsentDenyListMigrationTests` (2 tests). `["Finder", "Zoom"]` with `com.apple.finder` added loads and persists as `["Finder", "Zoom", "custom:com.apple.finder"]` and sets the flag. After the user sets `["Finder"]`, a second init keeps `["Finder"]`. A fresh suite yields `[]`, sets the flag and writes no list. Both tests were red on the old code. A mutation run with the flag guard removed made the runs-once assertion fail with `["Finder", "custom:com.apple.finder"]`, and the source was restored after.
- R6 readiness. `AppSettingsRecordWithoutAskingTests.testAnAddedAppCountsAsAskingUntilDenied` is the one changed existing test, a changed requirement that commit b4610d58 states. Denying the display name (here the bundle ID) leaves the app asking, and denying `custom:com.example.not-installed` counts it out. Both assertions were red on the old code.
- R8. No other existing test changed. All 170 baseline tests in the filter still pass.

### Gates
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh52-tick/lane2-home swift test --parallel --filter "ConsentDenyList|AppSettings|GeneralSettings|BrowserConsentReadiness|MicInputDetector|SettingsInteraction"` gave rc 0 with 176 tests (170 baseline + 6 new), log at /private/tmp/gh52-tick/lane2-t2-tests.log.
- `PATH="/private/tmp/gh52-tick/lint-bin:$PATH" ./scripts/lint.sh` with SwiftFormat 0.63.0 and SwiftLint 0.65.1 gave rc 0, 0/716 files to format and 0 violations in 716 files.
- `swift build -c release` gave rc 0, "Build complete!", and no warning or error lines.
- `swift build --build-tests` on the intermediate state of 0d4786a5 (display-name half only) gave rc 0.
- `flowctl gate classify --base 37d24869` reported FULL (Swift code), so the focused gates above apply. They ran on bytes identical to HEAD (checked with `cmp` after the commit split).
- Not run: `swiftlint analyze` (CI only). Every new declaration has a production caller. `displayName` is called from `GeneralSettingsView`, `migratingAddedAppNames` from the loader, and the loader from `AppSettings.init`. `AddedAppIdentity.bundleID(fromKey:)` now has its first production caller in `displayName`.
- Not run: the installed app. The branch is not pushed, and the conductor owns integration and `mt-update`. The ViewInspector test drives the real `GeneralSettingsView`, and the migration tests drive the real `AppSettings.init` over a throwaway defaults suite.

### Decisions
1. Rule 1 (spec A4, task step 1). The row text is "<name> (added app)", resolved through `MicInputDetector.appDisplayName(bundleID:)`. Switch point is `ConsentDenyList.displayName(for:resolveAppName:)`. Tests are `ConsentDenyListTests.testAnAddedAppsKeyReadsAsItsNameMarkedAsAdded` and `GeneralSettingsConsentDenyListTests.testAnAddedAppsEntryIsListedByNameAndRemovedAlone`.
2. Rule 1 (spec A2, A3, R5, task steps 1 to 3). The migration was built as specified. It is additive, appends keys after the existing entries, runs once behind `consentDeniedAppsAddedAppKeysMigrated`, sets the flag on a fresh install, and writes the list back only when it changed. No choice was left open.
3. Rule 6. `migratingAddedAppNames` matches only against the legacy entries it was given. It appends through `ConsentDenyList.denying`, which already makes the append idempotent.
4. Rule 6. The loader writes the list before the flag. A run stopped between the two writes then repeats an idempotent migration instead of skipping it.
5. Rule 6. The flag key is private to `AppSettings+ConsentDenyMigration.swift`. `ConsentDenyListMigrationTests` spells it as a literal, so a rename fails a test. A rename would re-run the migration on every existing install.
6. Rule 6. Following the test-mass rule, the pure migration cases are one table-driven test plus the A3 assertion. `displayName` gets two tests.
7. Rule 6. The Settings row test searches for texts inside `A11yID.consentDenyListSection`, because the General tab also has a "Zoom" watch toggle that an unscoped `find(text:)` would match.
8. Rule 6. The work is three atomic commits (readiness, Settings rows, migration). The intermediate commit was built with tests on its own.
9. Rule 1. Phase 1b is inert because `IMPLEMENTER: opus` is the in-host session model. `worker-bridge.md` was read after the implementation instead of before Phase 1.5, and that changed nothing.

### Open / follow-ups
- Accepted by the spec (A3). An added app that is not installed during the first launch of this build cannot be matched by name. It asks again once reinstalled, and its old name row stays removable.
- Accepted by the spec. Downgrading to an older build lists `custom:` entries raw, and the added app asks again.
- No overlap with task .3's files. Integration notes are in the run notes dir as `task2-integration.md`.
## Evidence
- Commits: b4610d587780dbc140642bade5ab1a0a06c6dd4f, 0d4786a58c3e26994af3e3d9a1000f70e4fd0cc9, 8aa7450c2fba86a63058af200c834a0386cec465, e6812ed538d13e923be5bfac0e9f6e84fe678eb4
- Tests: swift test --parallel --skip WatchLoopE2ETests --filter "ConsentDenyList|AppSettings|GeneralSettings|BrowserConsentReadiness|MicInputDetector|SettingsInteraction" (rc 0 on the integrated target; worker lane gates in the summary), PATH="/private/tmp/gh52-tick/lint-bin:$PATH" ./scripts/lint.sh (rc 0)
- PRs: