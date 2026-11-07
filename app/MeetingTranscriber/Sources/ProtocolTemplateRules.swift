// The template rules: a rule, the check a typed pattern must pass before it is
// saved, and the resolver that picks a meeting title's template.
import Foundation

/// One template rule: a meeting whose title matches `pattern` gets `template`.
///
/// Stored in `AppSettings.protocolTemplateRules` as one dictionary of two
/// strings, the template in `ProtocolTemplateID.storedValue` form, so a
/// template name this build does not know reads back as a missing template,
/// never as an error.
struct ProtocolTemplateRule: Equatable {
    /// A regular expression, matched ignoring case anywhere in the title.
    let pattern: String
    let template: ProtocolTemplateID

    private static let patternKey = "pattern"
    private static let templateKey = "template"

    /// The list as UserDefaults stores it.
    static func storedList(_ rules: [Self]) -> [[String: String]] {
        rules.map { [patternKey: $0.pattern, templateKey: $0.template.storedValue] }
    }

    /// The list `storedList` wrote. An entry that is not two strings is
    /// dropped and the others kept, so one damaged entry never empties the list.
    static func list(fromStored stored: [Any]) -> [Self] {
        stored.compactMap { entry in
            guard let entry = entry as? [String: Any],
                  let pattern = entry[patternKey] as? String,
                  let template = entry[templateKey] as? String
            else { return nil }
            return Self(pattern: pattern, template: ProtocolTemplateID(storedValue: template))
        }
    }
}

/// Whether a typed pattern can be saved, and the message when it cannot.
enum ProtocolTemplateRulePattern {
    enum Refusal: Equatable {
        case empty
        /// `unclosed` is the opener that is not closed, when that is the reason
        /// found. The system's error names no reason (measured), so this is
        /// the only one the app can name.
        case invalid(unclosed: Character?)

        var message: String {
            switch self {
            case .empty:
                "Enter a pattern. The rule is saved once the pattern is valid."

            case let .invalid(unclosed?):
                "Not a valid pattern: a “\(unclosed)” is not closed. The rule is saved once the pattern is valid."

            case .invalid(nil):
                "Not a valid pattern. The rule is saved once the pattern is valid."
            }
        }
    }

    /// Nil when `text` is a pattern a rule can use.
    static func refusal(for text: String) -> Refusal? {
        if text.isEmpty { return .empty }
        return ProtocolTemplateRules.compile(text) == nil ? .invalid(unclosed: unclosedOpener(in: text)) : nil
    }

    /// "[" for a character class still open at the end, "(" for a group, nil
    /// otherwise. Only read once the pattern failed to compile.
    private static func unclosedOpener(in pattern: String) -> Character? {
        var depth = 0
        var inClass = false
        var escaped = false
        for character in pattern {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if inClass {
                if character == "]" { inClass = false }
            } else if character == "[" {
                inClass = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
            }
        }
        if inClass { return "[" }
        return depth > 0 ? "(" : nil
    }
}

/// Which template a new meeting gets from its title. The one place titles are
/// matched against rules: queue admission, both options windows and the
/// Settings try-a-title field all call `resolve`.
///
/// Runs on the main actor at every caller and decides synchronously, so a
/// pattern that runs away on a title is stopped by time: one rule after
/// `ruleTimeLimit`, all rules of one title after `titleTimeLimit`. Measured
/// with the system's regular expressions, a stopped check ends within a
/// millisecond of its limit and an ordinary one takes a few microseconds, so
/// only a broken pattern reaches the limits.
enum ProtocolTemplateRules {
    static let ruleTimeLimit: TimeInterval = 0.05
    static let titleTimeLimit: TimeInterval = 0.25

    /// What picked the template.
    enum Source: Equatable {
        /// The rule at `index` (0-based) in the list, with its pattern.
        case rule(index: Int, pattern: String)
        case defaultTemplate
    }

    struct Choice: Equatable {
        let template: ProtocolTemplateID
        let source: Source
        /// 0-based indices of the rules that ran out of time on this title,
        /// including those not tried because the title's time was used up;
        /// reported whatever won.
        let timedOutRules: [Int]
    }

    /// The first rule, in list order, whose pattern compiles, whose template
    /// is present and whose pattern matches somewhere in `title`, ignoring
    /// case; otherwise `defaultTemplate`. A rule's template comes back spelt as
    /// `templateNames` lists it. An empty title gets the default.
    static func resolve(
        title: String,
        rules: [ProtocolTemplateRule],
        templateNames: [String],
        defaultTemplate: ProtocolTemplateID,
        ruleTimeLimit: TimeInterval = ruleTimeLimit,
        titleTimeLimit: TimeInterval = titleTimeLimit,
    ) -> Choice {
        var timedOut: [Int] = []
        guard !title.isEmpty else {
            return Choice(template: defaultTemplate, source: .defaultTemplate, timedOutRules: [])
        }
        let titleDeadline = Date().addingTimeInterval(titleTimeLimit)
        for (index, rule) in rules.enumerated() {
            guard let template = present(rule.template, in: templateNames),
                  let regex = compile(rule.pattern)
            else { continue }
            let remaining = titleDeadline.timeIntervalSinceNow
            guard remaining > 0 else {
                timedOut.append(index)
                continue
            }
            switch check(regex, on: title, limit: min(ruleTimeLimit, remaining)) {
            case .matched:
                return Choice(template: template, source: .rule(index: index, pattern: rule.pattern), timedOutRules: timedOut)

            case .timedOut:
                timedOut.append(index)

            case .noMatch:
                continue
            }
        }
        return Choice(template: defaultTemplate, source: .defaultTemplate, timedOutRules: timedOut)
    }

    /// Nil for an empty pattern or one the system does not accept.
    static func compile(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// `id` spelt as `names` lists it, exact match first; nil for a file that
    /// is not listed. The built-in is always present.
    static func present(_ id: ProtocolTemplateID, in names: [String]) -> ProtocolTemplateID? {
        guard case let .file(name) = id else { return id }
        if names.contains(name) { return id }
        return names.first { $0.caseInsensitiveCompare(name) == .orderedSame }.map { .file(name: $0) }
    }

    private enum Outcome {
        case matched, noMatch, timedOut
    }

    /// `.reportProgress` makes the system call the block while a match attempt
    /// backtracks, which is what lets a run-away check be stopped.
    private static func check(_ regex: NSRegularExpression, on title: String, limit: TimeInterval) -> Outcome {
        let deadline = Date().addingTimeInterval(limit)
        var outcome = Outcome.noMatch
        let range = NSRange(title.startIndex ..< title.endIndex, in: title)
        regex.enumerateMatches(in: title, options: [.reportProgress], range: range) { result, _, stop in
            if result != nil {
                outcome = .matched
                stop.pointee = true
            } else if Date() >= deadline {
                outcome = .timedOut
                stop.pointee = true
            }
        }
        return outcome
    }
}
