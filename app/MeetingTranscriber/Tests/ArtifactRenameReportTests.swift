@testable import MeetingTranscriber
import XCTest

/// A meeting's additional reports follow the rename to its AI title (spec R6, A8):
/// planned from the protocols folder's names, moved in the same all-or-nothing run,
/// and a name a report holds is not free. The plan is pure; the run uses a temp
/// folder.
@MainActor
final class ArtifactRenameReportTests: XCTestCase {
    private let dirs = ArtifactRenamePlan.Directories(
        protocols: URL(fileURLWithPath: "/out/protocols"),
        recordings: URL(fileURLWithPath: "/out/recordings"),
    )

    // MARK: - The plan

    func testTheMovesTakeTheReportsAfterTheArtifacts() {
        let moves = ArtifactRenamePlan.moves(
            from: "old", to: "weekly_sync", in: dirs, reports: ["Short", "Alpha (Beta)"],
        ) { $0.path == "/out/protocols/old.md" }

        XCTAssertEqual(moves.map(\.from.lastPathComponent), ["old.md", "old (Short).md", "old (Alpha (Beta)).md"])
        XCTAssertEqual(moves.map(\.to.lastPathComponent), ["weekly_sync.md", "weekly_sync (Short).md", "weekly_sync (Alpha (Beta)).md"])
    }

    func testAStemWithAReportIsTaken() {
        let stem = ArtifactRenamePlan.availableStem(
            titleSlug: "weekly_sync", shortID: "ab12cd34", currentStem: "old", in: dirs,
            protocolNames: ["weekly_sync (Short).md"],
        ) { _ in false }

        XCTAssertEqual(stem, "weekly_sync_ab12cd34")
    }

    func testAStemWhereAnotherMeetingWouldOwnAMovedReportIsTaken() {
        for other in ["weekly_sync (Short).txt", "weekly_sync (short).txt", "Weekly_sync (Short).md"] {
            let stem = ArtifactRenamePlan.availableStem(
                titleSlug: "weekly_sync", shortID: "ab12cd34", currentStem: "old", in: dirs,
                protocolNames: ["old (Short).md", other], reports: ["Short"],
            ) { _ in false }

            XCTAssertEqual(stem, "weekly_sync_ab12cd34", other)
        }
    }

    func testAnotherMeetingsReportDoesNotTakeAShorterStem() {
        XCTAssertEqual(ArtifactRenamePlan.reports(of: "weekly_sync", in: ["weekly_sync_retro (Short).md"]), [])
        XCTAssertEqual(
            ArtifactRenamePlan.reports(of: "weekly_sync", in: ["weekly_sync (Q3).txt", "weekly_sync (Q3) (Short).md"]), [],
            "a longer meeting with its transcript claims the file",
        )
        XCTAssertEqual(ArtifactRenamePlan.reports(of: "weekly_sync", in: ["weekly_sync (Short).md"]), ["Short"])
    }

    // MARK: - The run

    private func makeFolder() throws -> (queue: PipelineQueue, protocols: URL, job: PipelineJob, store: MeetingFileStore) {
        let root = try makeTempDirectory(prefix: "rename_reports")
        let protocols = root.appendingPathComponent("output/protocols", isDirectory: true)
        try FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("output/recordings"), withIntermediateDirectories: true)
        let store = MeetingFileStore(path: root.appendingPathComponent("logs/meeting_files.json"))
        let queue = PipelineQueue(logDir: root.appendingPathComponent("logs"), stagingDir: root, meetingFileStore: store)
        var job = PipelineJob(meetingTitle: "Standup", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.state = .done
        for name in ["old.txt", "old.md", "old (Short).md", "old (Minutes).md", "old_retro (Short).md"] {
            try Data(name.utf8).write(to: protocols.appendingPathComponent(name))
        }
        job.transcriptPath = protocols.appendingPathComponent("old.txt")
        job.protocolPath = protocols.appendingPathComponent("old.md")
        queue.insertJobForTesting(job)
        var record = MeetingFileRecord(job: job, origin: .recorded, createdBy: store.bundleID)
        record.list(MeetingFile(role: .transcript, url: protocols.appendingPathComponent("old.txt"), owned: true))
        XCTAssertTrue(store.create(record))
        return (queue, protocols, job, store)
    }

