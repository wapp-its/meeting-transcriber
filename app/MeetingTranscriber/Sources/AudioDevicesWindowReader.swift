import Foundation
import Observation

/// The Audio Devices window's reader: what the window shows beyond the device
/// lists, read only while the window is open.
///
/// - Every 100 ms it samples values the app already holds: the two recorded
///   levels from `ChannelHealthController`, which keeps them unobserved so
///   that nothing redraws ten times a second for ever, and whether the
///   running recording's microphone track is active. It stores the levels as
///   lit segments and assigns only on a change, so the window redraws only
///   when a bar does.
/// - About once a second it reads, per device, whether Core Audio reports it
///   running for some process, and whether this app's own process runs audio
///   input; every five seconds, during a recording that taps an app, which
///   devices the tapped processes use (`AudioDeviceStatusProbe`).
///
/// **No Core Audio read on the main thread, and none waited for there** (issue
/// #588: coreaudiod can stop answering). A reading runs on `queue`, one at a
/// time, also across a close and a reopen of the window; one due while
/// another is out waits for it. A reading that has not returned two seconds
/// after it started is late: the rows it would answer read unknown, and when
/// it does return it is dropped, so the next reading answers them. A result
/// comes back by a main-actor hop and is adopted only while the window it was
/// started for is still open and is not late; the tapped processes' answer
/// only while the recording still taps the processes it asked about.
///
/// Opening the window reads nothing from the recording but those values: it
/// calls nothing on the recorder, opens no device and starts no capture.
@Observable
@MainActor
final class AudioDevicesWindowReader {
    /// Whether the window is open, so the readings run.
    private(set) var isOpen = false
    /// What the last current reading said; `.unknown` while the window is
    /// closed, before the first reading returns and while one is late.
    private(set) var status = AudioDeviceStatus.unknown
    /// `/state.audioDevicesWindow.selfRunningInput`; nil like `status`, and
    /// when Core Audio did not answer.
    private(set) var selfRunningInput: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The recorded levels as lit segments (`AudioDevicesWindowState.litSegments`).
    private(set) var micLitSegments = 0
    private(set) var appLitSegments = 0
    /// Whether the running recording's microphone track is active
    /// (`RecordingProvider.microphoneTrackActive`).
    private(set) var microphoneTrackActive = false

    static let sampleInterval: Duration = .milliseconds(100)
    static let readInterval: TimeInterval = 1
    static let meetingAppReadInterval: TimeInterval = 5
    static let readDeadline: TimeInterval = 2

    /// Where the Core Audio readings run, never the main queue.
    let queue = DispatchQueue(label: "com.meetingtranscriber.audio-device-status", qos: .utility)

    /// The reading out on `queue`, which stays out until it returns, whether
    /// or not the window is still open.
    private struct InFlight {
        let id: Int
        let generation: Int
        let startedAt: Date
        /// The tapped processes it asks about; empty when it does not ask.
        let meetingAppPIDs: [pid_t]
        var late = false
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Bumped at every close, so a reading started before tells.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextReadingID = 0
    @ObservationIgnored private var inFlight: InFlight?
    @ObservationIgnored private var lastReadingStartedAt: Date?
    @ObservationIgnored private var lastMeetingAppReadingStartedAt: Date?
    /// The running recording's tapped processes, empty without one.
    @ObservationIgnored private var tappedPIDs: [pid_t] = []
    /// The tapped processes `status.meetingApp` answers for; empty while it
    /// answers for none.
    @ObservationIgnored private var meetingAppAnsweredPIDs: [pid_t] = []

    /// One reading, given the tapped processes to ask about, empty to not ask.
    typealias Read = @Sendable ([pid_t]) -> AudioDeviceStatusReading

    /// The reading the app runs: Core Audio, through `AudioDeviceStatusProbe`.
    nonisolated static let coreAudioRead: Read = { AudioDeviceStatusProbe.read(tappedPIDs: $0) }

    private let read: Read
    private let levels: @MainActor () -> (mic: Double?, app: Double?)
    private let recorder: @MainActor () -> (any RecordingProvider)?
    private let now: () -> Date

    /// - Parameters:
    ///   - read: one reading (`Read`), run on `queue`.
    ///   - levels: the microphone and app-audio tracks' levels in dBFS.
    ///   - recorder: the running recording's recorder, nil without one.
    ///   - now: the clock the cadence and the deadline are measured on.
    init(
        read: @escaping Read = coreAudioRead,
        levels: @escaping @MainActor () -> (mic: Double?, app: Double?),
        recorder: @escaping @MainActor () -> (any RecordingProvider)?,
        now: @escaping () -> Date = Date.init,
    ) {
        self.read = read
        self.levels = levels
        self.recorder = recorder
        self.now = now
    }

