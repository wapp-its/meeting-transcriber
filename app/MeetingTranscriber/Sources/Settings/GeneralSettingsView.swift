import AppKit
import SwiftUI
import UserNotifications

struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings

    /// Latest notification visibility from `PermissionsController`, or nil
    /// before the first check. Recording a meeting that asks first depends on
    /// it (the consent prompt is a notification), and nothing else in the app
    /// can say so without using the channel that is broken.
    var notificationVisibility: NotificationVisibility?

    /// Nil until the first permission check. The case, not just the message:
    /// how total the failure is decides the headline.
    private var browserConsentReadiness: BrowserConsentReadiness? {
        guard let notificationVisibility else { return nil }
        return BrowserConsentReadiness.evaluate(
            anyWatchedAppAsks: settings.anyWatchedAppAsksFirst,
            visibility: notificationVisibility,
        )
    }

    var body: some View {
        // swiftlint:disable:next closure_body_length
        Form {
            Section("Mode") {
                Toggle("Record-only mode", isOn: $settings.recordOnly)
                    .accessibilityIdentifier(A11yID.recordOnlyToggle)
                if settings.recordOnly {
                    recordOnlyBanner
                }
            }

            Section("Apps to Watch") {
                Toggle("Microsoft Teams", isOn: $settings.watchTeams)
                Toggle("Zoom", isOn: $settings.watchZoom)
                Toggle("Webex", isOn: $settings.watchWebex)
                Toggle("WeChat", isOn: $settings.watchWeChat)
                Toggle("Tencent Meeting", isOn: $settings.watchTencentMeeting)
                Toggle("FaceTime", isOn: $settings.watchFaceTime)
                Toggle("WhatsApp", isOn: $settings.watchWhatsApp)
                Toggle("Browser Web Meetings", isOn: $settings.watchBrowserMeetings)
                    .accessibilityIdentifier(A11yID.watchBrowserToggle)
                Text(
                    """
                    Detects web meetings (Google Meet, Whereby, web Zoom/Teams) by the WebRTC \
                    signal, so any browser works. Other apps that place calls can trigger it too; \
                    it always asks before recording, and "Never for this app" stops one for good.
                    """,
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                consentDenyList
            }

            Section("Record Without Asking") {
                ForEach(AppMeetingPattern.recordWithoutAskingCandidates, id: \.appName) { pattern in
                    Toggle(pattern.appName, isOn: recordWithoutAskingBinding(for: pattern.appName))
                        .disabled(!settings.watchApps.contains(pattern.appName))
                        .accessibilityIdentifier(A11yID.recordWithoutAskingToggle(pattern.appName))
                }
                Text(
                    """
                    Detected meetings ask before recording, with a notification offering Record, \
                    Ignore and "Never for this app". Meetings in the apps switched on here start \
                    recording as soon as they are detected. Browser meetings always ask.
                    """,
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                browserConsentWarning
            }

            Section("Detection") {
                HStack {
                    Text("Poll Interval")
                    Spacer()
                    TextField("", value: $settings.pollInterval, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.pollInterval, in: 1 ... 30, step: 0.5)
                        .labelsHidden()
                    Text("seconds").foregroundStyle(.secondary)
                }

                HStack {
                    Text("Grace Period")
                    Spacer()
                    TextField("", value: $settings.endGrace, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.endGrace, in: 1 ... 120, step: 1)
                        .labelsHidden()
                    Text("seconds").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Apps the user answered "Never for this app" about.
    ///
    /// Shown whenever the list is non-empty, deliberately NOT gated on any
    /// app's watch toggle: every app that asks can be denied, and a denial
    /// hidden behind a switched-off toggle would be impossible to undo. An
    /// empty list stays hidden: the only reason to come here is to take back a
    /// Never.
    ///
    /// Writes go through `ConsentDenyListStore`, the same path the consent gate
    /// uses, so list semantics live in one place instead of two.
    @ViewBuilder private var consentDenyList: some View {
        if !settings.consentDeniedApps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Never record these apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(settings.consentDeniedApps.enumerated()), id: \.element) { index, app in
                    HStack {
                        Text(app)
                            .font(.caption)
                        Spacer()
                        Button("Remove") {
                            ConsentDenyListStore(settings: settings).revert(app)
                        }
                        .accessibilityIdentifier(A11yID.consentDeniedAppRemove(index))
                    }
                }
            }
            .accessibilityIdentifier(A11yID.consentDenyListSection)
        }
    }

    /// Warns when a watched app asks first but the consent prompt cannot reach
    /// the user. Rendered here rather than as a notification for the obvious
    /// reason, and kept out of the menu-bar permission badge because this
    /// permission only matters for meetings that ask.
    @ViewBuilder private var browserConsentWarning: some View {
        if let readiness = browserConsentReadiness,
           let headline = readiness.headline,
           let warning = readiness.warning {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.callout.weight(.semibold))
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(A11yID.browserConsentWarning)
                    Button("Open Notification Settings") {
                        NSWorkspace.shared.open(Self.notificationSettingsURL)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .padding(8)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// One app's "record without asking" switch, stored as membership in
    /// `AppSettings.recordWithoutAskingApps`. Adding is idempotent and removing
    /// leaves the other entries in place, so a toggle can never duplicate or
    /// drop someone else's choice.
    private func recordWithoutAskingBinding(for appName: String) -> Binding<Bool> {
        Binding(
            get: { settings.recordWithoutAskingApps.contains(appName) },
            set: { enabled in
                let others = settings.recordWithoutAskingApps.filter { $0 != appName }
                settings.recordWithoutAskingApps = enabled ? others + [appName] : others
            },
        )
    }

    /// Deep link to System Settings > Notifications. Verified to land on the
    /// Notifications pane rather than merely opening the app.
    private static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.notifications",
    )!

    private var recordOnlyBanner: some View {
        let display = OutputSettingsLogic.displayPath(
            for: settings.effectiveOutputDir.appendingPathComponent("recordings"),
            home: FileManager.default.homeDirectoryForCurrentUser,
        )
        return Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Record-only mode is active.")
                    .font(.callout.weight(.semibold))
                Text(
                    "Files land in `\(display)`. Each recording gets a `<timestamp>_meta.json` " +
                        "sidecar next to its WAVs. No transcription, diarization, or protocol " +
                        "generation runs on this device.",
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
        }
        .padding(8)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier(A11yID.recordOnlyBanner)
    }
}
