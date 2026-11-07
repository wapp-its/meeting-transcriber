import Foundation
import Observation

/// The All Recordings window's rows' files and audio on disk, read once per row
/// and kept until the next refresh.
///
/// SwiftUI builds a `Menu`'s and a `.contextMenu`'s content with the row, not
/// when the menu opens, so a row menu that asked the disk itself would read the
/// row's files on every redraw of every visible row, out of a history of up to
/// a thousand. The window calls `refresh()` when its entries change, when it
/// appears or becomes key, and after a row action; in between, each row is
/// answered from what was read for it. The bound that follows: a file deleted
/// or restored in Finder is seen the next time the window is activated, not
/// sooner. Until then its menu item stays out or in, and an item whose file
/// went since the read fails with "The file was moved or deleted.".
///
/// A row's audio also follows its `MeetingFileRecord`: the automatic check deletes
/// audio with the window open, and `TranscriptionEntry` says nothing about audio,
/// so nothing above would notice. A record that differs from the one the audio
/// was read for is read again.
@Observable
@MainActor
final class RowAvailability {
    typealias FilesOnDisk = RecordingRowActions.FilesOnDisk
    typealias AudioOnDisk = RecordingAudioLine.AudioOnDisk

    /// Moved on by every refresh and read by every lookup, so a refresh
    /// redraws the rows that asked, while a lookup storing what it read into
    /// the ignored `found` redraws nothing.
    private var generation = 0
    @ObservationIgnored private var found: [UUID: FilesOnDisk] = [:]
    @ObservationIgnored private var audio: [UUID: (record: MeetingFileRecord, onDisk: AudioOnDisk?)] = [:]

    /// The row's files as last read, read now through `resolve` when this row
    /// has not been read since the last refresh.
    func filesOnDisk(for entry: TranscriptionEntry, resolve: (TranscriptionEntry) -> FilesOnDisk) -> FilesOnDisk {
        _ = generation
        if let known = found[entry.id] { return known }
        let read = resolve(entry)
        found[entry.id] = read
        return read
    }

    /// The row's audio as last read for `record`, read now through `resolve` when
    /// this row has not been read for that record since the last refresh. Nil without
    /// a record: a row without one shows nothing about its audio.
    func audioOnDisk(for entry: TranscriptionEntry, record: MeetingFileRecord?, resolve: (TranscriptionEntry) -> AudioOnDisk?) -> AudioOnDisk? {
        _ = generation
        guard let record else {
            audio[entry.id] = nil
            return nil
        }
        if let known = audio[entry.id], known.record == record { return known.onDisk }
        let read = resolve(entry)
        audio[entry.id] = (record, read)
        return read
    }

    /// Forgets every row's files and audio, so each is read again the next time it
    /// is drawn.
    func refresh() {
        found.removeAll()
        audio.removeAll()
        generation += 1
    }
}
