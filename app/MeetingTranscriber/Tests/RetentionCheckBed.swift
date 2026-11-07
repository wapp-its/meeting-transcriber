@testable import MeetingTranscriber
import XCTest

/// A `RecordingRetentionController` over a temp folder, with its clock, its calendar
/// and its view of the queue in the test's hands, and meetings to act on: their
/// files on disk and their record, as a finished run leaves them.
@MainActor
final class RetentionCheckBed {
    let harness: MeetingDeletionHarness
    /// Well past every due date of a meeting recorded on `RetentionFixture.recorded`,
    /// except After 90 days.
    var clock = RetentionFixture.date(2026, 12, 1)
    /// How many checks have begun: a check reads the clock once.
    private(set) var clockReads = 0
    var calendar = RetentionFixture.calendar
    var live: [UUID: LiveMeetingState] = [:]
    var listed: Set<UUID> = []
    /// What each permanent delete was asked to remove, by file name.
    private(set) var removed: [String] = []
    /// What the permanent delete answers for a file; nil deletes it.
    var refusal: (URL) -> (any Error)? = { _ in nil }
    /// Runs before each permanent delete, to look at the state at that moment.
    var beforeRemoval: (URL) -> Void = { _ in }
    /// Runs on each look at the queue, with how many there were for that meeting.
    var onLiveLookup: (UUID, Int) -> Void = { _, _ in }
    /// Runs on each look at the rows, with how many there were for that meeting.
    var onRowLookup: (UUID, Int) -> Void = { _, _ in }
    private var liveLookups: [UUID: Int] = [:]
    private var rowLookups: [UUID: Int] = [:]

    var store: MeetingFileStore {
        harness.store
    }

    var settings: AppSettings {
        harness.settings
    }

    init(harness: MeetingDeletionHarness) {
        self.harness = harness
        harness.settings.recordingRetention = .days30
    }

    /// `store` and `settings` stand for another build sharing the record file, which
    /// has its own setting and identifier; by default this bed's.
    func controller(
        interval: Duration = .seconds(3600), store: MeetingFileStore? = nil, settings: AppSettings? = nil,
    ) -> RecordingRetentionController {
        let readClock = { [self] in
            clockReads += 1
            return clock
        }
        return RecordingRetentionController(
            settings: settings ?? self.settings, store: store ?? self.store,
            remover: MeetingFileRemover(
                trash: { url in
                    XCTFail("the automatic check moved \(url.lastPathComponent) to the Trash")
                },
                removeForGood: { [self] url in
                    removed.append(url.lastPathComponent)
                    beforeRemoval(url)
                    if let error = refusal(url) { throw error }
                    try MeetingFileRemover().removeForGood(url)
                },
            ),
            liveState: { [self] id in
                let count = liveLookups[id, default: 0] + 1
                liveLookups[id] = count
                onLiveLookup(id, count)
                return live[id]
            },
            isListed: { [self] id in
                let count = rowLookups[id, default: 0] + 1
                rowLookups[id] = count
                onRowLookup(id, count)
                return listed.contains(id)
            },
            securityScope: harness.scopes.access,
            interval: interval,
            calendar: calendar,
            now: readClock,
        )
    }

    /// One check, as a launch would run it.
    func check() async {
        await controller().checkNow()
    }

    // MARK: - Meetings

