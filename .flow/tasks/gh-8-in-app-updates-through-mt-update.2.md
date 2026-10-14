---
satisfies: [R1, R2, R3, R4]
---
# gh-8-in-app-updates-through-mt-update.2 mt-update process runner: bounded check, detached install, liveness

## Description
The process layer: `MtUpdateProvider`, the real `MtUpdateInstalling` (task 1's protocol). It runs the bounded porcelain check, launches the detached install with its output in a log file and its exit status delivered to a callback, tells whether a recorded install process still runs, reads the running build's identity, and detects mt-update mode at launch. This is the spec's early proof point: if mt-update cannot be run and launched this way, the background-launch approach (A4) is re-evaluated before tasks 3 and 4.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/MtUpdateProvider.swift`, `app/MeetingTranscriber/Tests/MtUpdateProviderTests.swift`
**Touches:** [app/MeetingTranscriber/Sources/MtUpdateProvider.swift, app/MeetingTranscriber/Tests/MtUpdateProviderTests.swift]

### Approach
- Both files are wrapped entirely in `#if !APPSTORE` (pattern: `ClaudeCLIProtocolGenerator.swift`, whole file guarded). Header comment states the file's purpose, as every source file does.
- `struct MtUpdateProvider: MtUpdateInstalling` with injected `executableURL`, `homeDirectory`, `logDirectory`, `baseEnvironment`, `checkTimeout: TimeInterval = 300`, `bundle: Bundle = .main`. `installLogPath` = `<logDirectory>/mt-update.log`, `checkLogPath` = `<logDirectory>/mt-update-check.log`. Production log directory: `PersistentDiagnosticLog.logDirectory` (`~/Library/Logs/MeetingTranscriber`; its cleanup leaves non-`diagnostics-*` files alone).
- `static func detect(fileManager: FileManager = .default, homeDirectory: URL = <real home>, runningBundlePath: String = Bundle.main.bundleURL.path) -> MtUpdateProvider?` → `MtUpdateSource.isActive(isAppStoreBuild: false, executableIsPresent: isExecutableFile(<home>/.local/bin/mt-update), runningBundlePath:)`; nil otherwise.
- `check()`: truncate/create the check log, `Process` with arguments `["--check", "--porcelain"]`, `environment = MtUpdateEnvironment.build(base:home:)`, `currentDirectoryURL = homeDirectory`, stdin `FileHandle.nullDevice`, stdout and stderr the same `FileHandle` on the check log. Run it bounded, in the shape of `runBounded` (termination handler installed before `run()`, a one-shot resume guard) but with group semantics, which is why it is not shared with the Claude CLI generator (do not refactor that one): at the limit send SIGTERM to the process group (`kill(-pid, SIGTERM)`; the child leads its own group), SIGKILL to the group one second later, then poll `kill(-pid, 0)` every 100 ms and return only once it fails with `ESRCH`, so no `git` mt-update started outlives the check (spec, Edge Cases). After exit read the log and return `MtUpdatePorcelain.parse(exit:output:)`; at the limit `.failed(.timedOut)`; when `run()` throws or the log cannot be opened, `.failed(.notStartable(<reason>))`.
- Exit mapping: `terminationReason == .uncaughtSignal` → `.signaled(terminationStatus)`, else `.exited(terminationStatus)`.
- `startInstall(onExit:)`: truncate/create the install log; `Process` with no arguments, same environment and working directory, stdin `FileHandle.nullDevice`, stdout and stderr the log `FileHandle` — never a `Pipe` (spec, Install); termination handler set before `run()` maps the status and calls `onExit`; after `run()` read the child's start time and return `MtUpdateLaunch(pid:processStart:)`. Throw when the log cannot be opened or `run()` fails.
- Start time and liveness: `sysctl` with `[CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]` and `kp_proc.p_starttime`, pattern `DualSourceRecorder.swift:209-218` (there for the own pid). `isRunning(_:)` is true only when the call succeeds, the returned size is non-zero (a missing pid returns success with size 0), and, when the record has a start time, it equals the live one to the microsecond.
- `currentBuild()`: `BuildIdentity(gitCommitHash: bundle.gitCommitHash, executableModified: <modification date of bundle.executableURL>)`; pattern for the date read: `AboutSettingsView.buildDate`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator+SessionPersistence.swift:110-148` — bounded child run writing to a file
- `app/MeetingTranscriber/Sources/CLIProcessRunner.swift:225-240` — termination handler before `run()` (the same construct; the shared CLI runner from gh-7 holds it now)
- `app/MeetingTranscriber/Sources/DualSourceRecorder.swift:205-220` — process start time via sysctl
- `app/MeetingTranscriber/Sources/PersistentDiagnosticLog.swift:52-63` — log directory

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/ClaudeCLIProtocolGeneratorSessionPersistenceTests.swift:58-82` — fake `#!/bin/sh` scripts in a temp folder
- `app/MeetingTranscriber/Sources/Bundle+AppVersion.swift` — `gitCommitHash`

### Key context
- The child must survive this app quitting: no pipe on any of its standard streams, and nothing in the app terminates it on quit. The parent may close its own copy of the log handle after `run()`; the child keeps its descriptor.
- `exec` (mt-update's self-update re-exec) keeps the process ID and start time, so the termination handler and the liveness check still apply.
- Measured on 2026-10-06 with a throwaway Swift script: a child started through Foundation's `Process` has `getpgid(child) == child`, `kill(-child, SIGKILL)` also ends a grandchild started with `&`, and `kill(-child, 0)` then fails with `ESRCH`. The install child is never signalled by the app.
- Tests write fake `mt-update` scripts into a fresh temp folder and inject every path (executable, home, log directory) and the base environment; they never touch the real `~/.local/bin`, `~/Library/Logs` or `UserDefaults.standard`. Cases: porcelain `update-available` + exit 10 → `.updateAvailable`; today's human `--check` lines + exit 0 → `.failed(.unsupported)`; a script that starts `sleep 30 &`, writes that grandchild's pid (`$!`) to a file and then sleeps 30 s itself, with an injected 1 s limit → `.failed(.timedOut)` within a few seconds, and when `check()` returns the grandchild is already gone (`kill(pid, 0)` fails with `ESRCH`), so a second `check()` started right after cannot overlap it; a missing executable → `.notStartable`; install script `exit 2` → `onExit(.exited(2))` (wait with an expectation); an install script that writes `env` and its stdin to files and echoes to stdout and stderr → PATH prefix, `GIT_TERMINAL_PROMPT=0`, no `MT_` key although the injected base had `MT_NO_LAUNCH=1`, empty stdin, both lines in the install log; liveness: a sleeping install script reads running, then not after it is killed, a launch with a shifted start time reads not running, an unused pid reads not running; `detect` true only with an executable at the home path and the `/Applications/MeetingTranscriber-Dev.app` bundle path.

### Verification
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh-8-test-home swift test --parallel --filter MtUpdateProviderTests > /private/tmp/gh-8-t2.log 2>&1` (read the log; never pipe a test run).
- `cd app/MeetingTranscriber && swift build --build-tests -Xswiftc -DAPPSTORE > /private/tmp/gh-8-t2-appstore.log 2>&1`.
- `./scripts/pre-push.sh` (release build: Swift 6 Sendable diagnostics around the termination handler surface only there).
- `./scripts/lint.sh` with the pinned tools from `scripts/tool-versions.sh`.
## Acceptance
- [ ] `MtUpdateProvider` (whole file `#if !APPSTORE`) conforms to `MtUpdateInstalling`; nothing in the App Store build references it.
- [ ] Fake-script tests pass for: available (exit 10), today's human output (unsupported), a missing executable (not startable), and a timed-out check whose script left a background grandchild: `check()` returns `.failed(.timedOut)` only after the whole process group, grandchild included, has ended.
- [ ] An install script exiting 2 reaches `onExit` as `.exited(2)`; the environment-dump script shows the `PATH` prefix, `GIT_TERMINAL_PROMPT=0` and no `MT_` key, an empty stdin, and its stdout and stderr in the injected install log; no `Pipe` is attached to the install child.
- [ ] `isRunning` is true for a live install child, false after it is killed, false for a shifted start time and for an unused pid.
- [ ] `detect` returns a provider only for an executable at `<home>/.local/bin/mt-update` and the `/Applications/MeetingTranscriber-Dev.app` bundle path.
- [ ] No test touches the real `~/.local/bin`, `~/Library/Logs` or `UserDefaults.standard`.
- [ ] `./scripts/pre-push.sh` and the App Store test build succeed; lint clean.
## Done summary
Added `MtUpdateProvider` (whole file `#if !APPSTORE`), the real `MtUpdateInstalling`. It runs `mt-update --check --porcelain` with output in `mt-update-check.log`. At the limit it signals the child's process group and returns only once that group is empty. It launches the install with output in `mt-update.log` (never a pipe), delivers the install's exit status to `onExit`, checks a recorded install's liveness by PID plus kernel start time, reads the running build's identity, and detects mt-update mode. The spec's early proof point holds for the process layer, so A4 stands. Whether a real mt-update can quit the app from the app's own child is still the owner's install check, as the spec says.

stage: impl-review - ran [2026-10-14T11:46Z..2026-10-14T11:53:12Z]

Tier: implementer - opus at xhigh (explicit invocation) (model: claude-opus-5-5)

Review: codex:gpt-6-astra:xhigh, three-lens fan-out (correctness, contracts, integration). All three returned SHIP with no findings; the receipt records effort xhigh. Receipt: /tmp/impl-review-receipt-cfaadf991a4c-gh-8-in-app-updates-through-mt-update.2.json. The reviewer sandbox was workspace-write. Afterwards `git status` showed only flowctl's review ledger in `.flow/specs/gh-8-in-app-updates-through-mt-update.json`, so nothing needed reverting. Inside their sandbox the reviewers could not finish the release build (nested sandbox, then `GenerateDSYMFile` refused). It ran green outside the sandbox (below).

Verification
- baseline: green before any edit. Spec Quick command: 117 tests, rc 0. Lint: 0 violations.
- measured with a throwaway probe outside the repository: across 90 runs (30 polling every 100 ms, 60 polling every 1 ms), the child led its own process group every time. When `kill(-pid, 0)` first failed with `ESRCH`, the background grandchild was already fully gone, not a zombie, in every run.
- mutation check: five deliberate defects each turned a test red: only the leader killed, no `O_TRUNC`, start time ignored, a `Pipe` on stdout, the size-0 check dropped. The no-truncation mutant survived at first, because both stale logs were shorter than the new output. The tests now pre-fill longer stale content and compare the check log exactly. The source was restored after each mutant.
- `swift test --parallel --filter MtUpdateProviderTests`: 9 tests, rc 0
- spec Quick command `--filter 'MtUpdate|UpdateInstall|UpdateChecker|AboutSettingsView|MenuBarView'`: 126 tests, exit 0, on the committed tree
- `swift build --build-tests -Xswiftc -DAPPSTORE`: rc 0. Only the two guarded files reference the provider.
- `./scripts/pre-push.sh`: rc 0, "OK — pre-push parity check passed" (release build, Homebrew variant)
- `./scripts/lint.sh` with the cached pinned tools: 0 files need formatting; 0 violations in 771 files
- not run: CI's `swiftlint analyze` (`unused_declaration`) needs a clean xcodebuild. `MtUpdateProvider.detect` and the provider type have no production caller until task 3, so that check may report them on this commit alone.

Error-case tests (R-IDs this task satisfies)
- R1, a path that cannot be read counts as absent: `testDetectNeedsAnExecutableMtUpdateAndTheInstalledBundle` (no file; a file that is not executable; the Homebrew release path; a development build path)
- R2, no answer within the limit: `testATimedOutCheckReturnsOnlyOnceItsProcessGroupHasEnded`. mt-update not startable: `testACheckOrInstallThatCannotStartIsNotStartable`. Exit codes and status disagreements are task 1's parser tests.
- R3, today's `--check` output: `testTodaysHumanCheckOutputIsUnsupported`
- R4, mt-update cannot be started: `testACheckOrInstallThatCannotStartIsNotStartable` covers a missing executable and a log that cannot be opened, for both check and install.

Choices
1. Rule 1 (AC "No test touches the real ~/Library/Logs"). `detect` takes a fourth parameter, `logDirectory: URL? = nil`. `PersistentDiagnosticLog.logDirectory` is read only when a provider is made, because reading it creates `~/Library/Logs/MeetingTranscriber`. The production call `detect()` is unchanged. Test: `testDetectNeedsAnExecutableMtUpdateAndTheInstalledBundle`.
2. Rule 6. The default home is `FileManager.default.homeDirectoryForCurrentUser`, as the conductor preferred.
3. Rule 6. For `Sendable`, the provider keeps the bundle's `gitCommitHash` and `executableURL` as values read at init, not the `Bundle` itself. `currentBuild()` reads the executable's modification date when it is called, following the task's Approach. Test: `testCurrentBuildIsTheBundlesCommitAndExecutableDate`. That test is not in the ACs, but without it nothing tests this method, and task 3's R5 and R7 depend on it.
4. Rule 6. The provider holds no state. The guard against a check and an install running together belongs to `UpdateChecker` (spec, Install gate; task 3).
5. Rule 6. Once a check runs out of time, the group gets SIGTERM and is polled every 100 ms from that moment. From 1 s on, every poll sends SIGKILL while the group still exists, instead of one SIGKILL at exactly 1 s. A group that SIGTERM ends returns at once, and a process forked between the two signals is also killed. The return condition is the task's: `kill(-pid, 0)` fails with `ESRCH`. A group member the app is not allowed to signal would hold the check open, which is the spec's "still running until every process in that group has ended". Test: `testATimedOutCheckReturnsOnlyOnceItsProcessGroupHasEnded`.
6. Rule 6. A one-shot lock decides between the exit and the deadline, so a check that exits at the very instant of its limit can read as timed out.
7. Rule 6. Logs are opened with `open(O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC)` with mode 0600, the repo's owner-only mode (`FileManager.ownerOnlyPermissions`). If the log folder is missing it is created first (`try?`), so any failure shows up as the open's own error. An open that fails throws `MtUpdateProvider.LogNotOpened`, whose text is "cannot open <path>: <strerror>". That text goes into `.notStartable(...)` for a check and is the error thrown by an install. Test: `testACheckOrInstallThatCannotStartIsNotStartable` (pinned verbatim, "Not a directory").
8. Rule 6. After the check exits, its log is read back by path and decoded as lossy UTF-8, so one invalid byte in mt-update's other lines cannot lose the answer. An unreadable log reads as empty. This needed a reasoned `swiftlint:disable:next optional_data_string_conversion`, the same as `CommandProtocolGenerator.lossyText`.
9. Rule 6. "Equal to the microsecond" is implemented as a difference under 0.5 µs between the two Dates, not by converting them to Int64, so a corrupt stored date can never trap. Tests: a start time 1 µs off reads not running, and a launch that went through JSON still reads running.
10. Rule 6. The exit mapping is an `MtUpdateExit.init(_ process: Process)` extension in the provider file: `.uncaughtSignal` maps to `.signaled`, anything else to `.exited`.
11. Rule 6. Liveness does not exclude zombie processes. The probe measurement above found no zombie window. Foundation reaps the install child, and launchd reaps orphans.
12. Rule 6. The environment-dump test also checks that the working directory is the home folder (physical paths compared inside the script) and that none of the child's streams is a pipe: stdin is a device, stdout and stderr are files.

Follow-ups: none. No feature-map route changed.

Commits: 22e105d6..a16a01d9 (one code commit, a16a01d9), plus the receipt commit that follows.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: a16a01d933e3432ef9d811332897699c2fbf621d
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh-8-test-home swift test --parallel --filter MtUpdateProviderTests (9 tests, rc 0), cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh-8-test-home swift test --parallel --filter 'MtUpdate|UpdateInstall|UpdateChecker|AboutSettingsView|MenuBarView' (126 tests, exit 0), cd app/MeetingTranscriber && swift build --build-tests -Xswiftc -DAPPSTORE (rc 0), ./scripts/pre-push.sh (rc 0, release build parity passed), PATH=$HOME/Library/Caches/MeetingTranscriber/lint-tools/bin:$PATH ./scripts/lint.sh (0 violations, 771 files)
- PRs: