---
satisfies: [R1, R2, R3, R5, R6, R7]
---
# gh-8-in-app-updates-through-mt-update.1 Pure mt-update contract, install bookkeeping and notices

## Description
The pure core everything else builds on: the mt-update contract (source selection, porcelain parser, child environment), the install bookkeeping types, the outcome decisions and the notification texts. No process is started here, so every type compiles in both build variants and is tested exhaustively without a subprocess. Split out first because R1-R3 and R5-R7 are decided entirely by these functions, and the contract table in the spec is easiest to pin as data.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/MtUpdateContract.swift`, `app/MeetingTranscriber/Sources/UpdateInstallOutcome.swift`, `app/MeetingTranscriber/Tests/MtUpdateContractTests.swift`, `app/MeetingTranscriber/Tests/UpdateInstallOutcomeTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/MtUpdateContract.swift, app/MeetingTranscriber/Sources/UpdateInstallOutcome.swift, app/MeetingTranscriber/Tests/MtUpdateContractTests.swift, app/MeetingTranscriber/Tests/UpdateInstallOutcomeTests.swift]

### Approach
Write the tests first from the spec's contract table and R-IDs, see them fail, then implement. Both source files are plain Foundation, no `#if APPSTORE` (the App Store build must compile them; nothing here starts a process).

`MtUpdateContract.swift`:
- `enum MtUpdateSource` with `static let executablePathInHome = ".local/bin/mt-update"`, `static let installedBundlePath = "/Applications/MeetingTranscriber-Dev.app"`, and `static func isActive(isAppStoreBuild: Bool, executableIsPresent: Bool, runningBundlePath: String) -> Bool` (compare standardized paths; a trailing slash must not matter).
- `enum MtUpdateExit: Equatable { case exited(Int32), signaled(Int32) }`.
- `enum MtUpdateCheckFailure: Equatable { case unsupported, contradicting, exitStatus(MtUpdateExit), timedOut, notStartable(String) }` with a user-facing `message(checkLogPath: String) -> String`. Wording to pin: `.unsupported` → "This mt-update cannot report updates to the app yet." (R3); the others start "Update check failed" and name the cause; `.contradicting`, `.exitStatus` and `.timedOut` end with " Details: <checkLogPath>"; `.timedOut` says it did not answer within 5 minutes.
- `enum MtUpdateCheckOutcome: Equatable { case upToDate, updateAvailable(summary: String), failed(MtUpdateCheckFailure) }`.
- `enum MtUpdatePorcelain` with `static func parse(exit: MtUpdateExit, output: String) -> MtUpdateCheckOutcome`, per the spec's contract table: split on newlines (tolerate `\r\n`); a line counts only as `key=value` with key `format`, `status` or `summary` (first occurrence wins; everything else ignored). Exit other than `.exited(0)`/`.exited(10)` → `.failed(.exitStatus(exit))`. Exit 0/10 without `format=mt-update-porcelain/1` (absent or another version) → `.unsupported`. Format present but status missing, unknown, or disagreeing with the exit code → `.contradicting`. Summary trimmed, empty → `new build`, longer than 80 characters → first 80 characters.
- `enum MtUpdateEnvironment` with `static func build(base: [String: String], home: String) -> [String: String]`: drop every key with prefix `MT_`; `PATH` = `<home>/.local/bin:/opt/homebrew/bin:/usr/local/bin:` + (base PATH or `/usr/bin:/bin:/usr/sbin:/sbin`); `GIT_TERMINAL_PROMPT=0`. Pattern: `ClaudeCLIProtocolGenerator.buildEnvironment`.
- `struct BuildIdentity: Codable, Equatable { gitCommitHash: String; executableModified: Date? }` and `struct MtUpdateLaunch: Codable, Equatable { pid: Int32; processStart: Date? }`.
- `protocol MtUpdateInstalling: Sendable` (the seam task 3 consumes and task 2 implements): `var installLogPath: String { get }`, `var checkLogPath: String { get }`, `func currentBuild() -> BuildIdentity`, `func check() async -> MtUpdateCheckOutcome`, `func startInstall(onExit: @escaping @Sendable (MtUpdateExit) -> Void) throws -> MtUpdateLaunch`, `func isRunning(_ launch: MtUpdateLaunch) -> Bool`.

