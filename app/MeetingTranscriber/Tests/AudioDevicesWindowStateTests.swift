@testable import MeetingTranscriber
import XCTest

/// Every arm of the Audio Devices window, decided without the window.
final class AudioDevicesWindowStateTests: XCTestCase {
    private typealias State = AudioDevicesWindowState
    private typealias Mark = AudioDevicesWindowState.Mark

    private static let builtInMic = MicrophoneDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private static let headsetMic = MicrophoneDevice(uid: "HeadsetUID", name: "USB Headset")
    private static let speakers = OutputDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
    private static let headsetOut = OutputDevice(uid: "HeadsetUID", name: "USB Headset")

    /// Every device read, the built-in pair running.
    private static let allRead = AudioDeviceStatus(
        running: ["BuiltInMicrophoneDevice": true, "HeadsetUID": false, "BuiltInSpeakerDevice": true],
        meetingApp: nil,
    )

    /// Teams on the built-in microphone and the headset's output.
    private static let teamsDevices = MeetingAppDevices(
        inputUIDs: ["BuiltInMicrophoneDevice"], outputUIDs: ["HeadsetUID"], inputComplete: true, outputComplete: true,
    )

    private static func recording(
        capturesApp: Bool = true, recordedMicrophoneUID: String? = "HeadsetUID", paused: Bool = false,
    ) -> State.Recording {
        State.Recording(
            capturesApp: capturesApp, appName: capturesApp ? "Teams" : nil, recordedMicrophoneUID: recordedMicrophoneUID,
            paused: paused, micLitSegments: 7, appLitSegments: 4,
        )
    }

    private func resolve(
        microphones: [MicrophoneDevice] = [builtInMic, headsetMic],
        configuredMicrophoneUID: String = "",
        outputs: [OutputDevice] = [speakers, headsetOut],
        defaultOutput: OutputDevice? = speakers,
        meetingAppHint: String? = nil,
        recording: State.Recording? = nil,
        status: AudioDeviceStatus = allRead,
    ) -> State {
        State(State.Inputs(
            microphones: microphones, defaultInputUID: "BuiltInMicrophoneDevice",
            configuredMicrophoneUID: configuredMicrophoneUID, outputs: outputs, defaultOutput: defaultOutput,
            meetingAppHint: meetingAppHint, recording: recording, status: status,
        ))
    }

    private func marks(_ state: State) -> [String: [Mark]] {
        Dictionary(state.rows.map { ("\($0.group.rawValue): \($0.name)", $0.marks) }) { first, _ in first }
    }

    // MARK: - Without a recording

    /// Both lists in the menus' order, a device with input and output in both,
    /// the status marks, no level column, no Meeting audio group, the idle
    /// footer; and no Recording or Used by mark although the reader still
    /// holds an answer about the meeting app.
    func testWithoutARecordingRowsShowStatusOnly() {
        let status = AudioDeviceStatus(running: Self.allRead.running, meetingApp: Self.teamsDevices)
        let state = resolve(status: status)

        XCTAssertEqual(state.microphones.title, "Microphones")
        XCTAssertEqual(state.outputs.title, "Outputs")
        XCTAssertEqual(state.rows.map(\.name), ["MacBook Pro Microphone", "USB Headset", "MacBook Pro Speakers", "USB Headset"])
        XCTAssertEqual(marks(state), [
            "microphone: MacBook Pro Microphone": [.inUse, .systemDefault],
            "microphone: USB Headset": [],
            "output: MacBook Pro Speakers": [.inUse, .systemDefault],
            "output: USB Headset": [],
        ])
        XCTAssertFalse(state.showsLevelColumn)
        XCTAssertNil(state.meetingAudio)
        XCTAssertEqual(state.rows.compactMap(\.litSegments), [])
        XCTAssertEqual(
            state.footer,
            "Levels show while a recording runs. To switch a device, use Microphone or Output in the menu bar.",
        )
    }

    // MARK: - During a recording

