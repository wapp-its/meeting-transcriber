@testable import MeetingTranscriber
import XCTest

final class RecordingSidecarTests: XCTestCase {
    private func makeFullSidecar() -> RecordingSidecar {
        RecordingSidecar(
            title: "Standup",
            appName: "Microsoft Teams",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            stoppedAt: Date(timeIntervalSince1970: 1_777_001_800),
            participants: ["Alice", "Bob"],
            micDelaySeconds: 0.12,
            trigger: .manual,
            mixFilename: "20260503_083000_mix.wav",
            appFilename: "20260503_083000_app.wav",
            micFilename: "20260503_083000_mic.wav",
        )
    }

    /// Writes `json` under the sidecar's own naming convention and reads it
    /// back through the real `read()` path, which swallows decode errors —
    /// a bespoke decoder here would not show what production actually gets.
    private func readRawSidecar(_ json: String) throws -> RecordingSidecar? {
        let dir = try makeTempDirectory(prefix: "rs-raw")
        let basename = "raw"
        let url = dir.appendingPathComponent("\(basename)\(RecordingSidecar.filenameSuffix)")
        try Data(json.utf8).write(to: url)
        return RecordingSidecar.read(fromDirectory: dir, basename: basename)
    }

    private func encodeAsDict(_ sidecar: RecordingSidecar) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    func test_encode_includesAllFields() throws {
        let sidecar = makeFullSidecar()
        let dict = try encodeAsDict(sidecar)

        XCTAssertEqual(dict["version"] as? Int, 3)
        XCTAssertEqual(dict["title"] as? String, "Standup")
        XCTAssertEqual(dict["appName"] as? String, "Microsoft Teams")
        XCTAssertEqual(dict["participants"] as? [String], ["Alice", "Bob"])
        XCTAssertEqual(dict["micDelaySeconds"] as? Double, 0.12)
        XCTAssertEqual(dict["trigger"] as? String, "manual")
        XCTAssertNotNil(dict["startedAt"] as? String)
        XCTAssertNotNil(dict["stoppedAt"] as? String)

        let files = dict["files"] as? [String: Any]
        XCTAssertEqual(files?["mix"] as? String, "20260503_083000_mix.wav")
        XCTAssertEqual(files?["app"] as? String, "20260503_083000_app.wav")
        XCTAssertEqual(files?["mic"] as? String, "20260503_083000_mic.wav")
    }

    func test_encode_omitsMicAndAppWhenNil() throws {
        let sidecar = RecordingSidecar(
            title: "Solo",
            appName: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            stoppedAt: Date(timeIntervalSince1970: 1_777_000_600),
            participants: [],
            micDelaySeconds: 0,
            trigger: .auto,
            mixFilename: "mix.wav",
            appFilename: nil,
            micFilename: nil,
        )
        let dict = try encodeAsDict(sidecar)
        let files = dict["files"] as? [String: Any]
        XCTAssertNotNil(files)
        XCTAssertEqual(files?["mix"] as? String, "mix.wav")
        XCTAssertNil(files?["app"], "app filename should be omitted when nil")
        XCTAssertNil(files?["mic"], "mic filename should be omitted when nil")
    }

    /// Each pause is written with its wall-clock times and its position on the
    /// saved tracks; a recording without one has no `pauses` key at all.
    func test_encode_writesPausesOnlyWhenThereAreSome() throws {
        let start = Date(timeIntervalSince1970: 1_777_000_000)
        let pause = RecordingPause(startedAt: start + 600, endedAt: start + 900, offsetSeconds: 598.5)
        let rows: [(name: String, pauses: [RecordingPause], expected: [[String: String]])] = [
            ("paused", [pause], [["startedAt": "2026-04-24T03:16:40Z", "endedAt": "2026-04-24T03:21:40Z", "offsetSeconds": "598.5"]]),
            ("never paused", [], []),
        ]
        for (name, pauses, expected) in rows {
            let sidecar = RecordingSidecar(
                title: "Standup", appName: "Zoom", startedAt: start, stoppedAt: start + 1800,
                participants: [], micDelaySeconds: 0, trigger: .manual,
                mixFilename: "mix.wav", appFilename: nil, micFilename: nil, pauses: pauses,
            )
            let written = try encodeAsDict(sidecar)["pauses"]
            XCTAssertEqual(written != nil, !expected.isEmpty, "\(name): a pauses key only when paused")
            XCTAssertEqual((written as? [[String: Any]] ?? []).map { $0.mapValues { "\($0)" } }, expected, name)
        }
    }

