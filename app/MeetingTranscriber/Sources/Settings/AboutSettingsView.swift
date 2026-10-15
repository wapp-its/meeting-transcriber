import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Bindable var settings: AppSettings
    var updateChecker: UpdateChecker?
    /// Why "Install Update" is not possible right now (`UpdateInstallGate`),
    /// shown under the disabled button; nil when nothing blocks it.
    var updateInstallBlockedReason: String?
    /// Starts an mt-update install; nil leaves "Install Update" disabled.
    var onInstallUpdate: (() -> Void)?

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: Self.versionString)
                    .textSelection(.enabled)
                LabeledContent("Identifier", value: Bundle.main.bundleID)
                    .textSelection(.enabled)
                LabeledContent("Build Date", value: Self.buildDate)
                    .textSelection(.enabled)
                LabeledContent("ffmpeg") {
                    Label(
                        FFmpegHelper.isAvailable ? "Available" : "Not installed",
                        systemImage: FFmpegHelper.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill",
                    )
                    .foregroundStyle(FFmpegHelper.isAvailable ? .green : .secondary)
                    .font(.caption)
                }
                Link("GitHub", destination: Self.githubURL)
            }

            if let updateChecker {
                updatesSection(updateChecker: updateChecker)
            }
        }
        .formStyle(.grouped)
    }

    // swiftlint:disable:next force_unwrapping
    private static let githubURL = URL(string: "https://github.com/\(GitHubReleaseProvider.owner)/\(GitHubReleaseProvider.repo)")!

    private static let versionString: String = {
        let version = Bundle.main.appVersion
        let commit = Bundle.main.gitCommitHash
        #if APPSTORE
            let variant = "App Store"
        #else
            let variant = "Homebrew"
        #endif
        return "\(version) (\(commit)) · \(variant)"
    }()

    private static let buildDate: String = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date
        else { return "unknown" }
        return fmt.string(from: date)
    }()

    private func updatesSection(updateChecker: UpdateChecker) -> some View {
        // swiftlint:disable:next closure_body_length
        Section("Updates") {
            Toggle("Check for Updates", isOn: $settings.checkForUpdates)

            // mt-update builds whatever its branches hold, so a release
            // channel means nothing to it.
            if updateChecker.isMtUpdateMode {
                Text("Updates are built on this Mac by mt-update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if settings.checkForUpdates {
                Toggle("Include Pre-Releases", isOn: $settings.includePreReleases)
            }

            HStack {
                Button {
                    updateChecker.checkNow(
                        includePreReleases: settings.includePreReleases,
                    )
                } label: {
                    HStack(spacing: 4) {
                        if updateChecker.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Check Now")
                    }
                }
                .disabled(updateChecker.isChecking || updateChecker.isInstalling)

                if let error = updateChecker.lastError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                } else if let name = availableUpdateName(updateChecker) {
                    Label(
                        "Update available: \(name)",
                        systemImage: "arrow.down.circle.fill",
                    )
                    .foregroundStyle(.blue)
                    .font(.caption)
                } else if updateChecker.lastCheckDate != nil {
                    Label("Up to date", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            if updateChecker.isMtUpdateMode {
                mtUpdateInstallRows(updateChecker: updateChecker)
            } else if let update = updateChecker.availableUpdate {
                Button {
                    NSWorkspace.shared.open(update.dmgURL ?? update.htmlURL)
                } label: {
                    Label(
                        "Download \(update.tagName)",
                        systemImage: "arrow.down.to.line",
                    )
                }
            }
        }
    }

    /// What the status line offers: a newer GitHub release's tag, or what a
    /// newer mt-update build brings. Each mode sets only its own.
    private func availableUpdateName(_ updateChecker: UpdateChecker) -> String? {
        updateChecker.availableUpdate?.tagName ?? updateChecker.availableBuildSummary
    }

    /// mt-update mode under the status line: the install that runs, or the
    /// button that starts one, then why the last install failed. No
    /// confirmation dialog; the caption says what pressing it does.
    @ViewBuilder
    private func mtUpdateInstallRows(updateChecker: UpdateChecker) -> some View {
        if updateChecker.isInstalling {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing update… Meeting Transcriber restarts when the build is done and nothing is recording or processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if updateChecker.availableBuildSummary != nil {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    onInstallUpdate?()
                } label: {
                    Label("Install Update", systemImage: "arrow.down.to.line")
                }
                .disabled(updateInstallBlockedReason != nil || updateChecker.isChecking || onInstallUpdate == nil)
                .accessibilityIdentifier(A11yID.updateInstallButton)

                Text(installCaption(updateChecker: updateChecker))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let installError = updateChecker.lastInstallError {
            Label(installError, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    /// Why the button is disabled, so About names it (R4), else what pressing
    /// it does. A gate reason outranks the running check: both work on
    /// mt-update's checkout, and the recording or job is the one that lasts.
    private func installCaption(updateChecker: UpdateChecker) -> String {
        if let reason = updateInstallBlockedReason {
            return reason
        }
        if updateChecker.isChecking {
            return "Not available while checking for updates."
        }
        return "Builds the new version (about 5–10 minutes), then restarts Meeting Transcriber."
    }
}
