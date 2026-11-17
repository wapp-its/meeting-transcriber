import Foundation

/// The rules of a meeting's summary in All Recordings: one plain-text paragraph of at
/// most `maxLength` characters. Pure: the store keeps what these return, the
/// summarizer asks the provider with `instruction`, and the sheet saves through
/// `afterTyped`.
///
/// A meeting keeps up to two (`MeetingSummaries`): the notes summary, from the notes
/// the app last saved for it, and the typed one, which the user wrote and which new
/// notes never replace. The row, its tooltip, the sheet and the search show the typed
/// one when there is one.
enum MeetingSummary {
    static let maxLength = 600
    /// The most of the notes a summary call sends.
    static let maxNotesForCall = 32000

    /// The template the summary call passes in place of the notes template, so
    /// `ProtocolGenerator.buildSystemPrompt` fills in `{LANGUAGE}` as it does for the
    /// notes, and adds no meeting time, background or speaker note around it. The
    /// providers put the notes right after it, so it ends with a line break.
    static let instruction = """
    Write a summary of the following meeting notes in {LANGUAGE}: one paragraph of plain text, \
    at most three sentences and at most 600 characters, saying what the meeting was about and \
    what was decided. Return only the summary, with no heading, list, Markdown or introduction.

    Meeting notes:

    """

    /// The heading words a summary section starts with, per notes language the app
    /// offers (`AppSettings.protocolLanguages`), compared without case and diacritics
    /// with what a heading is or begins with. Where models use more than one word for
    /// it, each is listed.
    static let headingNames: [String: [String]] = [
        "German": ["Zusammenfassung"],
        "English": ["Summary"],
        "French": ["Résumé"],
        "Spanish": ["Resumen"],
        "Italian": ["Riepilogo", "Riassunto", "Sommario"],
        "Dutch": ["Samenvatting"],
        "Portuguese": ["Resumo"],
        "Japanese": ["要約", "概要", "まとめ"],
        "Chinese": ["摘要", "总结", "總結", "概要"],
        "Korean": ["요약"],
        "Russian": ["Резюме", "Краткое содержание", "Сводка"],
        "Arabic": ["ملخص", "الملخص"],
        "Turkish": ["Özet"],
        "Hindi": ["सारांश"],
        "Indonesian": ["Ringkasan"],
        "Swedish": ["Sammanfattning"],
        "Danish": ["Resumé", "Sammenfatning", "Opsummering"],
        "Finnish": ["Yhteenveto"],
        "Polish": ["Podsumowanie", "Streszczenie"],
        "Czech": ["Shrnutí"],
        "Greek": ["Περίληψη", "Σύνοψη"],
        "Hungarian": ["Összefoglaló", "Összefoglalás"],
        "Romanian": ["Rezumat"],
    ]

    private static let foldedHeadingNames: [String] = headingNames.values.flatMap(\.self).map(fold)

    // MARK: - The summary section rule

    /// The summary the saved notes give: the text of the first heading, at any level,
    /// whose words are or begin with a summary name, up to the next heading and never
    /// past an appended full transcript, cleaned up. A heading inside an HTML comment
    /// neither starts nor ends the section. Nil when the notes have no such section or
    /// it holds nothing once cleaned.
    static func section(in notes: String) -> String? {
        let lines = lines(of: withoutComments(withoutTranscript(notes)))
        guard let start = lines.firstIndex(where: { heading(of: $0).map(isSummaryHeading) ?? false }) else { return nil }
        let body = lines[(start + 1)...].prefix { heading(of: $0) == nil }
        return clean(body.joined(separator: "\n"))
    }

    /// The notes a summary call sends: without an appended full transcript, and at
    /// most `maxNotesForCall` characters, cut at the end of a line.
    static func notesForCall(_ notes: String) -> String {
        let text = withoutTranscript(notes)
        guard text.count > maxNotesForCall else { return text }
        let head = text.prefix(maxNotesForCall)
        guard let lineEnd = head.lastIndex(where: \.isNewline) else { return String(head) }
        return String(head[..<lineEnd])
    }

    // MARK: - Clean-up

    /// A section's text or a call's answer as one paragraph: tables, HTML comments,
    /// horizontal rules, headings, label lines such as `**Date:** …` and paragraphs
    /// wholly in square brackets dropped, list and block-quote markers and Markdown
    /// marks removed, joined with single spaces and cut to `maxLength` at a word end
    /// with "…". Nil when nothing is left.
    static func clean(_ text: String) -> String? {
        let kept = paragraphs(of: withoutComments(text)).compactMap(paragraphText)
        let joined = kept.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : cut(joined)
    }

