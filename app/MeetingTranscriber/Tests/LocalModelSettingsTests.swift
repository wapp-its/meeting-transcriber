#if !APPSTORE

    @testable import MeetingTranscriber
    import SwiftUI
    import ViewInspector
    import XCTest

    /// Settings → Output for the local model: Check Model against fake helpers
    /// (`#!/bin/sh` scripts that print the `check` report of
    /// `tools/local-llm-helper/README.md`), the status line's wording, a
    /// superseded check, and one wiring test per control.
    @MainActor
    final class LocalModelSettingsTests: XCTestCase {
        private static let readyJSON =
            #"{"modelType":"qwen3_5","name":"Qwen3.8-27B-4bit","problems":[],"quantization":{"bits":4,"groupSize":64},"sizeBytes":16106127360,"usable":true}"#
        private static let readyReport = LocalModelCheckReport(
            usable: true, name: "Qwen3.8-27B-4bit", modelType: "qwen3_5", quantization: .init(bits: 4), sizeBytes: 16_106_127_360, problems: [],
        )

        private static func unusable(_ problems: [(file: String, problem: String)], modelType: String = "qwen3_5") -> LocalModelCheckReport {
            LocalModelCheckReport(
                usable: false, name: "model", modelType: modelType, quantization: nil, sizeBytes: nil,
                problems: problems.map { LocalModelCheckReport.Problem(file: $0.file, problem: $0.problem) },
            )
        }

        // MARK: - Check Model

        func testCheckRunsTheHelperOnTheFolderAndReadsItsVerdict() async throws {
            let folder = try makeTempDirectory(prefix: "Qwen 3.8 $HOME")
            let selection = LocalModelFolderSelection(path: folder.path, bookmark: nil)
            let cases: [(report: String, status: Int32, expected: LocalModelCheckResult)] = [
                (Self.readyJSON, 0, .ready(Self.readyReport)),
                (
                    #"{"modelType":"qwen3_5","name":"model","problems":[{"file":"tokenizer.json","problem":"missing"}],"usable":false}"#,
                    11, .unusable(Self.unusable([("tokenizer.json", "missing")])),
                ),
                (
                    #"{"modelType":"llama9","name":"model","problems":[{"file":"config.json","problem":"unsupported"}],"usable":false}"#,
                    11, .unusable(Self.unusable([("config.json", "unsupported")], modelType: "llama9")),
                ),
                (#"{"name":"model","problems":[{"file":".","problem":"missing"}],"usable":false}"#, 11, .folderNotFound),
                ("not a report", 0, .failed(.unreadableReport)),
                ("", 1, .failed(.exitStatus(1))),
            ]
            for (report, status, expected) in cases {
                let helper = try fakeHelper("cat <<'REPORT'\n\(report)\nREPORT\nexit \(status)")
                let result = await LocalModelCheck.run(selection, helper: helper)
                XCTAssertEqual(result, expected, "\(report) exit \(status)")
                let arguments = try String(contentsOf: helper.deletingLastPathComponent().appendingPathComponent("arguments"), encoding: .utf8)
                XCTAssertEqual(arguments, "check\n\(folder.path)\n", "check mode, the folder as one argument with its spaces and $ unexpanded")
            }
        }

        func testCheckThatCannotRunStartsNoHelper() async throws {
            let helper = try fakeHelper("exit 0")
            let spawned = helper.deletingLastPathComponent().appendingPathComponent("arguments")
            let folder = try makeTempDirectory(prefix: "model")

            let withoutHelper = await LocalModelCheck.run(LocalModelFolderSelection(path: folder.path, bookmark: nil), helper: nil)
            let gone = LocalModelFolderSelection(path: folder.appendingPathComponent("gone").path, bookmark: nil)
            let withoutFolder = await LocalModelCheck.run(gone, helper: helper)

            XCTAssertEqual(withoutHelper, .failed(.helperMissing))
            XCTAssertEqual(withoutFolder, .folderNotFound)
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawned.path), "no helper may start for a folder that is not there")
        }

        func testCheckThatDoesNotAnswerInTimeIsStopped() async throws {
            let helper = try fakeHelper("exec sleep 30")
            let folder = try makeTempDirectory(prefix: "model")
            let started = ContinuousClock.now

            let result = await LocalModelCheck.run(LocalModelFolderSelection(path: folder.path, bookmark: nil), helper: helper, timeout: 0.3)

            XCTAssertEqual(result, .failed(.timedOut))
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        }

        // MARK: - Status line

        func testStatusLineNamesWhatTheCheckFound() {
            let tiny = LocalModelCheckReport(usable: true, name: "tiny-model", modelType: "qwen3", quantization: nil, sizeBytes: 500_000_000, problems: [])
            let cases: [(status: LocalModelStatus, text: String)] = [
                (.noFolder, "No model chosen. Protocols are not written until one is set."),
                (.checked(.ready(Self.readyReport)), "Qwen3.8-27B \u{00B7} 4-bit \u{00B7} 16.1 GB \u{00B7} ready"),
                (.checked(.ready(tiny)), "tiny-model \u{00B7} 0.5 GB \u{00B7} ready"),
                (.checked(.unusable(Self.unusable([("config.json", "missing")]))), "Not a usable model. Missing: config.json."),
                (.checked(.unusable(Self.unusable([("tokenizer.json", "missing")]))), "Not a usable model. Missing: tokenizer.json."),
                (.checked(.unusable(Self.unusable([("tokenizer_config.json", "missing")]))), "Not a usable model. Missing: tokenizer_config.json."),
                (.checked(.unusable(Self.unusable([("chat_template.jinja", "missing")]))), "Not a usable model. Missing: chat_template.jinja."),
                (.checked(.unusable(Self.unusable([("model.safetensors", "missing")]))), "Not a usable model. Missing: model.safetensors."),
                (
                    .checked(.unusable(Self.unusable([
                        ("model-00002-of-00004.safetensors", "missing"), ("tokenizer.json", "missing"), ("tokenizer_config.json", "invalid"),
                    ]))),
                    "Not a usable model. Missing: model-00002-of-00004.safetensors, tokenizer.json. Invalid: tokenizer_config.json.",
                ),
                (
                    .checked(.unusable(Self.unusable([("config.json", "unsupported")], modelType: "llama9"))),
                    "Not a usable model. Model type llama9 is not supported.",
                ),
                (.checked(.unusable(Self.unusable([(".", "unreadable")]))), "Not a usable model. The folder cannot be read."),
                (.checked(.folderNotFound), "Model folder not found. Choose it again."),
                (.checked(.failed(.helperMissing)), "Cannot check: the local model helper is not in this app."),
                (.checked(.failed(.timedOut)), "Cannot check: no answer from the local model helper within 30 seconds."),
            ]
            for (status, text) in cases {
                XCTAssertEqual(status.text, text)
            }
        }

        func testACheckThatEndsAfterAnotherFolderWasChosenNeverShowsItsResult() async throws {
            let settings = try makeSettings()
            let folderA = try makeTempDirectory(prefix: "model-a")
            let folderB = try makeTempDirectory(prefix: "model-b")
            let checks = ScriptedChecks()
            let model = LocalModelSettingsModel(settings: settings, pickFolder: { folderB }, runCheck: { await checks.run($0) })
            settings.setLocalModelFolder(folderA)

            let checkA = try XCTUnwrap(model.startCheck())
            let checkB = try XCTUnwrap(model.chooseFolder())
            checks.finish(folderA.path, with: .ready(Self.readyReport))
            await checkA.value

            XCTAssertEqual(model.status, .checking, "folder A's verdict must never show while folder B is chosen")

            checks.finish(folderB.path, with: .folderNotFound)
            await checkB.value

            XCTAssertEqual(model.status, .checked(.folderNotFound))
        }

        // MARK: - Wiring

        func testPickingTheProviderShowsTheLocalModelRows() throws {
            let settings = try makeSettings()
            settings.protocolProvider = .openAICompatible
            XCTAssertThrowsError(try OutputSettingsView(settings: settings).inspect().find(viewWithAccessibilityIdentifier: A11yID.localModelStatus))

            try OutputSettingsView(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.protocolProviderPicker)
                .find(ViewType.Picker.self)
                .select(value: ProtocolProvider.localModel)

            let view = try OutputSettingsView(settings: settings).inspect()
            for identifier in [A11yID.localModelChooseFolderButton, A11yID.localModelStatus, A11yID.localModelCheckButton] {
                XCTAssertNoThrow(try view.find(viewWithAccessibilityIdentifier: identifier), identifier)
            }
            XCTAssertNoThrow(try view.find(text: "Model folder"))
        }

        func testChooseStoresThePickedFolderAndChecksIt() throws {
            let settings = try makeSettings()
            let picked = try makeTempDirectory(prefix: "picked-model")
            let model = LocalModelSettingsModel(settings: settings, pickFolder: { picked }, runCheck: { _ in .folderNotFound })

            try button(A11yID.localModelChooseFolderButton, model).tap()

            XCTAssertEqual(settings.localModelFolder.path, picked.path)
            XCTAssertEqual(model.status, .checking)
        }

        func testCheckModelChecksTheChosenFolderOneCheckAtATime() throws {
            let settings = try makeSettings()
            try settings.setLocalModelFolder(makeTempDirectory(prefix: "model"))
            let model = LocalModelSettingsModel(settings: settings, pickFolder: { nil }, runCheck: { _ in .folderNotFound })

            try button(A11yID.localModelCheckButton, model).tap()

            XCTAssertEqual(model.status, .checking)
            XCTAssertTrue(try button(A11yID.localModelCheckButton, model).isDisabled(), "a check in flight disables Check Model")
        }

        func testCheckModelIsDisabledAndTheWarningShownWithNoFolder() throws {
            let model = try LocalModelSettingsModel(settings: makeSettings(), pickFolder: { nil }, runCheck: { _ in .folderNotFound })
            let view = try LocalModelSettingsView(model: model).inspect()

            XCTAssertTrue(try view.find(viewWithAccessibilityIdentifier: A11yID.localModelCheckButton).button().isDisabled())
            XCTAssertNoThrow(
                try view.find(viewWithAccessibilityIdentifier: A11yID.localModelStatus)
                    .find(text: "No model chosen. Protocols are not written until one is set."),
            )
        }

        /// Screen 2 without a folder, screen 1 with one.
        func testNotesFollowWhetherAFolderIsChosen() throws {
            let settings = try makeSettings()
            let model = LocalModelSettingsModel(settings: settings, pickFolder: { nil }, runCheck: { _ in .folderNotFound })
            let noFolderCaption = "Transcripts are still saved. Download the model folder, then choose it here."
            let recordingNote = "Waits while a recording runs. Stops if the Mac runs low on memory. The transcript is always kept."

            let withoutFolder = try LocalModelSettingsView(model: model).inspect()
            XCTAssertNoThrow(try withoutFolder.find(text: noFolderCaption))
            XCTAssertThrowsError(try withoutFolder.find(text: recordingNote))

            try settings.setLocalModelFolder(makeTempDirectory(prefix: "model"))
            let withFolder = try LocalModelSettingsView(model: model).inspect()
            XCTAssertNoThrow(try withFolder.find(text: recordingNote))
            XCTAssertThrowsError(try withFolder.find(text: noFolderCaption))
        }

        func testStatusLineChecksAnUncheckedFolderWhenItAppears() throws {
            let settings = try makeSettings()
            try settings.setLocalModelFolder(makeTempDirectory(prefix: "model"))
            let model = LocalModelSettingsModel(settings: settings, pickFolder: { nil }, runCheck: { _ in .folderNotFound })

            try LocalModelSettingsView(model: model).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.localModelStatus)
                .callOnAppear()

            XCTAssertEqual(model.status, .checking)
        }

        // MARK: - Helpers

        private func makeSettings() throws -> AppSettings {
            let suite = "LocalModelSettingsTests-\(getpid())-\(UUID().uuidString)"
            addTeardownBlock { DefaultsSuite.remove(suite) }
            let settings = try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
            settings.protocolProvider = .localModel
            return settings
        }

        private func button(_ identifier: String, _ model: LocalModelSettingsModel) throws -> InspectableView<ViewType.Button> {
            try LocalModelSettingsView(model: model).inspect().find(viewWithAccessibilityIdentifier: identifier).button()
        }

        /// A fake helper in a directory of its own: it writes its arguments,
        /// one per line, to `arguments` beside it, then runs `body`.
        private func fakeHelper(_ body: String) throws -> URL {
            let directory = try makeTempDirectory(prefix: "LocalModelSettingsHelper")
            let url = directory.appendingPathComponent(LocalModelHelperLocator.executableName)
            let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(directory.path)/arguments'\n\(body)\n"
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
    }

    /// Checks the test answers by hand, per folder path, in any order: an
    /// answer given before its check asks is kept for it.
    @MainActor
    private final class ScriptedChecks {
        private var waiting: [String: CheckedContinuation<LocalModelCheckResult, Never>] = [:]
        private var answers: [String: LocalModelCheckResult] = [:]

        func run(_ folder: LocalModelFolderSelection) async -> LocalModelCheckResult {
            if let answer = answers.removeValue(forKey: folder.path) { return answer }
            return await withCheckedContinuation { waiting[folder.path] = $0 }
        }

        func finish(_ path: String, with result: LocalModelCheckResult) {
            if let continuation = waiting.removeValue(forKey: path) {
                continuation.resume(returning: result)
            } else {
                answers[path] = result
            }
        }
    }

#endif