    /// The recorded microphone and the Meeting audio row carry Recording and a
    /// bar; the meeting app's devices carry "Used by Teams"; every other row
    /// shows "no level" in the column.
    func testAnAppAndMicrophoneRecordingMarksWhatItRecordsAndWhatTheAppUses() {
        let status = AudioDeviceStatus(running: Self.allRead.running, meetingApp: Self.teamsDevices)
        let state = resolve(recording: Self.recording(), status: status)

        XCTAssertEqual(marks(state), [
            "microphone: MacBook Pro Microphone": [.meetingApp, .inUse, .systemDefault],
            "microphone: USB Headset": [.recording],
            "output: MacBook Pro Speakers": [.inUse, .systemDefault],
            "output: USB Headset": [.meetingApp],
            "meetingAudio: Teams": [.recording],
        ])
        XCTAssertEqual(state.rows.map(\.litSegments), [nil, 7, nil, nil, 4])
        XCTAssertEqual(state.rows.map(\.meetingApp), ["Teams", nil, nil, "Teams", nil])
        XCTAssertEqual(state.meetingAudio?.title, "Meeting audio")
        XCTAssertTrue(state.showsLevelColumn)
        XCTAssertEqual(
            state.footer,
            "Levels show for what this recording captures. To switch a device, use Microphone or Output in the menu bar.",
        )
    }

    /// The order and words of the boards: Recording, Used by <App>, In use, Default.
    func testMarksKeepTheBoardsOrderAndWords() throws {
        let status = AudioDeviceStatus(
            running: ["HeadsetUID": true],
            meetingApp: MeetingAppDevices(inputUIDs: ["HeadsetUID"], outputUIDs: [], inputComplete: true, outputComplete: true),
        )
        let state = State(State.Inputs(
            microphones: [Self.headsetMic], defaultInputUID: "HeadsetUID", configuredMicrophoneUID: "",
            outputs: [], defaultOutput: nil, meetingAppHint: nil, recording: Self.recording(), status: status,
        ))

        let row = try XCTUnwrap(state.microphones.rows.first)
        XCTAssertEqual(row.marks, [.recording, .meetingApp, .inUse, .systemDefault])
        XCTAssertEqual(row.marks.map { $0.label(meetingApp: row.meetingApp) }, ["Recording", "Used by Teams", "In use", "Default"])
    }

    /// Which recording decides which groups and bars there are.
    func testTheRecordingDecidesTheMeetingAudioGroupAndTheMicrophoneBar() {
        let cases: [(name: String, recording: State.Recording, meetingAudio: Bool, micBar: Bool)] = [
            ("microphone only", Self.recording(capturesApp: false), false, true),
            ("app only, or a microphone track that gave up", Self.recording(recordedMicrophoneUID: nil), true, false),
            ("app and microphone", Self.recording(), true, true),
        ]
        for testCase in cases {
            let state = resolve(recording: testCase.recording)

            XCTAssertEqual(state.meetingAudio != nil, testCase.meetingAudio, testCase.name)
            XCTAssertEqual(state.microphones.rows.contains { $0.litSegments != nil }, testCase.micBar, testCase.name)
            XCTAssertEqual(state.microphones.rows.contains { $0.marks.contains(.recording) }, testCase.micBar, testCase.name)
            XCTAssertTrue(state.showsLevelColumn, testCase.name)
        }
    }

    /// Paused: the bars light nothing and the Meeting audio row says Paused,
    /// after Recording.
    func testAPausedRecordingLightsNoSegmentAndSaysPaused() throws {
        let state = resolve(recording: Self.recording(paused: true))

        let meetingAudio = try XCTUnwrap(state.meetingAudio?.rows.first)
        XCTAssertEqual(meetingAudio.marks, [.recording, .paused])
        XCTAssertEqual(meetingAudio.marks.map { $0.label(meetingApp: nil) }, ["Recording", "Paused"])
        XCTAssertEqual(state.rows.compactMap(\.litSegments), [0, 0])
    }

    // MARK: - States the boards do not draw

    func testAnEmptyGroupHasNoRowsForTheWindowToShowNoneFoundIn() {
        let state = resolve(microphones: [], outputs: [], defaultOutput: nil)

        XCTAssertEqual(state.microphones.rows, [])
        XCTAssertEqual(state.outputs.rows, [])
        XCTAssertEqual(State.noneFound, "None found")
    }

    /// Listed as the Microphone entry lists it, and never unknown: there is
    /// no device to ask.
    func testAConfiguredMicrophoneThatIsNotConnectedIsListedAsNotConnected() throws {
        let state = resolve(configuredMicrophoneUID: "GoneUID", status: .unknown)

        let row = try XCTUnwrap(state.microphones.rows.last)
        XCTAssertEqual(row.name, "Selected microphone")
        XCTAssertEqual(row.marks, [.notConnected])
        XCTAssertEqual(row.marks.map { $0.label(meetingApp: nil) }, ["Not connected"])
        XCTAssertEqual(state.microphones.rows.count, 3)
    }

