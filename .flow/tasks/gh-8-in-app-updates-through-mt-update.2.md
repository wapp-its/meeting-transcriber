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
- Start time and liveness: `sysctl` with `[CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]` and `kp_proc.p_starttime`, pattern `DualSourceRecorder.swift:187-194` (there for the own pid). `isRunning(_:)` is true only when the call succeeds, the returned size is non-zero (a missing pid returns success with size 0), and, when the record has a start time, it equals the live one to the microsecond.
- `currentBuild()`: `BuildIdentity(gitCommitHash: bundle.gitCommitHash, executableModified: <modification date of bundle.executableURL>)`; pattern for the date read: `AboutSettingsView.buildDate`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator+SessionPersistence.swift:85-147` — bounded child run writing to a file
- `app/MeetingTranscriber/Sources/ClaudeCLIProtocolGenerator.swift:46-80` — termination handler before `run()`
- `app/MeetingTranscriber/Sources/DualSourceRecorder.swift:180-194` — process start time via sysctl
- `app/MeetingTranscriber/Sources/PersistentDiagnosticLog.swift:52-61` — log directory

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/ClaudeCLIProtocolGeneratorSessionPersistenceTests.swift:55-85` — fake `#!/bin/sh` scripts in a temp folder
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
TBD

## Evidence
- Commits:
- Tests:
- PRs:
