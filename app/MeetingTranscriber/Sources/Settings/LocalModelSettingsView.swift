// Settings → Output for the local model provider: the model folder with
// Choose…, the status line with Check Model, and the notes from the accepted
// mockup (spec R1, screens 1 and 2).

#if !APPSTORE

    import AppKit
    import Observation
    import SwiftUI

    /// What the status line says about the chosen model folder.
    enum LocalModelStatus: Equatable {
        case noFolder
        /// A folder is chosen and no check has run for it.
        case notChecked
        case checking
        case checked(LocalModelCheckResult)

        enum Tone {
            case ready, warning, neutral
        }

        /// Check Model runs for a chosen folder, one check at a time.
        var allowsCheck: Bool {
            self != .noFolder && self != .checking
        }

        var tone: Tone {
            switch self {
            case .checked(.ready): .ready
            case .notChecked, .checking: .neutral
            case .noFolder, .checked: .warning
            }
        }

        var text: String {
            switch self {
            case .noFolder: "No model chosen. Protocols are not written until one is set."
            case .notChecked: "Not checked yet."
            case .checking: "Checking the model folder\u{2026}"
            case let .checked(.ready(report)): Self.readyText(report)
            case let .checked(.unusable(report)): Self.unusableText(report)
            case .checked(.folderNotFound): "Model folder not found. Choose it again."
            case let .checked(.failed(failure)): Self.failureText(failure)
            }
        }

        /// "Qwen3.8-27B · 4-bit · 16.1 GB · ready", as on the mockup: the
        /// quantisation suffix of a Hugging Face folder name is left out of
        /// the name because the line names it on its own.
        static func readyText(_ report: LocalModelCheckReport) -> String {
            let bits = report.quantization?.bits
            let parts: [String?] = [
                report.name.map { displayName($0, bits: bits) },
                bits.map { "\($0)-bit" },
                report.sizeBytes.map(gigabytes),
                "ready",
            ]
            return parts.compactMap(\.self).joined(separator: " \u{00B7} ")
        }

        static func displayName(_ name: String, bits: Int?) -> String {
            guard let bits else { return name }
            let suffix = "-\(bits)bit"
            guard name.count > suffix.count, name.lowercased().hasSuffix(suffix) else { return name }
            return String(name.dropLast(suffix.count))
        }

        /// Decimal gigabytes with one decimal, as Finder counts them.
        static func gigabytes(_ bytes: UInt64) -> String {
            String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }

        /// Names every problem the check found: the folder itself, an
        /// unsupported model type, then the files by kind of problem.
        static func unusableText(_ report: LocalModelCheckReport) -> String {
            var sentences = ["Not a usable model."]
            let problems = report.problems
            if problems.contains(where: { $0.file == "." }) {
                sentences.append("The folder cannot be read.")
            }
            if problems.contains(where: { $0.problem == "unsupported" }) {
                sentences.append(report.modelType.map { "Model type \($0) is not supported." } ?? "Its model type is not supported.")
            }
            let fileProblems = problems.filter { $0.file != "." && $0.problem != "unsupported" }
            let kinds: [(problem: String, label: String)] = [("missing", "Missing"), ("unreadable", "Unreadable"), ("invalid", "Invalid")]
            var groups = kinds.map { kind in (kind.label, fileProblems.filter { $0.problem == kind.problem }) }
            groups.append(("Problem with", fileProblems.filter { found in !kinds.contains { $0.problem == found.problem } }))
            for (label, found) in groups where !found.isEmpty {
                sentences.append("\(label): \(found.map(\.file).joined(separator: ", ")).")
            }
            return sentences.joined(separator: " ")
        }

        static func failureText(_ failure: LocalModelCheckFailure) -> String {
            switch failure {
            case .helperMissing: "Cannot check: the local model helper is not in this app."
            case .couldNotStart: "Cannot check: the local model helper did not start."
            case .timedOut: "Cannot check: no answer from the local model helper within \(Int(LocalModelCheck.timeout)) seconds."
            case let .exitStatus(status): "Cannot check: the local model helper failed (status \(status))."
            case .unreadableReport: "Cannot check: the local model helper gave no readable answer."
            }
        }
    }

    /// The local model rows' state and every write they make, held as a
    /// reference type so a test reads back the object the view writes to (as
    /// with `SpeakerNamingRowState`, CLAUDE.md, GUI Testing, rung 2).
    ///
    /// A check's result belongs to the folder it ran on and is shown only
    /// while that folder is the chosen one; a check that ends after another
    /// check started is dropped. A superseded check is not stopped: it ends on
    /// its own within `LocalModelCheck.timeout`.
    @Observable
    @MainActor
    final class LocalModelSettingsModel {
        private enum Check {
            case running(LocalModelFolderSelection)
            case finished(LocalModelFolderSelection, LocalModelCheckResult)
        }

        private var check: Check?
        @ObservationIgnored private var generation = 0

        private let settings: AppSettings
        private let pickFolder: @MainActor () -> URL?
        private let runCheck: @Sendable (LocalModelFolderSelection) async -> LocalModelCheckResult

        init(
            settings: AppSettings,
            pickFolder: @escaping @MainActor () -> URL? = LocalModelSettingsModel.showFolderPanel,
            runCheck: @escaping @Sendable (LocalModelFolderSelection) async -> LocalModelCheckResult = { await LocalModelCheck.run($0) },
        ) {
            self.settings = settings
            self.pickFolder = pickFolder
            self.runCheck = runCheck
        }

        var folderDisplay: String {
            let path = settings.localModelFolder.path
            guard !path.isEmpty else { return "Not set" }
            return OutputSettingsLogic.displayPath(
                for: URL(fileURLWithPath: path),
                home: FileManager.default.homeDirectoryForCurrentUser,
            )
        }

        var status: LocalModelStatus {
            let folder = settings.localModelFolder
            guard !folder.path.isEmpty else { return .noFolder }
            switch check {
            case let .running(checked) where checked == folder: return .checking
            case let .finished(checked, result) where checked == folder: return .checked(result)
            default: return .notChecked
            }
        }

        /// Choose…: stores the picked folder and checks it at once.
        @discardableResult
        func chooseFolder() -> Task<Void, Never>? {
            guard let url = pickFolder() else { return nil }
            settings.setLocalModelFolder(url)
            return startCheck()
        }

        /// Check Model. Returns the check's task, which ends once its result
        /// is applied or dropped.
        @discardableResult
        func startCheck() -> Task<Void, Never>? {
            let folder = settings.localModelFolder
            guard !folder.path.isEmpty else { return nil }
            generation += 1
            let current = generation
            check = .running(folder)
            let runCheck = runCheck
            return Task {
                let result = await runCheck(folder)
                guard current == generation else { return }
                check = .finished(folder, result)
            }
        }

        /// Checks the chosen folder when nothing has checked it yet, so the
        /// status line shows the folder's state when the rows appear.
        @discardableResult
        func checkIfNeeded() -> Task<Void, Never>? {
            status == .notChecked ? startCheck() : nil
        }

        static func showFolderPanel() -> URL? {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = "Choose the folder of an MLX model"
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    }

    /// The local model's rows in Settings → Output, below the provider picker.
    struct LocalModelSettingsView: View {
        /// The tested model links to its Hugging Face page.
        private static let folderCaption: LocalizedStringKey =
            "A model folder from Hugging Face in MLX format. Tested: [mlx-community/Qwen3.8-27B-4bit](https://huggingface.co/mlx-community/Qwen3.8-27B-4bit) (16 GB)."

        /// SwiftUI keeps the first object it is handed for the view's
        /// lifetime, so a test holds the object every control here writes to.
        @State private var model: LocalModelSettingsModel

        init(model: LocalModelSettingsModel) {
            _model = State(initialValue: model)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Model folder")
                    Spacer()
                    Text(model.folderDisplay)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose\u{2026}") { model.chooseFolder() }
                        .accessibilityIdentifier(A11yID.localModelChooseFolderButton)
                }
                Text(Self.folderCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    statusLine
                    Spacer()
                    Button("Check Model") { model.startCheck() }
                        .disabled(!model.status.allowsCheck)
                        .accessibilityIdentifier(A11yID.localModelCheckButton)
                }
                Group {
                    if model.status == .noFolder {
                        Text("Transcripts are still saved. Download the model folder, then choose it here.")
                    } else {
                        Text(
                            "Runs on this Mac; the transcript never leaves it. Uses about 18 GB of memory while it writes, "
                                + "about 4 minutes for a one-hour meeting.",
                        )
                        Text("Waits while a recording runs. Stops if the Mac runs low on memory. The transcript is always kept.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }

        /// The status, kept current: it checks a folder nothing has checked
        /// yet when it appears.
        private var statusLine: some View {
            let status = model.status
            return HStack(spacing: 6) {
                switch status.tone {
                case .ready:
                    Image(systemName: "checkmark.circle.fill").accessibilityLabel("Ready")

                case .warning:
                    Image(systemName: "exclamationmark.triangle.fill").accessibilityLabel("Warning")

                case .neutral where status == .checking:
                    ProgressView().controlSize(.small)

                case .neutral:
                    EmptyView()
                }
                Text(status.text)
                    .fontWeight(status.tone == .neutral ? .regular : .medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Self.color(of: status.tone))
            .accessibilityIdentifier(A11yID.localModelStatus)
            .onAppear { model.checkIfNeeded() }
        }

        private static func color(of tone: LocalModelStatus.Tone) -> Color {
            switch tone {
            case .ready: .green
            case .warning: .orange
            case .neutral: .secondary
            }
        }
    }

#endif
