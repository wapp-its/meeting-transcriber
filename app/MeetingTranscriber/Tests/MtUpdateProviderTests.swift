#if !APPSTORE
    @testable import MeetingTranscriber
    import os
    import XCTest

    /// `MtUpdateProvider` against fake `mt-update` shell scripts. Every path
    /// (executable, home, logs) and the base environment are injected into a
    /// fresh temporary folder, so no test touches the real `~/.local/bin`,
    /// `~/Library/Logs` or `UserDefaults.standard`.
    final class MtUpdateProviderTests: XCTestCase {
        /// What `onExit` reported, and when.
        private final class ExitRecorder: Sendable {
            let reported: XCTestExpectation
            private let received = OSAllocatedUnfairLock<MtUpdateExit?>(initialState: nil)

            init(_ reported: XCTestExpectation) {
                self.reported = reported
            }

            var exit: MtUpdateExit? {
                received.withLock { $0 }
            }

            func record(_ exit: MtUpdateExit) {
                received.withLock { $0 = exit }
                reported.fulfill()
            }
        }

        /// The app's environment as the child would inherit it, with an `MT_`
        /// variable that must not reach mt-update.
        private let baseEnvironment = ["PATH": "/usr/bin:/bin", "MT_NO_LAUNCH": "1"]

        /// A fresh folder with `home/` and `logs/`, removed after the test.
        private func makeFolder() throws -> URL {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("MtUpdateProviderTests-\(UUID().uuidString)", isDirectory: true)
            for name in ["home", "logs"] {
                try FileManager.default.createDirectory(
                    at: folder.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true,
                )
            }
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            return folder
        }

        private func writeScript(_ text: String, to url: URL, permissions: Int = 0o755) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }

        /// A provider whose mt-update is `<folder>/mt-update`.
        private func makeProvider(
            in folder: URL,
            checkTimeout: TimeInterval = MtUpdateProvider.defaultCheckTimeout,
            logDirectory: URL? = nil,
        ) -> MtUpdateProvider {
            MtUpdateProvider(
                executableURL: folder.appendingPathComponent("mt-update"),
                homeDirectory: folder.appendingPathComponent("home", isDirectory: true),
                logDirectory: logDirectory ?? folder.appendingPathComponent("logs", isDirectory: true),
                baseEnvironment: baseEnvironment,
                checkTimeout: checkTimeout,
            )
        }

        // MARK: - Check

        /// The arguments reach mt-update, and the check log holds this check's
        /// stdout and stderr and nothing of an earlier, longer one.
        func testAnAgreeingPorcelainAnswerReadsAsAvailable() async throws {
            let folder = try makeFolder()
            try writeScript("""
            #!/bin/sh
            [ "$*" = "--check --porcelain" ] || exit 1
            echo "mt-update updated itself"
            echo "format=mt-update-porcelain/1"
            echo "status=update-available"
            echo "summary=upstream 1a2b3c4 · wapp/main 5d6e7f8" >&2
            exit 10
            """, to: folder.appendingPathComponent("mt-update"))
            let provider = makeProvider(in: folder)
            try String(repeating: "status=up-to-date from an earlier check\n", count: 10)
                .write(toFile: provider.checkLogPath, atomically: true, encoding: .utf8)

            let outcome = await provider.check()

            XCTAssertEqual(outcome, .updateAvailable(summary: "upstream 1a2b3c4 · wapp/main 5d6e7f8"))
            XCTAssertEqual(
                try String(contentsOfFile: provider.checkLogPath, encoding: .utf8),
                """
                mt-update updated itself
                format=mt-update-porcelain/1
                status=update-available
                summary=upstream 1a2b3c4 · wapp/main 5d6e7f8

                """,
            )
        }

        /// Today's `--check` prints human text and exits 0; that is never an
        /// answer.
        func testTodaysHumanCheckOutputIsUnsupported() async throws {
            let folder = try makeFolder()
            try writeScript("""
            #!/bin/sh
            echo "upstream/main: 1a2b3c4 (2 neue Commits)"
            echo "wapp/main: unverändert"
            exit 0
            """, to: folder.appendingPathComponent("mt-update"))

            let outcome = await makeProvider(in: folder).check()

            XCTAssertEqual(outcome, .failed(.unsupported))
        }

        /// A check stopped at its limit returns only once mt-update's whole
        /// process group has ended, the grandchild it left in the background
        /// included, so a second check started right after cannot meet it.
        func testATimedOutCheckReturnsOnlyOnceItsProcessGroupHasEnded() async throws {
            let folder = try makeFolder()
            let grandchildFile = folder.appendingPathComponent("grandchild.pid")
            try writeScript("""
            #!/bin/sh
            sleep 30 &
            echo $! > "\(grandchildFile.path)"
            sleep 30
            """, to: folder.appendingPathComponent("mt-update"))

            let start = ContinuousClock.now
            let outcome = await makeProvider(in: folder, checkTimeout: 1).check()
            let elapsed = start.duration(to: .now)

            let grandchild = try XCTUnwrap(pid_t(
                String(contentsOf: grandchildFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            ))
            let probe = kill(grandchild, 0)
            let probeError = errno
            if probe == 0 { kill(grandchild, SIGKILL) }
            XCTAssertEqual(outcome, .failed(.timedOut))
            XCTAssertLessThan(elapsed, .seconds(5))
            XCTAssertEqual(probe, -1, "the background grandchild outlived the check")
            XCTAssertEqual(probeError, ESRCH)
        }

        /// Neither a missing mt-update nor a log that cannot be opened starts
        /// anything: the check is not startable and the install throws.
        func testACheckOrInstallThatCannotStartIsNotStartable() async throws {
            let folder = try makeFolder()
            let missing = makeProvider(in: folder)
            let missingOutcome = await missing.check()
            guard case .failed(.notStartable) = missingOutcome else {
                XCTFail("a missing mt-update must be not startable, got \(missingOutcome)")
                return
            }
            XCTAssertThrowsError(try missing.startInstall { _ in XCTFail("nothing was started") })

            try writeScript("#!/bin/sh\nexit 0\n", to: folder.appendingPathComponent("mt-update"))
            let notAFolder = folder.appendingPathComponent("not-a-folder")
            try Data().write(to: notAFolder)
            let unopenableLog = makeProvider(in: folder, logDirectory: notAFolder)
            let outcome = await unopenableLog.check()
            XCTAssertEqual(outcome, .failed(.notStartable("cannot open \(unopenableLog.checkLogPath): Not a directory")))
            XCTAssertThrowsError(try unopenableLog.startInstall { _ in XCTFail("nothing was started") }) { error in
                XCTAssertEqual(error.localizedDescription, "cannot open \(unopenableLog.installLogPath): Not a directory")
            }
        }

        // MARK: - Install

        func testAnInstallExitReachesOnExit() throws {
            let folder = try makeFolder()
            try writeScript("#!/bin/sh\nexit 2\n", to: folder.appendingPathComponent("mt-update"))
            let recorder = ExitRecorder(expectation(description: "onExit"))

            _ = try makeProvider(in: folder).startInstall(onExit: recorder.record)

            wait(for: [recorder.reported], timeout: 10)
            XCTAssertEqual(recorder.exit, .exited(2))
        }

        /// What the install child gets: the built environment, the home folder
        /// as working directory, `/dev/null` as stdin, and the install log (a
        /// file, never a pipe) as stdout and stderr, emptied first.
        func testTheInstallChildGetsTheEnvironmentNullInputAndTheLogFile() throws {
            let folder = try makeFolder()
            let seen = folder.appendingPathComponent("seen", isDirectory: true)
            try FileManager.default.createDirectory(at: seen, withIntermediateDirectories: true)
            let provider = makeProvider(in: folder)
            let home = provider.homeDirectory
            try writeScript("""
            #!/bin/sh
            env > "\(seen.path)/env"
            cat > "\(seen.path)/stdin"
            if [ "$(pwd -P)" = "$(cd "\(home.path)" && pwd -P)" ]; then echo home; else pwd -P; fi > "\(seen.path)/cwd"
            for fd in 0 1 2; do
              if [ -p /dev/fd/$fd ]; then kind=pipe
              elif [ -f /dev/fd/$fd ]; then kind=file
              elif [ -c /dev/fd/$fd ]; then kind=device
              else kind=other; fi
              echo "$fd $kind" >> "\(seen.path)/streams"
            done
            echo "to stdout"
            echo "to stderr" >&2
            """, to: folder.appendingPathComponent("mt-update"))
            try String(repeating: "an earlier, longer install\n", count: 10)
                .write(toFile: provider.installLogPath, atomically: true, encoding: .utf8)
            let recorder = ExitRecorder(expectation(description: "onExit"))

            _ = try provider.startInstall(onExit: recorder.record)

            wait(for: [recorder.reported], timeout: 10)
            XCTAssertEqual(recorder.exit, .exited(0))
            func read(_ name: String) throws -> String {
                try String(contentsOf: seen.appendingPathComponent(name), encoding: .utf8)
            }
            let environment = try read("env").split(separator: "\n").map(String.init)
            XCTAssertTrue(
                environment.contains("PATH=\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"),
                "environment was: \(environment)",
            )
            XCTAssertTrue(environment.contains("GIT_TERMINAL_PROMPT=0"))
            XCTAssertFalse(environment.contains { $0.hasPrefix("MT_") }, "environment was: \(environment)")
            XCTAssertEqual(try read("stdin"), "")
            XCTAssertEqual(try read("cwd"), "home\n", "the working directory is not the home folder")
            XCTAssertEqual(try read("streams"), "0 device\n1 file\n2 file\n")
            XCTAssertEqual(try String(contentsOfFile: provider.installLogPath, encoding: .utf8), "to stdout\nto stderr\n")
        }

        // MARK: - Liveness

        /// Running means the recorded ID is alive and started at the recorded
        /// microsecond, also after the record went through storage. `exec`,
        /// as in mt-update's self-update, keeps both.
        func testIsRunningOnlyForTheLiveChildItRecorded() throws {
            let folder = try makeFolder()
            try writeScript("#!/bin/sh\nexec sleep 30\n", to: folder.appendingPathComponent("mt-update"))
            let provider = makeProvider(in: folder)
            let recorder = ExitRecorder(expectation(description: "onExit"))

            let launch = try provider.startInstall(onExit: recorder.record)
            let started = try XCTUnwrap(launch.processStart)
            let stored = try JSONDecoder().decode(MtUpdateLaunch.self, from: JSONEncoder().encode(launch))
            let shifted = MtUpdateLaunch(pid: launch.pid, processStart: started.addingTimeInterval(0.000_001))

            XCTAssertTrue(provider.isRunning(launch))
            XCTAssertTrue(provider.isRunning(stored), "a record read back from storage")
            XCTAssertFalse(provider.isRunning(shifted), "a start time one microsecond off")

            kill(launch.pid, SIGKILL)
            wait(for: [recorder.reported], timeout: 10)
            XCTAssertEqual(recorder.exit, .signaled(SIGKILL))
            XCTAssertFalse(provider.isRunning(launch), "after it was killed")

            let unused = try XCTUnwrap((pid_t(90000) ..< 99999).first { kill($0, 0) == -1 && errno == ESRCH })
            XCTAssertFalse(provider.isRunning(MtUpdateLaunch(pid: unused, processStart: nil)), "an unused pid")
        }

        // MARK: - Detection and build

        func testDetectNeedsAnExecutableMtUpdateAndTheInstalledBundle() throws {
            let folder = try makeFolder()
            let home = folder.appendingPathComponent("home", isDirectory: true)
            let logs = folder.appendingPathComponent("logs", isDirectory: true)
            let executable = home.appendingPathComponent(".local/bin/mt-update")
            let devApp = "/Applications/MeetingTranscriber-Dev.app"
            func detect(_ bundlePath: String) -> MtUpdateProvider? {
                MtUpdateProvider.detect(homeDirectory: home, runningBundlePath: bundlePath, logDirectory: logs)
            }

            XCTAssertNil(detect(devApp), "no mt-update")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeScript("#!/bin/sh\n", to: executable, permissions: 0o644)
            XCTAssertNil(detect(devApp), "an mt-update that is not executable")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            XCTAssertNil(detect("/Applications/MeetingTranscriber.app"), "the Homebrew release")
            XCTAssertNil(detect(folder.appendingPathComponent("MeetingTranscriber.app").path), "a development build")

            let provider = try XCTUnwrap(detect(devApp))
            XCTAssertEqual(provider.executableURL.path, executable.path)
            XCTAssertEqual(provider.homeDirectory, home)
            XCTAssertEqual(provider.logDirectory, logs)
        }

        func testCurrentBuildIsTheBundlesCommitAndExecutableDate() throws {
            let folder = try makeFolder()
            let app = folder.appendingPathComponent("Fake.app", isDirectory: true)
            let executable = app.appendingPathComponent("Contents/MacOS/Fake")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let info: [String: String] = [
                "CFBundleExecutable": "Fake",
                "CFBundleIdentifier": "test.mt-update-provider.\(UUID().uuidString)",
                "CFBundlePackageType": "APPL",
                "GitCommitHash": "1a2b3c4",
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            try writeScript("#!/bin/sh\n", to: executable)
            let built = Date(timeIntervalSince1970: 1_760_000_000)
            try FileManager.default.setAttributes([.modificationDate: built], ofItemAtPath: executable.path)
            let bundle = try XCTUnwrap(Bundle(url: app))

            let provider = MtUpdateProvider(
                executableURL: folder.appendingPathComponent("mt-update"),
                homeDirectory: folder.appendingPathComponent("home", isDirectory: true),
                logDirectory: folder.appendingPathComponent("logs", isDirectory: true),
                baseEnvironment: baseEnvironment,
                bundle: bundle,
            )

            XCTAssertEqual(provider.currentBuild(), BuildIdentity(gitCommitHash: "1a2b3c4", executableModified: built))
        }
    }
#endif
