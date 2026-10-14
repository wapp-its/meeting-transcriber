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
- `app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator.swift:364-375` — environment builder pattern to mirror
- `app/MeetingTranscriber/Sources/PreviousExitNotice.swift` — pure notice-text type pattern
- `app/MeetingTranscriber/Sources/UpdateChecker.swift:1-106` — existing models and error type; do not change them

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
Added the pure core of the mt-update integration in two plain-Foundation files, `MtUpdateContract.swift` (source selection, the `--check --porcelain` parser, the child environment, the `MtUpdateInstalling` seam) and `UpdateInstallOutcome.swift` (pending-install record and store, live-exit outcome, launch-time evaluation, notice texts, install gate). Today's `mt-update --check` output (exit 0, German text in ANSI bold) parses as `.failed(.unsupported)`, so the app never reports it as up to date. Nothing here starts a process, and both variants compile it.

stage: impl-review - ran [2026-10-13T16:42:57Z..2026-10-13T16:50:16Z]

Tier: explicit implementer opus at xhigh (project routing block), spawned natively on this host (model: claude-opus-5-5)

Review: codex:gpt-5.6-sol:xhigh, three-draw fan-out (correctness, contracts, integration), all SHIP with no findings; receipt effort xhigh. Receipt /tmp/impl-review-receipt-cfaadf991a4c-gh-8-in-app-updates-through-mt-update.1.json (copy in .flow/tmp/gh-8-in-app-updates-through-mt-update.1-impl-review-receipt.json). The validator pass (FLOW_VALIDATE_REVIEW=1) was not dispatched because it runs only on NEEDS_WORK. The reviewer sandbox was workspace-write as instructed; git status after the round showed only flowctl's own bookkeeping.

Verification
- baseline: green (spec Quick command filter, 101 tests, rc 0; lint 0 violations), before any edit
- red first: the new tests failed to compile against the missing types before the implementation
- mutation check: six deliberate defects (summary cut at 79, MT_ kept, first key not winning, undecodable record kept, liveness before build identity, active jobs ignored by the gate) each turned a test red; sources restored afterwards
- `swift test --parallel --filter 'MtUpdateContractTests|UpdateInstallOutcomeTests'`: 16 tests, rc 0
- spec Quick command `--filter 'MtUpdate|UpdateInstall|UpdateChecker|AboutSettingsView|MenuBarView'`: 117 tests, rc 0
- `swift build --build-tests -Xswiftc -DAPPSTORE`: rc 0, no diagnostics from the new files
- `./scripts/lint.sh` with the cached pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1: 0 violations in 769 files
- not run: CI's `swiftlint analyze` (`unused_declaration`), see Choices 15

Error-case tests (R-IDs this task satisfies)
- R1 absent or unreadable mt-update means today's behaviour: `MtUpdateContractTests.testOnlyTheInstalledDevBuildWithMtUpdateUsesIt` ("no mt-update" row)
- R2 other exit code, signal, missing or contradicting status: `MtUpdateContractTests.testAnythingButAnAgreeingAnswerIsAFailedCheck`; wording `testFailedCheckMessagesNameTheCause`
- R3 today's `--check` output: `MtUpdateContractTests.testTodaysHumanCheckOutputIsUnsupported`
- R6 unknown exit status reported with its number: `UpdateInstallOutcomeTests.testALiveExitMapsToItsOutcome`, `testEveryOutcomeHasItsNotice`
- R7 mt-update gone without a new build: `UpdateInstallOutcomeTests.testTheSameBuildIsStillRunningOrDidNotFinish` (the start-time match itself is task 2's `isRunning`)

Choices (open in the spec and task, smallest default taken)
1. Failed-check wording beyond the pinned R3 sentence: `contradicting` reads "mt-update's answer was incomplete or did not match its exit status", `exitStatus` names the exit code or the signal number, `timedOut` says "did not answer within 5 minutes"; all three end with " Details: <checkLogPath>". Pinned verbatim in `testFailedCheckMessagesNameTheCause`.
2. `notStartable` (check message and install notice) puts the reason in parentheses and carries no log path, because mt-update never ran and its log holds nothing. The notice adds "The installed app is unchanged."
3. Every notice body is pinned verbatim in `testEveryOutcomeHasItsNotice`. "Update installed" reads "Now running the new build: <summary>."; the verbatim pins also prove that no text carries a date or time.
4. An empty `PATH` counts as absent and falls back to `/usr/bin:/bin:/usr/sbin:/sbin`, because an empty `PATH` entry means the working directory.
5. `GIT_TERMINAL_PROMPT=0` overrides a value already in the app's environment. The `MT_` prefix match is case-sensitive.
6. Bundle paths are compared through `URL(fileURLWithPath:).standardizedFileURL.path` (SwiftLint `legacy_objc_type` refuses the `NSString` form), and `~/.local/bin` is built with `URL.appending(path:)`, so a trailing slash on the home folder does not double.
7. The summary is read only with `status=update-available`. Whitespace left at the 80-character cut is kept as cut. A value keeps any later `=` signs.
8. `PendingUpdateInstallStore` stores JSON `Data`. A stored value of any other type also counts as undecodable and is removed. `save(_:)` keeps the task's non-throwing signature and drops a record that fails to encode, which only a non-finite `Date` can cause.
9. `PendingUpdateInstallStore(defaults:)` has no default argument, so no caller reaches `UserDefaults.standard` by accident.
10. "5 minutes" is a literal in the `timedOut` message; task 2 owns the limit value.
11. `MtUpdateContract.swift` carries `// swiftlint:disable:this file_name` with its reason, following `PermissionAccessRequest.swift`, because the task names that file and none of its types.
12. Test rows with more than four fields use nested tuples to satisfy `large_tuple`.
13. `UpdateInstallGate` takes the four inputs the task names; "a check is running" (R4) is left to task 3.
14. The round was finalized with `--merged-file` because the contracts draw printed no findings heading and `--merge-plan` refused it; all three draws were SHIP with zero findings.
15. `MtUpdateInstalling` and `MtUpdateSource.executablePathInHome` have no user until tasks 2 and 3 land, so CI's `swiftlint analyze` (`unused_declaration`) may report them on this commit alone. That check needs a clean xcodebuild and was not run here.

Follow-ups: none.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 4264ba3228c71e838a4d9681a0e346c808ffb411
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh-8-test-home swift test --parallel --filter 'MtUpdateContractTests|UpdateInstallOutcomeTests' (16 tests, rc 0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh-8-test-home swift test --parallel --filter 'MtUpdate|UpdateInstall|UpdateChecker|AboutSettingsView|MenuBarView' (117 tests, rc 0), cd app/MeetingTranscriber && swift build --build-tests -Xswiftc -DAPPSTORE (rc 0), PATH=$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH ./scripts/lint.sh (0 violations)
- PRs: