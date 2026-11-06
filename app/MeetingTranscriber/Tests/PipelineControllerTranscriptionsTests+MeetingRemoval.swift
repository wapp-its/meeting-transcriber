@testable import MeetingTranscriber
import XCTest

// MARK: - The end of a deletion, when a write fails

/// A deletion ends in writes of its own after the files have gone. The pending
/// mark is what a launch repairs from, so it stays until the rest is on disk: a
/// failed write or a crash in between must not bring a meeting back with no way to
/// finish it, and nothing here may remove a file the mover did not check.
extension PipelineControllerTranscriptionsTests {
    // MARK: - No file goes by name

    /// The record knows these files went, so the mover has nothing to check, and
    /// what has since taken their path is not the meeting's. The queue's own
    /// cleanup removes by name, folders with their content included.
    func testMoveMeetingLeavesWhatNowSitsAtASidecarPathTheRecordSawGo() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        var job = try harness.recordedMeeting()
        job.namingSlug = "budget"
        job.recordSidecarOutputDir(harness.outputDir)
        controller.queue.insertJobForTesting(job)
        let roles: [(MeetingFile.Role, String)] = [
            (.segments, SpeakerNamingStore.segmentsSuffix),
            (.naming, SpeakerNamingStore.namingJSONSuffix),
            (.mix16k, SpeakerNamingStore.mixSuffix),
        ]
        var inside: [URL] = []
        for (role, suffix) in roles {
            let folder = harness.recordings.appendingPathComponent("budget\(suffix)", isDirectory: true)
            harness.store.update(jobID: job.id) { record in
                var entry = MeetingFile(role: role, url: folder, owned: true)
                entry.state = .gone
                record.files.append(entry)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let kept = folder.appendingPathComponent("kept.txt")
            try Data("kept".utf8).write(to: kept)
            inside.append(kept)
        }

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertFalse(controller.queue.jobs.contains { $0.id == job.id }, "test premise: the queue job went")
        for file in inside {
            XCTAssertTrue(harness.isOnDisk(file.path), "\(file.deletingLastPathComponent().lastPathComponent) was removed by name")
        }
    }

    /// The files are the mover's, the memory is still the queue's: naming data kept
    /// for a job that is gone would never be dropped.
    func testMoveMeetingForgetsTheNamingDataOfItsJob() throws {
        let harness = try makeDeletionHarness()
        let controller = harness.controller(queue: harness.makeQueue())
        let job = try harness.recordedMeeting()
        controller.queue.insertJobForTesting(job)
        controller.queue.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
            jobID: job.id, meetingTitle: job.meetingTitle, mapping: ["SPEAKER_0": "SPEAKER_0"],
            speakingTimes: ["SPEAKER_0": 5], embeddings: [:], audioPath: nil, segments: [],
            participants: [], isDualSource: false,
        )

        XCTAssertTrue(controller.moveMeetingToTrash(jobID: job.id))

        XCTAssertNil(controller.queue.speakerNamingDataByJob[job.id])
    }
}
