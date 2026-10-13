import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProtocolGenerator")

/// Abstraction for protocol generation, enabling mock injection in tests.
protocol ProtocolGenerating {
    func generate(
        transcript: String, title: String, diarized: Bool, meetingStartTime: Date?, instructions: ProtocolInstructions,
    ) async throws -> String
}

/// What a job asks the provider for beyond the transcript: the text of its
/// protocol template and the background info the person typed for the meeting.
///
/// The template text still carries its `{LANGUAGE}` / `{MEETING_DATE}` /
/// `{MEETING_TIME}` placeholders; `ProtocolGenerator.buildSystemPrompt` fills
/// them in. The background is never placeholder-replaced and never logged.
struct ProtocolInstructions: Equatable {
    let template: String
    /// Trimmed; nil when blank, so "no background" has one representation.
    let background: String?

    init(template: String, background: String?) {
        self.template = template
        let trimmed = background?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.background = trimmed.isEmpty ? nil : trimmed
    }
}

/// Shared protocol utilities: prompts, file operations, and error types.
enum ProtocolGenerator {
    struct MeetingPromptMetadata: Equatable {
        let date: String
        let time: String
    }

    static let unknownMeetingMetadata = "Unknown"

    static let protocolPrompt = """
    You are a professional meeting minute taker.
    Create a structured meeting protocol in {LANGUAGE} from the following transcript.

    Return ONLY the finished Markdown document - no explanations, no introduction,
    no comments before or after.

    Use exactly this structure:

    # Meeting Protocol - [Meeting Title]
    **Date:** {MEETING_DATE}
    **Time:** {MEETING_TIME}

    ---

    ## Summary
    [3-5 sentence summary of the meeting]

    ## Participants
    - [Name 1]
    - [Name 2]

    ## Topics Discussed

    ### [Topic 1]
    [What was discussed]

    ### [Topic 2]
    [What was discussed]

    ## Decisions
    - [Decision 1]
    - [Decision 2]

    ## Tasks
    | Task | Responsible | Deadline | Priority |
    |------|-------------|----------|----------|
    | [Description] | [Name] | [Date or open] | 🔴 high / 🟡 medium / 🟢 low |

    ## Open Questions
    - [Question 1]
    - [Question 2]

    Do NOT include the full transcript in the output.

    ---
    Transcript:
    """

    static let diarizationNote = """
    \nNote: The transcript contains speaker labels in brackets. \
    Possible label formats:
    - [SPEAKER_00], [SPEAKER_01] — auto-detected speakers (use Speaker 1, Speaker 2)
    - [Me], [Roman] etc. — the local microphone user
    - [Remote] — remote participant(s) without diarization
    - [Name] — a recognized or named speaker
    Use these labels to identify participants. \
    In the Participants section, list them by name where possible. \
    In the Topics Discussed section, attribute key statements to speakers.
    """

    /// Replaces supported protocol-prompt variables with meeting-specific values.
    ///
    /// Dates and times use stable, locale-independent formats so users can
    /// reliably instruct their LLMs to resolve relative time expressions. When
    /// a recording has no captured start time (for example, an import), the
    /// date and time variables resolve to `Unknown` rather than processing time.
    static func applyVariables(
        _ prompt: String,
        language: String,
        metadata: MeetingPromptMetadata?,
    ) -> String {
        prompt
            .replacingOccurrences(of: "{LANGUAGE}", with: language)
            .replacingOccurrences(of: "{MEETING_DATE}", with: metadata?.date ?? unknownMeetingMetadata)
            .replacingOccurrences(of: "{MEETING_TIME}", with: metadata?.time ?? unknownMeetingMetadata)
    }

    /// Build the system prompt: an optional authoritative meeting-time context,
    /// the background block when the job has background info, the template with
    /// its variables replaced, and the optional `diarizationNote`. Imports and
    /// recovery jobs have no reliable meeting start and therefore receive no
    /// authoritative time anchor. Excludes the transcript itself — callers
    /// append or attach it as they see fit.
    ///
    /// With the built-in template and no background this is byte-identical to
    /// the prompt from before templates existed.
    static func buildSystemPrompt(
        diarized: Bool,
        language: String,
        meetingStartTime: Date?,
        instructions: ProtocolInstructions,
        timeZone: TimeZone = .autoupdatingCurrent,
    ) -> String {
        let metadata = meetingStartTime.map { meetingMetadata(for: $0, timeZone: timeZone) }
        var prompt = meetingTimeContext(metadata: metadata)
            + backgroundBlock(instructions.background)
            + applyVariables(instructions.template, language: language, metadata: metadata)
        if diarized { prompt += diarizationNote }
        return prompt
    }