    func test_write_createsFileNextToBasename() throws {
        let dir = try makeTempDirectory(prefix: "rs")

        let basename = "20260503_083000"
        let sidecar = makeFullSidecar()
        let url = try sidecar.write(toDirectory: dir, basename: basename)

        XCTAssertEqual(url.lastPathComponent, "\(basename)_meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_read_roundTripsTitleAndParticipants() throws {
        let dir = try makeTempDirectory(prefix: "rs")
        let basename = "20260503_083000"
        try makeFullSidecar().write(toDirectory: dir, basename: basename)

        let decoded = try XCTUnwrap(
            RecordingSidecar.read(fromDirectory: dir, basename: basename),
        )

        XCTAssertEqual(decoded.title, "Standup")
        XCTAssertEqual(decoded.appName, "Microsoft Teams")
        XCTAssertEqual(decoded.participants, ["Alice", "Bob"])
        XCTAssertEqual(decoded.micDelaySeconds, 0.12, accuracy: 0.0001)
        XCTAssertEqual(decoded.files.mix, "20260503_083000_mix.wav")
        XCTAssertEqual(decoded.trigger, .manual)
    }

    func test_read_returnsNilWhenMissing() throws {
        let dir = try makeTempDirectory(prefix: "rs")
        XCTAssertNil(RecordingSidecar.read(fromDirectory: dir, basename: "absent"))
    }

    /// Sidecars written before the trigger field existed must keep decoding.
    /// `read()` swallows decode errors, so a non-optional field here would
    /// silently degrade every reimport of an older recording to stem-derived
    /// defaults (title, participants and meeting-start all lost).
    func test_read_v1SidecarWithoutTrigger_decodesWithNilTrigger() throws {
        let decoded = try XCTUnwrap(readRawSidecar(
            """
            {
              "version": 1,
              "title": "Legacy Standup",
              "appName": "Zoom",
              "startedAt": "2026-05-03T08:30:00Z",
              "stoppedAt": "2026-05-03T09:00:00Z",
              "participants": ["Speaker A"],
              "micDelaySeconds": 0.5,
              "files": { "mix": "legacy_mix.wav" }
            }
            """,
        ))

        XCTAssertNil(decoded.trigger)
        XCTAssertEqual(decoded.title, "Legacy Standup")
        XCTAssertEqual(decoded.participants, ["Speaker A"])
    }

    /// A version 2 sidecar predates `pauses` and reads as a recording without
    /// any, every other field intact.
    func test_read_v2SidecarWithoutPauses_decodesEveryOtherField() throws {
        let decoded = try XCTUnwrap(readRawSidecar(
            """
            {
              "version": 2,
              "title": "Weekly Sync",
              "appName": "Microsoft Teams",
              "startedAt": "2026-05-03T08:30:00Z",
              "stoppedAt": "2026-05-03T09:00:00Z",
              "participants": ["Alice", "Bob"],
              "micDelaySeconds": 0.25,
              "trigger": "auto",
              "files": { "mix": "v2_mix.wav", "app": "v2_app.wav", "mic": "v2_mic.wav" }
            }
            """,
        ))

        XCTAssertNil(decoded.pauses)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.title, "Weekly Sync")
        XCTAssertEqual(decoded.appName, "Microsoft Teams")
        XCTAssertEqual(decoded.startedAt, Date(timeIntervalSince1970: 1_777_797_000))
        XCTAssertEqual(decoded.stoppedAt, Date(timeIntervalSince1970: 1_777_798_800))
        XCTAssertEqual(decoded.participants, ["Alice", "Bob"])
        XCTAssertEqual(decoded.micDelaySeconds, 0.25)
        XCTAssertEqual(decoded.trigger, .auto)
        XCTAssertEqual([decoded.files.mix, decoded.files.app, decoded.files.mic], ["v2_mix.wav", "v2_app.wav", "v2_mic.wav"])
    }

    /// A trigger value from a future schema version must map to nil rather than
    /// throw. A throw would poison the whole read, so an old build would lose
    /// every other field too instead of just the one it cannot interpret.
    func test_read_unknownTriggerValue_keepsRemainingFields() throws {
        let decoded = try XCTUnwrap(readRawSidecar(
            """
            {
              "version": 4,
              "title": "Future Standup",
              "appName": "Zoom",
              "startedAt": "2026-05-03T08:30:00Z",
              "stoppedAt": "2026-05-03T09:00:00Z",
              "participants": ["Speaker A"],
              "micDelaySeconds": 0.5,
              "trigger": "scheduled",
              "files": { "mix": "future_mix.wav" }
            }
            """,
        ))

        XCTAssertNil(decoded.trigger, "an unknown trigger value must decode as nil, not throw")
        XCTAssertEqual(decoded.title, "Future Standup")
        XCTAssertEqual(decoded.files.mix, "future_mix.wav")
    }

    /// The sidecar records meeting title + participants; it must be owner-only
    /// (0600), not world-readable, matching the audio it sits next to.
    func test_write_setsOwnerOnlyPermissions() throws {
        let dir = try makeTempDirectory(prefix: "rs")
        let url = try makeFullSidecar().write(toDirectory: dir, basename: "20260503_083000")

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int,
        )
        XCTAssertEqual(mode & 0o777, 0o600)
    }
}
