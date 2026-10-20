import Foundation

/// The two watch loops the controller builds: the one that watches for
/// meetings (`toggleWatching`) and the one a manual recording runs on
/// (`performManualRecording`).
///
/// Its own file because `WatchingController.swift` sits at the line cap; the
/// members it reaches into (`notifier`, `makeDetector`, `settings`, `pipeline`,
/// `channelHealth`) are internal rather than private for exactly that.
@MainActor
extension WatchingController {
    /// A loop that watches for meetings, configured from the current settings.
    func makeAutoWatchLoop() -> WatchLoop {
        WatchLoop(
            detector: makeDetector(),
            recorderFactory: makeRecorderFactory(),
            pipelineQueue: pipeline.queue,
            pollInterval: settings.pollInterval,
            endGracePeriod: settings.endGrace,
            noMic: settings.noMic,
            micDeviceUID: { [settings] in settings.micDeviceUID.isEmpty ? nil : settings.micDeviceUID },
            verboseDiagnostics: { [settings] in settings.verboseDiagnostics },
            recordOnly: { [settings] in settings.recordOnly },
            // Decided per write, not per poll: the loop calls this once
            // when a record-only recording is persisted, so a folder that
            // cannot be reached is reported there (see the resolver).
            recordOnlyDestination: { [pipeline] in
                .production(parent: pipeline.outputDirectory.resolve())
            },
            recordWithoutAskingApps: { [settings] in settings.recordWithoutAskingApps },
            speechActivity: { [channelHealth] in channelHealth.speechActivity },
            silencePromptAfter: { [settings] in settings.silencePromptAfter },
            notifier: notifier,
            denyListStore: ConsentDenyListStore(settings: settings),
        )
    }

    /// A loop for one manual recording.
    ///
    /// Manual recording never polls the detector, so WatchLoop's default
    /// (unfiltered) detector here is inert, and so is the consent gate
    /// that hangs off it: a manual start never asks, so neither consent
    /// list is consulted and the defaults stand. If this path ever gains
    /// auto-detection, route it through `makeDetector()` like
    /// `makeAutoWatchLoop` so the "Apps to Watch" filter still applies, and
    /// pass both `denyListStore:` and `recordWithoutAskingApps:`.
    func makeManualRecordingLoop() -> WatchLoop {
        WatchLoop(
            recorderFactory: makeRecorderFactory(),
            pipelineQueue: pipeline.queue,
            pollInterval: settings.pollInterval,
            noMic: settings.noMic,
            micDeviceUID: { [settings] in settings.micDeviceUID.isEmpty ? nil : settings.micDeviceUID },
            verboseDiagnostics: { [settings] in settings.verboseDiagnostics },
            recordOnly: { [settings] in settings.recordOnly },
            // Same seam as the auto-watch loop above: per write, through the
            // shared resolver.
            recordOnlyDestination: { [pipeline] in
                .production(parent: pipeline.outputDirectory.resolve())
            },
            speechActivity: { [channelHealth] in channelHealth.speechActivity },
            silencePromptAfter: { [settings] in settings.silencePromptAfter },
            notifier: notifier,
        )
    }
}