    /// The whole prompt a CLI provider sends: `buildSystemPrompt` followed by
    /// the transcript.
    static func fullPrompt(
        transcript: String,
        diarized: Bool,
        language: String,
        meetingStartTime: Date?,
        instructions: ProtocolInstructions,
    ) -> String {
        buildSystemPrompt(
            diarized: diarized, language: language, meetingStartTime: meetingStartTime, instructions: instructions,
        ) + transcript
    }

    static func meetingMetadata(
        for meetingStartTime: Date,
        timeZone: TimeZone = .autoupdatingCurrent,
    ) -> MeetingPromptMetadata {
        let dateFormatter = DateFormatter.filenameStamp("yyyy-MM-dd")
        dateFormatter.timeZone = timeZone
        let timeFormatter = DateFormatter.filenameStamp("HH:mm")
        timeFormatter.timeZone = timeZone
        return MeetingPromptMetadata(
            date: dateFormatter.string(from: meetingStartTime),
            time: timeFormatter.string(from: meetingStartTime),
        )
    }

    private static func meetingTimeContext(metadata: MeetingPromptMetadata?) -> String {
        guard let metadata else { return "" }
        return [
            "Meeting metadata:",
            "Date: \(metadata.date)",
            "Time: \(metadata.time)",
            "The date and time above are authoritative. Interpret relative time expressions",
            "in the transcript relative to this meeting date. Do not rely on the model's",
            "assumed current date.",
        ].joined(separator: "\n") + "\n\n"
    }

    /// The person's background info, verbatim and outside the template, so no
    /// template has to make room for it and no placeholder can rewrite it.
    private static func backgroundBlock(_ background: String?) -> String {
        guard let background else { return "" }
        return [
            "Background information about this meeting, provided by the person who recorded it:",
            "<background>",
            background,
            "</background>",
            "Use it to identify participants, agenda items and the goal of the meeting. "
                + "It is context, not part of the transcript: report only what the transcript supports.",
        ].joined(separator: "\n") + "\n\n"
    }

    // MARK: - Protocol document

    /// Separates the protocol from the verbatim transcript appended to it.
    static let fullTranscriptSeparator = "\n\n---\n\n## Full Transcript\n\n"

    /// The Markdown file a protocol run saves: the generated protocol, followed
    /// by the transcript when the job asked for it.
    static func composeDocument(protocolMarkdown: String, transcript: String, includeFullTranscript: Bool) -> String {
        includeFullTranscript ? protocolMarkdown + fullTranscriptSeparator + transcript : protocolMarkdown
    }

    /// The transcript `composeDocument` appended to a protocol: the text after
    /// the last separator. The last, because the generated protocol before it
    /// is model output and may repeat the heading itself. Nil when there is no
    /// separator or nothing but whitespace follows it.
    static func fullTranscript(in document: String) -> String? {
        guard let separator = document.range(of: fullTranscriptSeparator, options: .backwards) else { return nil }
        let transcript = String(document[separator.upperBound...])
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : transcript
    }

    /// Whether a transcript carries speaker labels (`[Name]`), which decides
    /// whether the prompt explains them.
    static func looksDiarized(_ transcript: String) -> Bool {
        transcript.range(of: #"\[\w[\w\s]*\]"#, options: .regularExpression) != nil
    }

    // MARK: - File Operations

    /// Save a transcript to a text file.
    ///
    /// `basename` is the job's precomputed, meeting-start-anchored stem (shared
    /// with the protocol and audio artifacts); the `.txt` extension is appended.
    ///
    /// Opens no security scope: `PipelineQueue` holds it on the output root
    /// (see `SecurityScopeAccess`).
    ///
    /// - Returns: URL of the saved file
    static func saveTranscript(_ text: String, basename: String, dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(basename).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        // Transcripts contain verbatim meeting speech — restrict to owner-only.
        try FileManager.default.restrictToOwner(url)
        logger.info("Transcript saved: \(url.lastPathComponent, privacy: .private)")
        return url
    }

    /// Save a protocol to a Markdown file.
    ///
    /// `basename` is the job's precomputed, meeting-start-anchored stem (shared
    /// with the transcript and audio artifacts); the `.md` extension is appended.
    ///
    /// Opens no security scope, as for `saveTranscript`.
    ///
    /// - Returns: URL of the saved file
    static func saveProtocol(_ markdown: String, basename: String, dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(basename).md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        // Protocol markdown summarises the meeting — restrict to owner-only.
        try FileManager.default.restrictToOwner(url)
        logger.info("Protocol saved: \(url.lastPathComponent, privacy: .private)")
        return url
    }

    private static let filenameFormatter = DateFormatter.filenameStamp("yyyyMMdd_HHmm")

    /// Sanitize a title into a safe filename slug (path-traversal safe).
    /// Falls back to `"meeting"` if no allowed characters remain.
    private static let slugAllowed = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_"))

    static func sanitizeSlug(_ title: String) -> String {
        let slug = String(stripExistingTimestampPrefix(title)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .unicodeScalars
            .filter { slugAllowed.contains($0) }
            .map(Character.init))
        return slug.isEmpty ? "meeting" : slug
    }

    /// Re-importing a previously-processed recording feeds its slug-based stem
    /// back as a title (e.g. `20260516_1319_20260503_174538`). `filename` would
    /// then prepend ANOTHER `yyyyMMdd_HHmm_` → compounding-prefix loop on every
    /// reprocess. Strip a leading `yyyyMMdd_HHmm[ss]_` so the slug stays
    /// idempotent across reprocesses.
    static func stripExistingTimestampPrefix(_ title: String) -> String {
        let patterns = [#"^\d{8}_\d{6}_"#, #"^\d{8}_\d{4}_"#]
        var result = title
        // Apply repeatedly — input may already contain multiple compounded layers
        // from earlier buggy runs; one call should normalize the worst case.
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                if let range = result.range(of: pattern, options: .regularExpression) {
                    result.removeSubrange(range)
                    changed = true
                }
            }
        }
        return result.isEmpty ? title : result
    }

