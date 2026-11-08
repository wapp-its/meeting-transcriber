import Foundation

/// A meeting's additional reports: Markdown files beside its files, named
/// `<basename> (<report name>).md`, which "Regenerate Notes…" writes when the
/// user saves the new notes as an additional report. The meeting's `<basename>.md`
/// stays its main protocol everywhere.
///
/// Nothing records a report while the meeting lives: each one is found by its
/// name, by the one ownership rule below, which the row's menu, the regenerate
/// sheet, "Regenerate from File…", Move Meeting to Trash and the title rename all
/// apply. So a report deleted or renamed in Finder drops out, and one whose
/// template was deleted later stays listed.
enum AdditionalReport {
    /// One report of a meeting, as the menu lists it.
    struct Listed: Equatable, Hashable, Sendable {
        /// What the menu shows: the text inside the file name's last brackets.
        let name: String
        let fileName: String
    }

    /// The built-in template's report name: its picker label "Standard (built-in)"
    /// would put brackets inside the brackets of the file name (spec A5). A user
    /// template named "Standard" shares the file and counts as the same template.
    static let builtInName = "Standard"

    static func name(of template: ProtocolTemplateID) -> String {
        switch template {
        case .builtIn: builtInName
        case let .file(name): name
        }
    }

    static func fileName(basename: String, name: String) -> String {
        "\(basename) (\(name)).md"
    }

    /// Whose report a Markdown file named `<stem>.md` is, for a file that has no
    /// `<stem>.txt` of its own (that one is a meeting, never a report; the caller
    /// asks the folder). A stem ending in `)` is split at each ` (`, and the file
    /// belongs to the longest part before such a split whose meeting has a
    /// transcript; the report's name is the text after that split, without its
    /// closing bracket. `Budget (Q3) (Short)` belongs to `Budget (Q3)` when that
    /// meeting has a transcript, else to `Budget` as the report `Q3) (Short`.
    /// Nil for a stem with no such part, which is no report.
    static func owner(ofStem stem: String, hasTranscript: (String) -> Bool) -> (meeting: String, name: String)? {
        guard stem.hasSuffix(")") else { return nil }
        let nameEnd = stem.index(before: stem.endIndex)
        var splits: [(meeting: String, name: String)] = []
        var searched = stem.startIndex ..< nameEnd
        while let split = stem.range(of: " (", range: searched) {
            if split.lowerBound > stem.startIndex, split.upperBound < nameEnd {
                splits.append((String(stem[..<split.lowerBound]), String(stem[split.upperBound ..< nameEnd])))
            }
            searched = split.upperBound ..< nameEnd
        }
        return splits.reversed().first { hasTranscript($0.meeting) }
    }

    /// Whether the meeting `stem` in `folder` has a transcript the way a
    /// regeneration finds one (`ProtocolRegenerationFiles.transcript`): its `.txt`,
    /// else the Full Transcript section of its `.md`, which is all a meeting has
    /// with "Save raw transcript separately" off. The `.md` is read only when the
    /// `.txt` does not answer.
    static func hasTranscript(folder: URL, stem: String, read: (URL) -> Data?) -> Bool {
        if let data = read(folder.appendingPathComponent("\(stem).txt")), let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let data = read(folder.appendingPathComponent("\(stem).md")),
              let document = String(data: data, encoding: .utf8) else { return false }
        return ProtocolGenerator.fullTranscript(in: document) != nil
    }
}

