@testable import MeetingTranscriber
import XCTest

/// What the fork adds on top of the original's recording retention: a meeting the
/// user holds in All Recordings keeps its audio, each build deletes only from its
/// own registry by its own setting, a pass that deleted shows on the meeting's
/// row, and the fork's earlier setting is not read.
@MainActor
final class RecordingRetentionForkGateTests: XCTestCase {
    private func makeHarness() throws -> MeetingDeletionHarness {
        let suite = "RecordingRetentionForkGateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let root = try makeTempDirectory(prefix: "retention_fork_gate")
        let settings = AppSettings(defaults: defaults, defaultOutputDir: root.appendingPathComponent("output", isDirectory: true))
        settings.recordingRetentionEnabled = true
        settings.recordingRetentionDays = 0
        return try MeetingDeletionHarness(root: root, settings: settings)
    }

    /// A controller wired as `activate` wires it, without its timers.
    private func makePipeline(_ harness: MeetingDeletionHarness) -> PipelineController {
        let pipeline = harness.controller()
        pipeline.connectRetentionToMeetingRecords()
        return pipeline
    }

    /// A finished recording this build relocated, listed in its registry as due.
    private func dueMeeting(_ harness: MeetingDeletionHarness, _ pipeline: PipelineController) throws -> PipelineJob {
        let job = try harness.recordedMeeting()
        let registry = pipeline.recordingRetention.registry
        registry.register(
            jobID: job.id, paths: tracks(of: job), root: harness.outputDir,
            recordedAt: MeetingDeletionHarness.now.addingTimeInterval(-86400),
        )
        try registry.markEligible(jobID: job.id, output: XCTUnwrap(job.protocolPath), at: MeetingDeletionHarness.now)
        return job
    }

    private func tracks(of job: PipelineJob) -> [URL] {
        [job.mixPath, job.appPath, job.micPath].compactMap(\.self)
    }

    private func sweep(_ retention: RecordingRetention) async {
        await retention.sweep(.init(excludedPaths: { [] }, scopeRoot: nil, securityScope: .live))
    }