`UpdateInstallOutcome.swift`:
- `struct PendingUpdateInstall: Codable, Equatable { startedAt: Date; launch: MtUpdateLaunch; previousBuild: BuildIdentity; summary: String; wasWatching: Bool }`.
- `struct PendingUpdateInstallStore` around an injected `UserDefaults`, key `mtUpdatePendingInstall`: `load() -> PendingUpdateInstall?` (undecodable data → nil and removed), `save(_:)`, `clear()`.
- `enum UpdateInstallOutcome: Equatable { case installed(summary: String), finishedWithoutRestart, mergeConflict, buildFailed, busyOrNotQuittable, failed(MtUpdateExit), notStartable(String), didNotFinish }` with `static func forLiveExit(_ exit: MtUpdateExit) -> Self` (0 → finishedWithoutRestart, 2 → mergeConflict, 3 → buildFailed, 4 → busyOrNotQuittable, other code or signal → failed).
- `enum UpdateLaunchEvaluation: Equatable { case nothingPending, stillRunning(PendingUpdateInstall), report(UpdateInstallOutcome, restoreWatching: Bool) }` with `static func evaluate(pending: PendingUpdateInstall?, currentBuild: BuildIdentity, isRunning: (MtUpdateLaunch) -> Bool) -> Self`: nil → nothingPending; build differs → `.report(.installed(summary:), restoreWatching: pending.wasWatching)` (checked before liveness, so a still-exiting mt-update never delays the success report); same build and running → stillRunning; else `.report(.didNotFinish, restoreWatching: false)`.
- `struct UpdateInstallNotice: Equatable { title; body }` with `init(outcome:logPath:)`, pattern `PreviousExitNotice`. Titles: installed and finishedWithoutRestart → "Update installed"; didNotFinish → "Update did not finish"; every failure → "Update not installed". Bodies: installed names the summary; finishedWithoutRestart says to quit and reopen to use the new build; mergeConflict / buildFailed / busyOrNotQuittable / failed name their cause (failed with its exit code or signal number), say the installed app is unchanged, and end with " Details: <logPath>"; didNotFinish says this is still the previous build and ends with the log path; notStartable names the reason. No date or time in any text (no locale dependence).
- `enum UpdateInstallGate` with `static func blockedReason(isRecording: Bool, manualRecordingStarting: Bool, waitingJobs: Int, activeJobs: Int) -> String?`: recording or starting → "Not available while recording."; any job → "Not available while meetings are being processed."; else nil. Speaker namings are deliberately not an input (A8).

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator.swift:427-450` — environment builder pattern to mirror
- `app/MeetingTranscriber/Sources/PreviousExitNotice.swift` — pure notice-text type pattern
- `app/MeetingTranscriber/Sources/UpdateChecker.swift:1-104` — existing models and error type; do not change them

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/DefaultsSuite.swift` — throwaway UserDefaults suites for the store tests
- `app/MeetingTranscriber/Tests/PreviousExitNoticeTests.swift` — how notice wording is pinned

### Key context
- Today's `mt-update --check` output, as a verbatim fixture for the R3 test (exit 0): three lines, each wrapped in the ANSI bold codes `\u{1B}[1m` … `\u{1B}[0m`: `Stand jetzt:        upstream 9b5f674 | wapp/main 65888b5`, `Letzter Build:      upstream 1111111 | wapp/main 2222222`, `Neuer Stand verfügbar → mt-update`. It must parse as `.failed(.unsupported)`, never as up to date.
- A self-update line (`mt-update wurde aktualisiert, starte neu …`) before the porcelain lines must not break parsing.
- File length cap is 600 lines (SwiftLint); keep each file well under it.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh-8-test-home swift test --parallel --filter 'MtUpdateContractTests|UpdateInstallOutcomeTests' > /private/tmp/gh-8-t1.log 2>&1` (never pipe a test run into tail/head/grep; read the log file).
- `cd app/MeetingTranscriber && swift build --build-tests -Xswiftc -DAPPSTORE > /private/tmp/gh-8-t1-appstore.log 2>&1` (both variants compile).
- `./scripts/lint.sh` with the pinned SwiftFormat/SwiftLint from `scripts/tool-versions.sh` (fetch them into a temp dir and put it first on `PATH` if they are not installed).

## Acceptance
- [ ] Tests written first: `MtUpdatePorcelain.parse` covers exit 10 + porcelain available, exit 0 + porcelain up to date, today's `--check` output verbatim (exit 0) as `.unsupported`, a foreign format version, a status that disagrees with the exit code in both directions, a missing status, any other exit code and a signal, a missing and an over-long summary, unknown keys and a leading self-update line.
- [ ] `MtUpdateSource.isActive` is true only for a non-App-Store build with the executable present and the bundle path `/Applications/MeetingTranscriber-Dev.app` (trailing slash tolerated).
- [ ] `MtUpdateEnvironment.build` drops every `MT_` key, prefixes `PATH` as specified (with and without a base `PATH`) and sets `GIT_TERMINAL_PROMPT=0`.
- [ ] `UpdateInstallOutcome.forLiveExit` maps 0, 2, 3, 4, another code and a signal as specified; `UpdateLaunchEvaluation.evaluate` returns installed (with `restoreWatching` from the record) for a changed build even while the process runs, still running, did not finish, and nothing pending.
- [ ] `PendingUpdateInstallStore` round-trips a record, clears it, and treats undecodable data as no record.
- [ ] `UpdateInstallNotice` titles and bodies match the wording in the task for every outcome; failure bodies name the cause and end with the log path; no text contains a date or time.
- [ ] `UpdateInstallGate.blockedReason` returns the recording reason, the processing reason, and nil when idle.
- [ ] Both source files compile in the App Store variant; lint clean.

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