    /// The Teams device the Mac does not offer is listed with Default and the
    /// orange Warning, and the Output entry's hint line goes under the list.
    func testTheTeamsOutputCarriesTheRoutingWarningAndTheOutputHint() throws {
        let teams = OutputDevice(uid: OutputRoutingWarning.teamsLoopbackUID, name: "Microsoft Teams Audio")
        let state = resolve(outputs: [Self.speakers], defaultOutput: teams)

        let row = try XCTUnwrap(state.outputs.rows.last)
        XCTAssertEqual(state.outputs.rows.map(\.name), ["MacBook Pro Speakers", "Microsoft Teams Audio"])
        XCTAssertEqual(row.marks, [.unknown, .systemDefault, .routingWarning])
        XCTAssertEqual(row.marks.map { $0.label(meetingApp: nil) }, ["Status unknown", "Default", "Warning"])
        XCTAssertEqual(state.outputs.hint, OutputRoutingWarning.menuHint)
        XCTAssertNil(resolve().outputs.hint)
    }

    /// The Microphone entry's hint, word for word, under the Microphones list.
    func testTheMeetingAppHintGoesUnderTheMicrophonesList() {
        XCTAssertEqual(resolve(meetingAppHint: "Teams uses USB Headset").microphones.hint, "Teams uses USB Headset")
        XCTAssertNil(resolve().microphones.hint)
    }

    /// "Could not ask" never reads as "not running": no current reading, a
    /// device the reading missed, and a meeting-app read that failed on one
    /// side each show Status unknown, and only where they apply.
    func testAFailedOrLateReadShowsUnknownNeverNotRunning() {
        let noReading = resolve(recording: Self.recording(), status: .unknown)
        XCTAssertTrue(noReading.microphones.rows.allSatisfy { $0.marks.contains(.unknown) && !$0.marks.contains(.inUse) })
        XCTAssertTrue(noReading.outputs.rows.allSatisfy { $0.marks.contains(.unknown) })
        XCTAssertEqual(noReading.meetingAudio?.rows.first?.marks, [.recording])

        let missed = resolve(status: AudioDeviceStatus(running: ["BuiltInMicrophoneDevice": true], meetingApp: nil))
        XCTAssertEqual(missed.microphones.rows.map(\.marks), [[.inUse, .systemDefault], [.unknown]])

        let inputFailed = AudioDeviceStatus(
            running: Self.allRead.running,
            meetingApp: MeetingAppDevices(inputUIDs: [], outputUIDs: ["HeadsetUID"], inputComplete: false, outputComplete: true),
        )
        let partly = resolve(recording: Self.recording(), status: inputFailed)
        XCTAssertTrue(partly.microphones.rows.allSatisfy { $0.marks.contains(.unknown) })
        XCTAssertEqual(partly.outputs.rows.map(\.marks), [[.inUse, .systemDefault], [.meetingApp]])
    }

    /// `OutputDevices` names a device by its UID when Core Audio gives no
    /// name; a USB UID carries the serial number.
    func testAnOutputNamedByItsUIDIsAnUnnamedDevice() {
        let uid = "AppleUSBAudioEngine:Vendor:Headset:SERIAL123:1"
        let unnamed = OutputDevice(uid: uid, name: uid)
        let state = resolve(outputs: [unnamed], defaultOutput: unnamed)

        XCTAssertEqual(state.outputs.rows.map(\.name), ["Unnamed device"])
        XCTAssertFalse(state.rows.contains { $0.name.contains("SERIAL123") })
    }

    // MARK: - Level bar

    /// One segment per 5 dB above -60 dBFS; the -120 a track reports half a
    /// second after it stops delivering lights none.
    func testTheLevelLightsOneSegmentPerFiveDecibelsAboveMinusSixty() {
        let cases: [(dBFS: Double?, lit: Int)] = [
            (nil, 0), (-120, 0), (-60, 0), (-57, 0), (-55, 1), (-30, 6), (-0.1, 11), (0, 12), (6, 12),
        ]
        for testCase in cases {
            XCTAssertEqual(State.litSegments(dBFS: testCase.dBFS), testCase.lit, "\(String(describing: testCase.dBFS)) dBFS")
        }
    }
}