/// One folder as it was read for one meeting's reports: its file names, and
/// which longer meeting names in it have a transcript. Pure once read, so the
/// sheet, the row and the deletion decide from the same answers.
///
/// The meeting itself counts as having a transcript: from a row's side its
/// reports stay its reports when its transcript is gone, as long as no longer
/// meeting name claims them.
///
/// Names are compared without regard to case, as the default macOS volume
/// compares them: there `Budget (Q3).md` reaches the file `Budget (q3).md`, and a
/// report written under the one name would replace another meeting's notes under
/// the other. On a case-sensitive volume this only refuses more.
struct MeetingReportFolder: Equatable, Sendable {
    /// Where the chosen template's report would go.
    enum Slot: Equatable, Sendable {
        case free(fileName: String)
        /// The template already has a report, which the new one replaces.
        case existing(fileName: String)
        /// The ownership rule gives the name to another meeting: the protocol of a
        /// meeting of its own, or a report a longer meeting name claims.
        case otherMeeting(fileName: String)
    }

    let basename: String
    let names: Set<String>
    /// Of the names longer than `basename` that start with `"<basename> ("`, the
    /// meetings with a transcript. Every meeting that can claim a file named after
    /// this one is among them.
    let transcriptStems: Set<String>
    private let foldedNames: Set<String>
    private let foldedTranscriptStems: Set<String>

    init(basename: String, names: Set<String>, transcriptStems: Set<String>) {
        self.basename = basename
        self.names = names
        self.transcriptStems = transcriptStems
        foldedNames = Set(names.map(Self.folded))
        foldedTranscriptStems = Set(transcriptStems.map(Self.folded))
    }

    /// A name as the comparisons here see it.
    static func folded(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: nil)
    }

    /// Whether `name` starts with `"<basename> ("`, without regard to case.
    static func isNamed(after basename: String, _ name: String) -> Bool {
        folded(name).hasPrefix(folded("\(basename) ("))
    }

    /// Nil when the folder cannot be listed.
    static func read(
        folder: URL, basename: String,
        list: (URL) -> [String]?, // swiftlint:disable:this discouraged_optional_collection
        read: (URL) -> Data?,
    ) -> Self? {
        guard let listed = list(folder) else { return nil }
        let names = Set(listed)
        let stems = Set(names.compactMap { name -> String? in
            let stem = [".md", ".txt"].first(where: name.hasSuffix).map { String(name.dropLast($0.count)) }
            return stem.flatMap { isNamed(after: basename, $0) ? $0 : nil }
        })
        return Self(
            basename: basename, names: names,
            transcriptStems: stems.filter { AdditionalReport.hasTranscript(folder: folder, stem: $0, read: read) },
        )
    }

    /// The meeting a Markdown file of this folder belongs to as a report, with the
    /// report's name; nil for a file that is a meeting of its own or no report.
    func owner(ofFileName name: String) -> (meeting: String, name: String)? {
        guard name.hasSuffix(".md") else { return nil }
        let stem = String(name.dropLast(3))
        guard !foldedNames.contains(Self.folded("\(stem).txt")) else { return nil }
        return AdditionalReport.owner(ofStem: stem) { meeting in
            isThisMeeting(meeting) || foldedTranscriptStems.contains(Self.folded(meeting))
        }
    }

    private func isThisMeeting(_ meeting: String) -> Bool {
        Self.folded(meeting) == Self.folded(basename)
    }

    /// This meeting's reports, by name in alphabetical order.
    var reports: [AdditionalReport.Listed] {
        names.filter { Self.isNamed(after: basename, $0) }
            .compactMap { name -> AdditionalReport.Listed? in
                guard let owner = owner(ofFileName: name), isThisMeeting(owner.meeting) else { return nil }
                return AdditionalReport.Listed(name: owner.name, fileName: name)
            }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.fileName < rhs.fileName : order == .orderedAscending
            }
    }

    /// Where the report named `name` would be written.
    func slot(forReportNamed name: String) -> Slot {
        let fileName = AdditionalReport.fileName(basename: basename, name: name)
        guard let owner = owner(ofFileName: fileName), isThisMeeting(owner.meeting) else { return .otherMeeting(fileName: fileName) }
        return foldedNames.contains(Self.folded(fileName)) ? .existing(fileName: fileName) : .free(fileName: fileName)
    }
}
