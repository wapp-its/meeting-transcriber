---
satisfies: [R1, R3]
---
# gh-60-cut-a-recovered-recording-back-after-a.1 Stored meeting-end cut: record, durable write and removal, process hold

## Description
The stored cut itself: its record, its durable write, update, read and removal, and the process-wide hold set. Everything else in this spec (recovery in task 4, the recorder in task 2, the watch loop in task 3) builds on this type, so it comes first and is proven on its own with real files. See spec Architecture & Data Models (record shape, durability, this process's hold), R1, R3.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/PendingRecordingCut.swift` (new), `app/MeetingTranscriber/Sources/RecordingFileSuffix.swift`, `app/MeetingTranscriber/Tests/PendingRecordingCutTests.swift` (new)
**Touches:** [app/MeetingTranscriber/Sources/PendingRecordingCut.swift, app/MeetingTranscriber/Sources/RecordingFileSuffix.swift, app/MeetingTranscriber/Tests/PendingRecordingCutTests.swift]

### Approach
- `RecordingFileSuffix`: add the stored-cut suffix (e.g. `_pending_cut.json`) beside `inProgress`, with a doc comment saying it is neither a crash signal (crash detection stays on the marker and the raw temp, `RecordingFileSuffix.swift:9-22`) nor a track.
- `PendingRecordingCut`: `Codable` value type with exactly the spec's seven fields (`captureEndedAt`, `keptSeconds` optional), `nonisolated` static helpers in the style of `DualSourceRecorder.inProgressMarker(stem:in:)` (`DualSourceRecorder.swift:276`): `url(stem:in:)`, `write(_:in:)`, `read(stem:in:)` → absent / valid(record) / invalid(reason: unreadable, empty, unknownVersion, otherRecording, timesOutOfOrder), `recordResolution(stem:in:keptSeconds:captureEndedAt:)` (read-modify-write that sets each field only when it is absent; a present value is never changed), and `remove(stem:in:)`.
- Durable sequence (spec, "Every change to it is durable"): write = encode → hidden temp sibling in the same folder, owner-only before it holds data (`FileManager.restrictToOwner`, `FileManager+OwnerOnly.swift:22`) → full sync of the temp's descriptor → POSIX rename over the target (`RecordingCut.rename`, `RecordingCut.swift:161`) → sync the folder's descriptor. Removal = unlink → sync the folder; if the unlink fails, truncate the file to zero bytes and fully sync it, and report both. A write reports one of three outcomes (spec, "Every change to it is durable"): written; notPublished(error) for any failure before the rename (the target is untouched and the temp removed); publishedNotSynced(error) when only the folder sync after the rename failed (the target holds the new record). `recordResolution` reports the same three. A removal reports removed / removedNotSynced(error) / emptied(unlink error) / failed(both errors), so tasks 2 and 3 can log `published=` and `emptied=`.
- The sync is one injectable function `(Int32) throws -> Void` with a production default of `fcntl(fd, F_FULLFSYNC)`, falling back to `fsync` when the file system does not support `F_FULLFSYNC` (the SQLite approach). Tests inject a recorder of calls and a failing variant.
- Hold set: `hold(_:)`, `release(_:)`, `isHeld(_:)` over a lock-protected `Set<String>` (recovery reads it off the main actor, so not actor-isolated), plus a test-only reset.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/RecordingFileSuffix.swift` — suffix constants and the crash-signal rule
- `app/MeetingTranscriber/Sources/RecordingCut.swift:159-165` — POSIX rename helper
- `app/MeetingTranscriber/Sources/ProcessedRecordingsLedger.swift:44-60` — small owner-only JSON file pattern
- `app/MeetingTranscriber/Sources/FileManager+OwnerOnly.swift` — owner-only helper

**Optional** (reference as needed):
- `app/MeetingTranscriber/Sources/LivenessMarker.swift` — injectable URL for tests, atomic write

### Key context
- `Data.write(options: .atomic)` renames but does not sync the file or the folder; the spec requires both, which is why this type owns its sequence.
- Dates: encode them so a round trip is exact to the millisecond or better (`keptSeconds` and the deadline check compare them).
## Acceptance
- [ ] A record round-trips through write and read with every field (optional ones present and absent); the file is owner-only (0600); a second write replaces the first whole.
- [ ] Read reports absent for no file, and invalid with the right reason for an empty file, undecodable bytes, an unknown version, a stem that differs from the file name, `cutAt` outside `startedAt…deadline`, and a non-positive `keptSeconds`.
- [ ] `recordResolution` sets `keptSeconds` and `captureEndedAt` when absent and never changes a value already present.
- [ ] Ordering is pinned with an injected sync: when the first sync fires the target still holds the old record (or nothing), when the folder sync fires it holds the new one.
- [ ] A sync failing on the temp file reports notPublished, leaves the target as it was and no temp behind; a sync failing only on the folder reports publishedNotSynced and the target reads back as the new record.
- [ ] Removal unlinks and syncs the folder (a failing folder sync reports removedNotSynced); with the folder made read-only (so the unlink fails) it empties the file instead, reports `emptied`, and the emptied file reads as invalid.
- [ ] Hold, release and isHeld behave as a set and are safe to call from several threads (concurrent test).
- [ ] Focused tests pass (spec Quick commands); lint clean.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
