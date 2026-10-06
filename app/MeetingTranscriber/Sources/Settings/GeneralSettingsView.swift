import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings

    /// Latest notification visibility from `PermissionsController`, or nil
    /// before the first check. Recording a meeting that asks first depends on
    /// it (the consent prompt is a notification), and nothing else in the app
    /// can say so without using the channel that is broken.
    var notificationVisibility: NotificationVisibility?

    @State private var addAppRefusals: [String] = []

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
                customApps
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
                    // With the switch on, no prompt reminds anyone that everyone
                    // must agree, so the switch carries the reminder instead.
                    if settings.recordWithoutAskingApps.contains(pattern.appName) {
                        Text(
                            """
                            Without the prompt, making sure everyone agrees to being recorded is entirely \
                            up to you (Art. 179bis StGB, Swiss Criminal Code).
                            """,
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(A11yID.recordWithoutAskingConsentNote(pattern.appName))
                    }
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

    @ViewBuilder private var customApps: some View {
        ForEach(Array(settings.watchCustomApps.enumerated()), id: \.element) { index, bundleID in
            HStack {
                Image(nsImage: Self.appIcon(bundleID: bundleID))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(MicInputDetector.appDisplayName(bundleID: bundleID))
                Spacer()
                Button("Remove") {
                    settings.watchCustomApps.removeAll { $0 == bundleID }
                }
                .accessibilityIdentifier(A11yID.watchCustomAppRemove(index))
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Button("Add App…", action: addCustomApps)
            Text("Recording starts when an added app keeps the microphone busy for a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(addAppRefusals, id: \.self) { refusal in
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func addCustomApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        addAppRefusals = addWatchedApps(at: panel.urls)
    }

    @discardableResult
    func addWatchedApps(at urls: [URL]) -> [String] {
        var refusals: [String] = []
        for url in urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if let refusal = Self.watchRefusal(name: name, bundleID: bundleID, info: bundle.infoDictionary ?? [:]) {
                if !refusals.contains(refusal) {
                    refusals.append(refusal)
                }
            } else if !settings.watchCustomApps.contains(bundleID) {
                settings.watchCustomApps.append(bundleID)
            }
        }
        return refusals
    }

    static func watchRefusal(
        name: String,
        bundleID: String,
        info: [String: Any],
        ownBundleID: String? = Bundle.main.bundleIdentifier,
    ) -> String? {
        if bundleID == ownBundleID {
            return "\(name) can't watch itself."
        }
        let executable = info["CFBundleExecutable"] as? String
        let builtInName = MicInputDetector.defaultPatterns.first { $0.bundleIDs.contains(bundleID) }?.appName
            ?? PowerAssertionDetector.defaultPatterns.first { executable.map($0.processNames.contains) ?? false }?.appName
        if let builtInName {
            return "\(builtInName) has its own toggle above."
        }
        guard isBrowser(info: info) else { return nil }
        return "\(name) is a browser and can't be watched as an app. Browser meetings are detected by Browser Web Meetings."
    }

    private static func isBrowser(info: [String: Any]) -> Bool {
        let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        let documentTypes = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let contentTypes = documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        let extensions = documentTypes.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
        let opensWeb = schemes.contains { ["http", "https"].contains($0.lowercased()) }
        let opensHTML = contentTypes.contains { ["public.html", "public.xhtml"].contains($0) }
            || extensions.contains { ["html", "htm", "xhtml", "shtml"].contains($0.lowercased()) }
        return opensWeb && opensHTML
    }

    private static func appIcon(bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
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