    /// `text` itself when it fits, else its first words that fit with "…".
    static func cut(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let head = text.prefix(maxLength - 1)
        let words = head.lastIndex(where: \.isWhitespace).map { head[..<$0] } ?? head
        return words.trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Replace or keep

    /// The summaries after the app saved a meeting's current notes, with what those
    /// notes gave: their summary section or the call's answer, nil for none (provider
    /// None, a failed, timed-out or empty call). A found one becomes the notes
    /// summary; none keeps the earlier one (A18); the typed one stays either way.
    static func afterNotesSaved(_ summaries: MeetingSummaries?, notesSummary: String?, at date: Date) -> MeetingSummaries? {
        guard let notesSummary else { return summaries }
        return MeetingSummaries(notes: .init(text: notesSummary, writtenAt: date), typed: summaries?.typed)
    }

    /// The summaries after Save in the Edit Summary sheet with `field`, the text as the
    /// field holds it (at most `maxLength` characters, as Save is disabled beyond).
    /// Saving no text removes both, so the next notes fill it again; a text equal to
    /// the notes summary is that summary, with no typed one.
    static func afterTyped(_ summaries: MeetingSummaries?, field: String, at date: Date) -> MeetingSummaries? {
        let text = typedText(field)
        guard !text.isEmpty else { return nil }
        if let notes = summaries?.notes, notes.text == text {
            return MeetingSummaries(notes: notes, typed: nil)
        }
        return MeetingSummaries(notes: summaries?.notes, typed: .init(text: text, writtenAt: date))
    }

    /// The field's text trimmed, its line breaks joined by single spaces.
    static func typedText(_ field: String) -> String {
        field.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Reading Markdown

    /// The notes before the separator of an appended full transcript, the last one, as
    /// `ProtocolGenerator.fullTranscript(in:)` finds it.
    private static func withoutTranscript(_ notes: String) -> String {
        guard let separator = notes.range(of: ProtocolGenerator.fullTranscriptSeparator, options: .backwards) else { return notes }
        return String(notes[..<separator.lowerBound])
    }

    /// Without HTML comments, an unclosed one running to the end.
    private static func withoutComments(_ text: String) -> String {
        text.replacingOccurrences(of: #"<!--[\s\S]*?(-->|$)"#, with: "", options: .regularExpression)
    }

    private static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    /// An ATX heading's text without its marks, a leading number ("1.") and a trailing
    /// colon; nil for a line that is no heading.
    private static func heading(of line: String) -> String? {
        guard let match = line.firstMatch(of: /^ {0,3}#{1,6}(?:[ \t]+(.*?))?[ \t#]*$/) else { return nil }
        var text = removingMarks(String(match.1 ?? ""))
        text = text.replacing(/^\s*\d+[.)]\s*/, with: "")
        text = text.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(":") || text.hasSuffix("：") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func isSummaryHeading(_ text: String) -> Bool {
        let folded = fold(text)
        return foldedHeadingNames.contains { folded.hasPrefix($0) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The text's paragraphs and list items, each as its lines, blank lines between.
    private static func paragraphs(of text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for line in lines(of: text) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || isListItem(line) {
                if !current.isEmpty { result.append(current) }
                current = []
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { current.append(line) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// One paragraph as plain text, nil when the rule drops all of it.
    private static func paragraphText(_ lines: [String]) -> String? {
        let kept = withoutTables(lines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") || isRule(trimmed) || heading(of: line) != nil || isLabelLine(trimmed) { return nil }
            return removingMarks(withoutMarkers(trimmed))
        }
        let text = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isWhollyBracketed(text) else { return nil }
        return text
    }

    /// Without its tables, outer pipes or not: a delimiter row such as `--- | :---:`,
    /// the header row above it and the rows with a pipe below it.
    private static func withoutTables(_ lines: [String]) -> [String] {
        var kept = lines
        var index = 1
        while index < kept.count {
            guard isTableDelimiter(kept[index]), kept[index - 1].contains("|") else {
                index += 1
                continue
            }
            var end = index + 1
            while end < kept.count, kept[end].contains("|") {
                end += 1
            }
            kept.removeSubrange((index - 1) ..< end)
            index = max(index - 1, 1)
        }
        return kept
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        line.wholeMatch(of: /\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)+\|?\s*/) != nil
    }

    private static func isListItem(_ line: String) -> Bool {
        line.contains(/^\s*(?:>\s*)*(?:[-*+]|\d+[.)])\s+\S/)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        trimmed.wholeMatch(of: /(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,}/) != nil
    }

    /// A line opening with a bold label such as `**Date:**` or `__Time__:`.
    private static func isLabelLine(_ trimmed: String) -> Bool {
        trimmed.contains(/^(?:\*\*|__)[^*_]+?(?::(?:\*\*|__)|(?:\*\*|__):)/)
    }

    /// Without its block-quote and list markers.
    private static func withoutMarkers(_ line: String) -> String {
        line.replacing(/^(?:>\s*)+/, with: "").replacing(/^(?:[-*+]|\d+[.)])\s+/, with: "")
    }

    /// Without emphasis, strike-through and inline-code marks, a link or image shown
    /// as its text.
    private static func removingMarks(_ text: String) -> String {
        text.replacing(/!?\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
            .replacing(/\*+|~~|`+/, with: "")
            .replacingOccurrences(of: #"(?<![\p{L}\p{N}])_+|_+(?![\p{L}\p{N}])"#, with: "", options: .regularExpression)
    }

    /// Whether the bracket opening the text closes at its very end.
    private static func isWhollyBracketed(_ text: String) -> Bool {
        guard text.hasPrefix("["), text.hasSuffix("]") else { return false }
        var depth = 0
        for (offset, character) in text.enumerated() {
            if character == "[" { depth += 1 }
            if character == "]" { depth -= 1 }
            if depth == 0 { return offset == text.count - 1 }
        }
        return false
    }
}

/// A meeting's two summaries (`MeetingSummary`), as the summary file keeps them.
struct MeetingSummaries: Codable, Equatable {
    /// One summary and when it was written.
    struct Saved: Codable, Equatable {
        let text: String
        let writtenAt: Date
    }

    /// From the notes the app last saved for the meeting.
    var notes: Saved?
    /// The user's own, which new notes never replace.
    var typed: Saved?

    /// What the row, its tooltip, the sheet and the search show.
    var shown: String? {
        typed?.text ?? notes?.text
    }
}