    /// Build a filesystem basename: `{yyyyMMdd_HHmm}_{slug}[_{shortID}]`.
    ///
    /// The timestamp is anchored on `startTime` (the meeting start) so the name
    /// reflects when the meeting happened, not when the pipeline processed it.
    /// The trailing `shortID` (when non-empty) is a per-job collision guard so
    /// two same-title meetings can't clobber each other's files. Empty
    /// components are dropped, so `shortID: ""` yields the plain
    /// `{yyyyMMdd_HHmm}_{slug}` shape.
    static func basename(title: String, startTime: Date, shortID: String) -> String {
        let date = filenameFormatter.string(from: startTime)
        let slug = sanitizeSlug(title)
        return [date, slug, shortID].filter { !$0.isEmpty }.joined(separator: "_")
    }

    /// Generate a filename: `{yyyyMMdd_HHmm}_{slug}.{ext}`, stamped with the
    /// current time and no collision suffix. Thin wrapper over `basename`.
    static func filename(title: String, ext: String) -> String {
        "\(basename(title: title, startTime: Date(), shortID: "")).\(ext)"
    }
}

enum ProtocolError: LocalizedError {
    #if !APPSTORE
        case cliNotFound(String)
        case cliFailed(Int, String)
        case timeout
        /// A CLI tool wrote more to stdout than a run accepts. Names the tool
        /// only: the output itself may hold meeting content.
        case commandOutputTooLarge(tool: String)
        // The command providers' errors (Codex CLI, custom command). Their
        // text is logged at `.public`, so it holds only the tool label, the
        // program's file name, the exit code and a reason the tool itself
        // reported, never the program's output or the command's arguments.
        case commandNotFound(tool: String, program: String)
        /// `reason` is the tool's own content-free error message, if any.
        case commandFailed(tool: String, exitCode: Int32, reason: String?)
        case commandTimedOut(tool: String)
        case commandProducedNoProtocol(tool: String)
        /// The command cannot run as configured; carries app-written text only.
        case commandNotConfigured(String)
    #endif
    case emptyProtocol
    case httpError(Int, String)
    case connectionFailed(String)
    case generationTimedOut(Int)
    case protocolTruncated

    var errorDescription: String? {
        switch self {
        #if !APPSTORE
            case let .cliNotFound(bin): "'\(bin)' CLI not found. Install: npm install -g @anthropic-ai/claude-code"

            case let .cliFailed(code, stderr): "Claude CLI exited with code \(code)\(stderr.isEmpty ? "" : ": \(stderr)")"

            case .timeout: "Claude CLI took too long (>10 min)"

            case let .commandOutputTooLarge(tool): "\(tool) wrote more output than the app accepts"

            case let .commandNotFound(tool, program): "\(tool): program '\(program)' not found or not executable"

            case let .commandFailed(tool, exitCode, reason): "\(tool) exited with code \(exitCode)\(reason.map { ": \($0)" } ?? "")"

            case let .commandTimedOut(tool): "\(tool) took too long (>10 min)"

            case let .commandProducedNoProtocol(tool): "\(tool) produced no protocol"

            case let .commandNotConfigured(message): message
        #endif

        case .emptyProtocol: "Protocol is empty. Tip: Test manually: echo Hello | claude --print"

        case let .httpError(code, body): "HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"

        case let .connectionFailed(reason): "Connection failed: \(reason)"

        case let .generationTimedOut(seconds): "Protocol generation timed out after \(seconds)s. The LLM endpoint is stuck or too slow — try a smaller model or shorter context."

        case .protocolTruncated: "Protocol was cut off before finishing (model hit its output/context limit). Raise the limit or shorten the transcript."
        }
    }
}