    /// From the window's `onAppear`: start sampling and reading. A second call
    /// while open changes nothing.
    func windowOpened() {
        guard !isOpen else { return }
        isOpen = true
        tick()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// From the window's `onDisappear`: stop sampling and reading, and forget
    /// what was read. A reading still out stays out, and is dropped when it
    /// returns.
    func windowClosed() {
        loop?.cancel()
        loop = nil
        isOpen = false
        generation += 1
        status = .unknown
        selfRunningInput = nil
        micLitSegments = 0
        appLitSegments = 0
        microphoneTrackActive = false
        lastReadingStartedAt = nil
        lastMeetingAppReadingStartedAt = nil
        tappedPIDs = []
        meetingAppAnsweredPIDs = []
    }

    /// One 100 ms step of the loop: sample, mark a late reading, start the
    /// next reading when it is due.
    func tick() {
        guard isOpen else { return }
        sampleRecording()
        markLateReading()
        startReadingIfDue()
    }

    private func sampleRecording() {
        let recorder = recorder()
        let active = recorder?.microphoneTrackActive ?? false
        if microphoneTrackActive != active { microphoneTrackActive = active }
        let pids = recorder?.tappedPIDs ?? []
        if pids != tappedPIDs {
            // Another recording's taps, or none: the answer about the old
            // ones says nothing about these.
            tappedPIDs = pids
            meetingAppAnsweredPIDs = []
            if status.meetingApp != nil { status = AudioDeviceStatus(running: status.running, meetingApp: nil) }
        }
        let (mic, app) = levels()
        let micLit = AudioDevicesWindowState.litSegments(dBFS: mic)
        if micLitSegments != micLit { micLitSegments = micLit }
        let appLit = AudioDevicesWindowState.litSegments(dBFS: app)
        if appLitSegments != appLit { appLitSegments = appLit }
    }

    private func markLateReading() {
        guard var flight = inFlight, !flight.late,
              now().timeIntervalSince(flight.startedAt) >= Self.readDeadline
        else { return }
        flight.late = true
        inFlight = flight
        if status != .unknown { status = .unknown }
        if selfRunningInput != nil { selfRunningInput = nil }
        meetingAppAnsweredPIDs = []
    }

    private func startReadingIfDue() {
        guard inFlight == nil else { return }
        let time = now()
        let meetingAppStale = Self.elapsed(since: lastMeetingAppReadingStartedAt, at: time) >= Self.meetingAppReadInterval
        let meetingAppDue = !tappedPIDs.isEmpty && (meetingAppAnsweredPIDs != tappedPIDs || meetingAppStale)
        let statusDue = status.running == nil || Self.elapsed(since: lastReadingStartedAt, at: time) >= Self.readInterval
        guard statusDue || meetingAppDue else { return }

        let id = nextReadingID
        nextReadingID += 1
        let pids = meetingAppDue ? tappedPIDs : []
        inFlight = InFlight(id: id, generation: generation, startedAt: time, meetingAppPIDs: pids)
        lastReadingStartedAt = time
        if meetingAppDue { lastMeetingAppReadingStartedAt = time }
        let read = read
        queue.async { [weak self] in
            let reading = read(pids)
            Task { @MainActor in
                self?.adopt(reading, id: id)
            }
        }
    }

    private func adopt(_ reading: AudioDeviceStatusReading, id: Int) {
        guard let flight = inFlight, flight.id == id else { return }
        inFlight = nil
        guard flight.generation == generation, isOpen, !flight.late else { return }

        var meetingApp = status.meetingApp
        // The recording can have ended, or another started, while the read was out.
        if !flight.meetingAppPIDs.isEmpty, flight.meetingAppPIDs == tappedPIDs {
            meetingApp = reading.meetingApp
            meetingAppAnsweredPIDs = flight.meetingAppPIDs
        }
        let current = AudioDeviceStatus(running: reading.running, meetingApp: meetingApp)
        if status != current { status = current }
        if selfRunningInput != reading.selfRunningInput { selfRunningInput = reading.selfRunningInput }
    }

    private static func elapsed(since start: Date?, at time: Date) -> TimeInterval {
        start.map { time.timeIntervalSince($0) } ?? .infinity
    }
}