    private func onDisk(_ urls: [URL]) -> [Bool] {
        urls.map { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - What the user holds

    func testAMeetingMarkedKeepKeepsItsAudioUntilTheMarkIsTaken() async throws {
        let harness = try makeHarness()
        let pipeline = makePipeline(harness)
        let job = try dueMeeting(harness, pipeline)
        harness.store.update(jobID: job.id) { $0.keep = true }

        await sweep(pipeline.recordingRetention)
        XCTAssertEqual(onDisk(tracks(of: job)), [true, true, true], "kept")

        harness.store.update(jobID: job.id) { $0.keep = false }
        await sweep(pipeline.recordingRetention)

        XCTAssertEqual(onDisk(tracks(of: job)), [false, false, false])
        try XCTAssertEqual(onDisk([XCTUnwrap(job.transcriptPath), XCTUnwrap(job.protocolPath)]), [true, true])
        let record = try harness.record(of: job)
        XCTAssertEqual(record.files.filter(\.role.isSourceTrack).map(\.state), [.gone, .gone, .gone])
        XCTAssertEqual(record.audioDeletion, .init(kind: .automatic, at: MeetingDeletionHarness.now))
        XCTAssertEqual(harness.fakeTrash.moved, [], "for good, not to the Trash")
    }

    /// A deletion the user started in All Recordings, under way or stopped, a
    /// recovered recording from before the records, and a meeting another build or
    /// a build from before the field created, all keep their audio.
    func testEveryOtherHoldKeepsTheAudio() async throws {
        let holds: [(String, (inout MeetingFileRecord) -> Void)] = [
            ("pending", { $0.pending = .init(kind: .audioToTrash, paths: []) }),
            ("incomplete", { $0.incomplete = .init(reason: "r", paths: [], kind: .audioToTrash) }),
            ("from before the records", { $0.excludedFromAutomaticDeletion = true }),
            ("another build's", { $0.createdBy = RetentionFixture.otherBuild }),
            ("from before the field", { $0.createdBy = nil }),
        ]
        for (name, hold) in holds {
            let harness = try makeHarness()
            let pipeline = makePipeline(harness)
            let job = try dueMeeting(harness, pipeline)
            harness.store.update(jobID: job.id, hold)

            await sweep(pipeline.recordingRetention)

            XCTAssertEqual(onDisk(tracks(of: job)), [true, true, true], name)
        }
    }

    /// An import counts as the user's file even when its audio reached the
    /// registry, as one enqueued without an origin does.
    func testAnImportKeepsItsAudio() async throws {
        let harness = try makeHarness()
        let pipeline = makePipeline(harness)
        let job = try harness.importedMeeting()
        let registry = pipeline.recordingRetention.registry
        registry.register(
            jobID: job.id, paths: tracks(of: job), root: harness.outputDir,
            recordedAt: MeetingDeletionHarness.now.addingTimeInterval(-86400),
        )
        try registry.markEligible(jobID: job.id, output: XCTUnwrap(job.protocolPath), at: MeetingDeletionHarness.now)

        await sweep(pipeline.recordingRetention)

        XCTAssertEqual(onDisk(tracks(of: job)), [true])
    }

    /// Unread, a Keep cannot be told from no Keep, so the pass deletes nothing.
    func testARecordFileThatDoesNotReadSkipsThePass() async throws {
        let harness = try makeHarness()
        let pipeline = makePipeline(harness)
        let job = try dueMeeting(harness, pipeline)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: harness.recordPath.path)
        addTeardownBlock { [path = harness.recordPath.path] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }

        await sweep(pipeline.recordingRetention)

        XCTAssertEqual(onDisk(tracks(of: job)), [true, true, true])
        XCTAssertEqual(pipeline.recordingRetention.registry.entries.map(\.jobID), [job.id])
    }

    /// A Keep set while a pass deletes (the other build's window) stops the files
    /// still to go: the holds are read again right before each delete.
    func testAHoldSetDuringThePassStopsTheFilesStillToGo() async throws {
        let root = try makeTempDirectory(prefix: "retention_fork_midpass")
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("notes.md")
        try Data("# Notes".utf8).write(to: output)
        let paths = try ["a_mix.wav", "a_app.wav", "a_mic.wav"].map { name in
            let url = recordings.appendingPathComponent(name)
            try Data("RIFF".utf8).write(to: url)
            return url
        }
        let jobID = UUID()
        let held = HeldJobs()
        let deleter = RecordingFileDeleter { url in
            try FileManager.default.removeItem(at: url)
            held.add(jobID)
        }
        let retention = RecordingRetention(
            registry: RecordingRetentionRegistry(path: root.appendingPathComponent("logs/retained_recordings.json")),
            settings: { RecordingRetentionSettings(enabled: true, days: 0) },
            deleter: deleter,
        )
        retention.heldJobs = { held.jobs }
        retention.registry.register(jobID: jobID, paths: paths, root: root, recordedAt: Date(timeIntervalSince1970: 0))
        retention.registry.markEligible(jobID: jobID, output: output, at: Date(timeIntervalSince1970: 0))

        await sweep(retention)

        XCTAssertEqual(onDisk(paths), [false, true, true])
    }

    func testThePolicyKeepsAJobTheUserHolds() {
        let root = URL(fileURLWithPath: "/Volumes/Archive/Protocols")
        let entry = RetainedRecording(
            jobID: UUID(), paths: [root.appendingPathComponent("recordings/a_mix.wav")], root: root,
            recordedAt: Date(timeIntervalSince1970: 0), eligibleAt: Date(timeIntervalSince1970: 60),
            outputPath: root.appendingPathComponent("a.md"),
        )
        func decide(held: Set<UUID>) -> RecordingRetentionDecision {
            RecordingRetentionPolicy.decide(
                entry, now: Date(timeIntervalSince1970: 86400), settings: .init(enabled: true, days: 0),
                environment: .init(
                    excludedPaths: [], scopedRoot: nil, fileExists: { _ in true }, hasContent: { _ in true },
                    resolve: { $0 }, canList: { _ in true }, heldJobs: held,
                ),
            )
        }

        XCTAssertEqual(decide(held: []), .delete(entry.paths))
        XCTAssertEqual(decide(held: [entry.jobID]), .keep(.heldByUser))
        XCTAssertEqual(decide(held: [UUID()]), .delete(entry.paths))
    }

    // MARK: - One registry per build

    func testEachBuildDeletesOnlyFromItsOwnRegistry() async throws {
        let harness = try makeHarness()
        let pipeline = makePipeline(harness)
        let job = try dueMeeting(harness, pipeline)
        XCTAssertEqual(
            pipeline.recordingRetention.registry.path.lastPathComponent,
            "retained_recordings.\(RetentionFixture.thisBuild).json",
        )
        let otherBuild = PipelineController.makeRecordingRetention(
            logDir: harness.logDir, settings: harness.settings, bundleID: RetentionFixture.otherBuild,
        )

        await sweep(otherBuild)

        XCTAssertEqual(otherBuild.registry.entries, [])
        XCTAssertEqual(onDisk(tracks(of: job)), [true, true, true])
        XCTAssertNotEqual(
            RecordingRetentionRegistry.filename(bundleID: RetentionFixture.thisBuild),
            RecordingRetentionRegistry.filename(bundleID: RetentionFixture.otherBuild),
        )
        XCTAssertEqual(RecordingRetentionRegistry.filename(bundleID: nil), RecordingRetentionRegistry.filename)
    }

    // MARK: - The fork's earlier setting

    /// Its value is not carried over: whoever chose a period there switches the
    /// original's setting on by hand.
    func testTheForksEarlierSettingIsNotRead() throws {
        let suite = "RecordingRetentionForkGateTests-old-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        defaults.set("days7", forKey: "recordingRetention")

        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.recordingRetentionEnabled)
        XCTAssertEqual(settings.recordingRetentionDays, 30)
    }
}

/// Jobs a deleter running off the main actor adds to.
private final class HeldJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<UUID> = []

    func add(_ id: UUID) {
        lock.withLock { _ = stored.insert(id) }
    }

    var jobs: Set<UUID> {
        lock.withLock { stored }
    }
}