    private func names(in folder: URL) throws -> Set<String> {
        try Set(FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    func testARenameMovesTheReportsAndTheyStayListed() throws {
        let (queue, protocols, job, _) = try makeFolder()

        let renamed = queue.renameJobArtifacts(jobID: job.id, from: "old", titleSlug: "weekly_sync", protocolsDir: protocols)

        XCTAssertEqual(renamed, "weekly_sync")
        XCTAssertEqual(try names(in: protocols), [
            "weekly_sync.txt", "weekly_sync.md", "weekly_sync (Short).md", "weekly_sync (Minutes).md", "old_retro (Short).md",
        ])
        let folder = try XCTUnwrap(MeetingReportFolder.read(
            folder: protocols, basename: renamed, list: { try? FileManager.default.contentsOfDirectory(atPath: $0.path) },
            read: { try? Data(contentsOf: $0) },
        ))
        XCTAssertEqual(folder.reports.map(\.name), ["Minutes", "Short"])
    }

    func testAFailedMoveUndoesTheReportsToo() throws {
        let (queue, protocols, job, _) = try makeFolder()
        let before = try names(in: protocols)

        let renamed = queue.renameJobArtifacts(jobID: job.id, from: "old", titleSlug: "weekly_sync", protocolsDir: protocols) { source, destination in
            if destination.lastPathComponent == "weekly_sync (Short).md" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: source, to: destination)
        }

        XCTAssertEqual(renamed, "old")
        XCTAssertEqual(try names(in: protocols), before)
    }

    /// A report that moved and could not move back is listed where it is, so Move
    /// Meeting to Trash still finds it.
    func testAReportStrandedByAFailedUndoIsListed() throws {
        let (queue, protocols, job, store) = try makeFolder()

        queue.renameJobArtifacts(jobID: job.id, from: "old", titleSlug: "weekly_sync", protocolsDir: protocols) { source, destination in
            if destination.lastPathComponent == "weekly_sync (Short).md" || destination.lastPathComponent == "old (Minutes).md" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }

        let stranded = protocols.appendingPathComponent("weekly_sync (Minutes).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranded.path), "test premise")
        let listed = try XCTUnwrap(store.record(for: job.id)?.files.first { $0.path == MeetingFile.resolvedPath(stranded) })
        XCTAssertEqual(listed.role, .previousProtocol)
        XCTAssertTrue(listed.owned)
        let found = try XCTUnwrap(store.record(for: job.id).map { MeetingReportScan.scan($0) })
        XCTAssertFalse(found.paths.contains(listed.path), "no rule finds it by name")
        XCTAssertTrue(try XCTUnwrap(store.record(for: job.id)).filesCovered(by: .meetingToTrash).contains(listed))
    }

    /// `weekly_sync (Short).md` would be the notes of the meeting `weekly_sync (Short).txt`
    /// names, so the report would leave the renamed meeting: the title is taken.
    func testATitleWhereAnotherMeetingWouldClaimAMovedReportIsTaken() throws {
        let (queue, protocols, job, _) = try makeFolder()
        try Data("[Ben] Another meeting".utf8).write(to: protocols.appendingPathComponent("weekly_sync (Short).txt"))

        let renamed = queue.renameJobArtifacts(jobID: job.id, from: "old", titleSlug: "weekly_sync", protocolsDir: protocols)

        XCTAssertEqual(renamed, "weekly_sync_\(PipelineJob.shortID(for: job.id))")
        let folder = try XCTUnwrap(MeetingReportFolder.read(
            folder: protocols, basename: renamed, list: { try? FileManager.default.contentsOfDirectory(atPath: $0.path) },
            read: { try? Data(contentsOf: $0) },
        ))
        XCTAssertEqual(folder.reports.map(\.name), ["Minutes", "Short"])
    }

    func testAFolderThatCannotBeReadRenamesNothing() throws {
        let (queue, protocols, job, _) = try makeFolder()
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: protocols.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protocols.path) }

        let renamed = queue.renameJobArtifacts(jobID: job.id, from: "old", titleSlug: "weekly_sync", protocolsDir: protocols)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: protocols.path)
        XCTAssertEqual(renamed, "old")
        XCTAssertTrue(try names(in: protocols).contains("old (Short).md"))
        XCTAssertEqual(
            queue.jobs.first?.warnings.contains("Could not rename the output files to the AI meeting title; the original names were kept"), true,
        )
    }
}
