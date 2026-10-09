import Foundation

/// One job as the Transcriptions window and the menu list it, whether it is
/// still in the pipeline's queue or known only from the finished-job history.
struct TranscriptionEntry: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// Nil for a record written before the history kept it.
    let appName: String?
    /// When the meeting started, or when the job was added for an import or a
    /// recovered recording, which have no meeting start. Nil for a record
    /// written before the history kept either.
    let date: Date?
    /// When the job was added, which orders the list. A retry keeps it.
    let enqueuedAt: Date?
    /// The recording's length in seconds; nil until stage 1 measured it.
    let audioDuration: TimeInterval?
    let participants: [String]
    let state: JobState
    let error: String?
    let warnings: [String]
    let protocolURL: URL?
    let transcriptURL: URL?
    /// Whether the job is in the pipeline's queue. Only a live job can be
    /// retried; one known only from the history waits for the pipeline to load
    /// it from the snapshot.
    let isLive: Bool
    /// Where the job stands among the finished ones in the order they
    /// finished, higher meaning later, and nil while it is unfinished. Only
    /// comparable between entries of one `TranscriptionList.entries` call.
    let finishOrder: Int?

    /// What Open opens and Show in Finder reveals: the protocol, else the
    /// transcript.
    var fileToOpen: URL? {
        protocolURL ?? transcriptURL
    }

    init(job: PipelineJob, finishOrder: Int?) {
        id = job.id
        title = job.meetingTitle
        appName = job.appName
        date = job.meetingStartTime ?? job.enqueuedAt
        enqueuedAt = job.enqueuedAt
        audioDuration = job.audioDuration
        participants = job.participants
        state = job.state
        error = job.error
        warnings = job.warnings
        protocolURL = job.protocolPath
        transcriptURL = job.transcriptPath
        isLive = true
        self.finishOrder = job.state.isTerminal ? finishOrder : nil
    }

    /// Nil for a record whose job id is not a UUID, which nothing could act on.
    init?(record: TerminalJobRecord, finishOrder: Int?) {
        let status = record.status
        guard let id = UUID(uuidString: status.jobID) else { return nil }
        self.id = id
        title = status.meetingTitle
        appName = record.appName
        date = record.meetingStartTime ?? record.enqueuedAt
        enqueuedAt = record.enqueuedAt
        audioDuration = record.audioDuration
        participants = record.participants
        state = status.state
        error = status.error
        warnings = status.warnings
        protocolURL = status.protocolPath.map { URL(fileURLWithPath: $0) }
        transcriptURL = status.transcriptPath.map { URL(fileURLWithPath: $0) }
        isLive = false
        self.finishOrder = status.state.isTerminal ? finishOrder : nil
    }
}

/// The one list both the Transcriptions window and the menu read, so the two
/// cannot disagree about which jobs exist or what state they are in. Pure: it
/// reads the jobs and records it is handed and nothing else.
enum TranscriptionList {
    /// Every job the app knows, once each: the queue's jobs and the history's
    /// records, a job in both listed from the live job. Newest first by when
    /// the job was added; records written before the history kept that time
    /// come after all others, the newest stored first.
    ///
    /// Each finished entry carries its finish order. The history appends a
    /// job's record, or moves it to the end, at every terminal transition
    /// (`TerminalJobStore.upserting`), so a record's index is the order the
    /// jobs finished in, while the enqueue time is not: a retry keeps it. The
    /// index is taken before a live job replaces its record, so a finished
    /// live job ranks by its record too. A finished live job with no record
    /// ranks below every record, among such jobs by when they were added. In
    /// the app that is a failed job whose record the history's cap evicted:
    /// the queue keeps failed jobs until they are removed, and such a job
    /// finished before anything still recorded.
    static func entries(liveJobs: [PipelineJob], records: [TerminalJobRecord]) -> [TranscriptionEntry] {
        let finishOrder = finishOrders(liveJobs: liveJobs, records: records)
        var seen: Set<UUID> = []
        var listed: [TranscriptionEntry] = []
        for job in liveJobs {
            guard seen.insert(job.id).inserted else { continue }
            listed.append(TranscriptionEntry(job: job, finishOrder: finishOrder[job.id]))
        }
        for (index, record) in records.enumerated().reversed() {
            guard let entry = TranscriptionEntry(record: record, finishOrder: index),
                  seen.insert(entry.id).inserted
            else { continue }
            listed.append(entry)
        }
        return listed.enumerated().sorted { lhs, rhs in
            switch (lhs.element.enqueuedAt, rhs.element.enqueuedAt) {
            case let (left?, right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// The finish order of every job that has one: its record's index, or
    /// below zero for a finished live job without a record.
    private static func finishOrders(liveJobs: [PipelineJob], records: [TerminalJobRecord]) -> [UUID: Int] {
        var order: [UUID: Int] = [:]
        for (index, record) in records.enumerated() {
            if let id = UUID(uuidString: record.status.jobID) { order[id] = index }
        }
        let unrecorded = liveJobs.enumerated()
            .filter { $0.element.state.isTerminal && order[$0.element.id] == nil }
            .sorted { ($0.element.enqueuedAt, $0.offset) < ($1.element.enqueuedAt, $1.offset) }
        for (rank, item) in unrecorded.enumerated() {
            order[item.element.id] = rank - unrecorded.count
        }
        return order
    }

    /// The entries whose title or any participant contains `query`, ignoring
    /// case and diacritics, in the order given. A query of only whitespace
    /// matches everything.
    static func matching(_ entries: [TranscriptionEntry], query: String) -> [TranscriptionEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            entry.title.localizedStandardContains(needle)
                || entry.participants.contains { $0.localizedStandardContains(needle) }
        }
    }

    /// The menu's share: every unfinished entry, plus the `finishedLimit`
    /// finished ones that finished last, in the order the jobs were added
    /// (oldest first), so the menu reads top to bottom as it always has.
    /// Entries without an enqueue time predate every other and come first,
    /// in the order they were stored.
    static func menuEntries(_ entries: [TranscriptionEntry], finishedLimit: Int = 3) -> [TranscriptionEntry] {
        let lastFinished = Set(
            entries.filter(\.state.isTerminal)
                .sorted { ($0.finishOrder ?? .min) > ($1.finishOrder ?? .min) }
                .prefix(finishedLimit)
                .map(\.id),
        )
        return entries.filter { !$0.state.isTerminal || lastFinished.contains($0.id) }
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.enqueuedAt ?? .distantPast
                let right = rhs.element.enqueuedAt ?? .distantPast
                if left != right { return left < right }
                return (lhs.element.finishOrder ?? .min, lhs.offset) < (rhs.element.finishOrder ?? .min, rhs.offset)
            }
            .map(\.element)
    }
}
