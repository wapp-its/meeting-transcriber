#if !APPSTORE

    import Foundation

    /// What the helper's `check` mode prints about a model folder, per the
    /// contract in `tools/local-llm-helper/README.md`: one JSON line on stdout.
    /// Keys the app does not show (`groupSize`) are not decoded.
    struct LocalModelCheckReport: Decodable, Equatable, Sendable {
        struct Quantization: Decodable, Equatable, Sendable {
            let bits: Int
        }

        /// One problem the check found. `file` is a name inside the folder,
        /// or `.` for the folder itself; `problem` is `missing`, `unreadable`,
        /// `invalid` or `unsupported`.
        struct Problem: Decodable, Equatable, Sendable {
            let file: String
            let problem: String
        }

        let usable: Bool
        /// The folder's name, which for a Hugging Face download is the model's.
        let name: String?
        /// `config.json`'s `model_type`, when readable.
        let modelType: String?
        /// Absent for an unquantised model.
        let quantization: Quantization?
        /// Bytes of the weight files on disk, absent when one is missing.
        let sizeBytes: UInt64?
        let problems: [Problem]
    }

    /// Why a check gave no verdict on the folder.
    enum LocalModelCheckFailure: Equatable, Sendable {
        /// No executable helper in the app bundle.
        case helperMissing
        case couldNotStart
        /// No answer within `LocalModelCheck.timeout`.
        case timedOut
        /// The helper exited with a status the check mode does not use.
        case exitStatus(Int32)
        /// Its stdout was not the report the contract describes.
        case unreadableReport
    }

    /// The verdict of one check, for the folder it ran on.
    enum LocalModelCheckResult: Equatable, Sendable {
        case ready(LocalModelCheckReport)
        /// The report names what is missing, unreadable, invalid or unsupported.
        case unusable(LocalModelCheckReport)
        /// No folder there: its bookmark no longer resolves, or nothing is at
        /// its path. The generator treats the same folder as no model.
        case folderNotFound
        case failed(LocalModelCheckFailure)
    }

    /// Settings' Check Model: runs the bundled helper's `check` mode on a
    /// model folder. The helper reads the configuration, tokenizer and chat
    /// template and only `stat`s the weight files, so a check never loads
    /// model weights (spec R1).
    ///
    /// The helper gets a fixed argument vector through `CLIProcessRunner`,
    /// never a shell, with stdin on `/dev/null` and the per-user temporary
    /// directory as its working directory, which has no privacy-protected
    /// folder on its path.
    enum LocalModelCheck {
        /// The longest a check may take before the helper is stopped. A check
        /// reads a few small files and renders a two-word prompt, which the
        /// spike measured in about a second for the tested model; 30 s leaves
        /// room for a cold or network volume and still ends a helper that hangs.
        static let timeout: TimeInterval = 30
        /// Far more than any report; stdout beyond it is not the helper's answer.
        static let maxReportBytes = 1 << 20

        static func run(
            _ folder: LocalModelFolderSelection,
            helper: URL? = LocalModelHelperLocator.locate(),
            timeout: TimeInterval = Self.timeout,
        ) async -> LocalModelCheckResult {
            guard let helper, LocalModelHelperLocator.isExecutableFile(helper) else { return .failed(.helperMissing) }
            guard let folderURL = folder.resolve() else { return .folderNotFound }
            let accessing = folderURL.startAccessingSecurityScopedResource()
            defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
            guard LocalModelJob.folderIsReachable(folderURL) else { return .folderNotFound }
            let request = CLIProcessRunner.Request(
                executable: helper,
                arguments: ["check", folderURL.path],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: FileManager.default.temporaryDirectory,
                standardInput: nil,
                timeout: timeout,
                maxStdoutBytes: maxReportBytes,
            )
            do {
                let output = try await CLIProcessRunner.run(request)
                return result(status: output.status, stdout: output.stdout)
            } catch CLIProcessRunner.Failure.timedOut {
                return .failed(.timedOut)
            } catch CLIProcessRunner.Failure.stdoutTooLarge {
                return .failed(.unreadableReport)
            } catch {
                return .failed(.couldNotStart)
            }
        }

        /// The verdict for the helper's exit `status` and what it printed:
        /// 0 is usable and 11 unusable, each with its report; any other status
        /// is a failed check. A report for the folder itself as missing is a
        /// folder that is not there.
        static func result(status: Int32, stdout: Data) -> LocalModelCheckResult {
            let usableStatus: Int32 = 0
            guard status == usableStatus || status == LocalModelHelperExitStatus.modelUnusable.rawValue else {
                return .failed(.exitStatus(status))
            }
            guard let report = try? JSONDecoder().decode(LocalModelCheckReport.self, from: stdout) else {
                return .failed(.unreadableReport)
            }
            if status == usableStatus, report.usable, report.problems.isEmpty {
                return .ready(report)
            }
            if report.problems.contains(LocalModelCheckReport.Problem(file: ".", problem: "missing")) {
                return .folderNotFound
            }
            return .unusable(report)
        }
    }

#endif