    private func write(_ name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    /// A file of a meeting, written to `folder`, as the record lists it.
    func file(_ role: MeetingFile.Role, _ name: String, owned: Bool = true, in folder: URL? = nil) throws -> MeetingFile {
        try MeetingFile(role: role, url: write(name, in: folder ?? harness.recordings), owned: owned)
    }

    /// A finished meeting: three tracks and their 16 kHz copies, segments, a naming
    /// file, a transcript, a protocol and the protocol before it. A recording owns
    /// its tracks. `audioFolder` puts the audio apart from everything else. Created
    /// by the build `writer` stands for, as `PipelineQueue` creates a record.
    @discardableResult
    func meeting(
        origin: MeetingFileRecord.Origin = .recorded,
        recorded: Date? = RetentionFixture.recorded,
        outcome: MeetingFileRecord.Outcome = .finished(protocolExpected: true),
        audioFolder: URL? = nil,
        writtenBy writer: MeetingFileStore? = nil,
        _ change: (inout MeetingFileRecord) throws -> Void = { _ in },
    ) throws -> MeetingFileRecord {
        let stem = String(UUID().uuidString.prefix(8))
        let audio: [(MeetingFile.Role, String)] = [
            (.mix, "mix.wav"), (.appTrack, "app.wav"), (.micTrack, "mic.wav"),
            (.mix16k, "16k.wav"), (.app16k, "app_16k.wav"), (.mic16k, "mic_16k.wav"),
        ]
        let other: [(MeetingFile.Role, String)] = [
            (.segments, "segments.json"), (.naming, "naming.json"), (.transcript, "txt"), (.protocol, "md"),
            (.previousProtocol, "previous.md"),
        ]
        var record = try MeetingFileRecord(
            jobID: UUID(), origin: origin, recordingDate: recorded,
            files: audio.map { role, name in
                try file(role, "\(stem)_\(name)", owned: origin.owns(role), in: audioFolder)
            } + other.map { role, name in try file(role, "\(stem)_\(name)") },
            outcome: outcome, createdBy: (writer ?? store).bundleID,
        )
        try change(&record)
        XCTAssertTrue((writer ?? store).create(record), "test premise")
        return record
    }

    /// Take `path` off the disk and leave the record as it is: what deleting a file
    /// in the Finder does.
    func removeBehindTheApp(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Looking at the result

    /// Calls `look` at each change of the store's records. The store saves first and
    /// tells afterwards, so the record file already holds that change.
    func onEveryRecordWrite(_ look: @escaping @MainActor () -> Void) {
        withObservationTracking {
            _ = store.records
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                look()
                self?.onEveryRecordWrite(look)
            }
        }
    }

    /// What a crash at this moment would leave for the launch to settle.
    var recordFileHoldsADeletionMark: Bool {
        ((try? String(contentsOf: harness.recordPath, encoding: .utf8)) ?? "").contains("\"pending\"")
    }

    func current(_ record: MeetingFileRecord) throws -> MeetingFileRecord {
        store.reload()
        return try XCTUnwrap(store.record(for: record.jobID))
    }

    func isOnDisk(_ path: String) -> Bool {
        harness.isOnDisk(path)
    }

    func audioPaths(_ record: MeetingFileRecord) -> [String] {
        record.files.filter(\.role.isAudio).map(\.path)
    }

    func otherPaths(_ record: MeetingFileRecord) -> [String] {
        record.files.filter { !$0.role.isAudio }.map(\.path)
    }

    /// The audio went for good, everything else stayed, and the record says so.
    func assertAudioWent(
        _ record: MeetingFileRecord, at time: Date? = nil, _ name: String = "",
        file: StaticString = #filePath, line: UInt = #line,
    ) throws {
        let now = try current(record)
        for path in audioPaths(record) {
            XCTAssertFalse(isOnDisk(path), "\(name): audio stayed", file: file, line: line)
        }
        for path in otherPaths(record) where record.files.first(where: { $0.path == path })?.state == .present {
            XCTAssertTrue(isOnDisk(path), "\(name): a file that is not audio went", file: file, line: line)
        }
        XCTAssertEqual(
            now.files.filter(\.role.isAudio).map(\.state), audioPaths(record).map { _ in .gone },
            "\(name): audio not marked gone", file: file, line: line,
        )
        XCTAssertEqual(
            now.audioDeletion, .init(kind: .automatic, at: time ?? clock), "\(name): date", file: file, line: line,
        )
        XCTAssertNil(now.pending, "\(name): pending", file: file, line: line)
        XCTAssertNil(now.incomplete, "\(name): incomplete is for manual deletions", file: file, line: line)
        XCTAssertEqual(harness.fakeTrash.moved, [], "\(name): trash", file: file, line: line)
    }

    /// Nothing was touched: the record is as it was and no file of it went.
    func assertUntouched(
        _ record: MeetingFileRecord, _ name: String = "", file: StaticString = #filePath, line: UInt = #line,
    ) throws {
        XCTAssertEqual(try current(record), record, "\(name): record changed", file: file, line: line)
        for entry in record.files where entry.state == .present {
            XCTAssertTrue(isOnDisk(entry.path), "\(name): \(entry.role) went", file: file, line: line)
        }
    }
}

@MainActor
extension XCTestCase {
    /// A bed on settings of its own and a temp folder, set to After 30 days.
    func makeRetentionCheckBed() throws -> RetentionCheckBed {
        let suite = "RetentionCheckBed-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let root = try makeTempDirectory(prefix: "retention_check")
        let settings = AppSettings(
            defaults: defaults, defaultOutputDir: root.appendingPathComponent("output", isDirectory: true),
        )
        return try RetentionCheckBed(harness: MeetingDeletionHarness(root: root, settings: settings))
    }
}
