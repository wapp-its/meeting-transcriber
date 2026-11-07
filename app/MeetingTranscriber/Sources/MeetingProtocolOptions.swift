import Foundation
import Observation

/// The template and background info one recording's protocol is made with, as
/// chosen in an options window. Nil wherever a recording starts without that
/// window: its job then gets the template the rules pick for its title (the
/// default when none matches), stamped when it is queued, and no background.
struct MeetingProtocolOptions: Equatable {
    let template: ProtocolTemplateID
    /// Trimmed; nil when blank, so "no background" has one representation.
    let background: String?

    init(template: ProtocolTemplateID, rawBackground: String) {
        self.template = template
        let trimmed = rawBackground.trimmingCharacters(in: .whitespacesAndNewlines)
        background = trimmed.isEmpty ? nil : trimmed
    }
}

/// What an options form holds while its window is open. A reference type so a
/// view test reads back the object the controls write to (as with
/// `SpeakerNamingRowState`, CLAUDE.md, GUI Testing, rung 2).
@Observable
@MainActor
final class ProtocolOptionsDraft {
    /// Written by the picker only through `chooseByHand`.
    var template: ProtocolTemplateID
    /// As typed; `options` normalises it.
    var background: String
    /// The line under the template picker; nil shows none, as with no rules
    /// and in the regenerate sheet, which never follows the rules (spec A6).
    private(set) var line: TemplateChoiceLine?
    /// The user changed the template picker since the window opened. From then
    /// on the rules no longer move the selection.
    private(set) var chosenByHand = false

    init(template: ProtocolTemplateID = .builtIn, background: String = "") {
        self.template = template
        self.background = background
    }

    var options: MeetingProtocolOptions {
        MeetingProtocolOptions(template: template, rawBackground: background)
    }

    /// How every opening of a window starts: the default template, no
    /// background, no line, nothing chosen by hand.
    func reset(to template: ProtocolTemplateID) {
        self.template = template
        background = ""
        line = nil
        chosenByHand = false
    }

    /// The template picker's write. A pick that changes nothing is not a choice.
    func chooseByHand(_ template: ProtocolTemplateID) {
        guard template != self.template else { return }
        self.template = template
        chosenByHand = true
        if line != nil { line = .chosenByHand }
    }

    /// Selects what the rules pick for `title`, the title the recording would
    /// get (nil while the start dialog has nothing selected), and says why in
    /// the line. A template chosen by hand stays. With no rules, no line.
    func follow(_ choices: ProtocolTemplateChoices, title: String?) {
        guard !choices.rules.isEmpty else {
            line = nil
            return
        }
        guard !chosenByHand else {
            line = .chosenByHand
            return
        }
        guard let title else {
            template = choices.defaultTemplate
            line = .defaultUntilSourceChosen
            return
        }
        let choice = choices.choice(forTitle: title)
        template = choice.template
        line = switch choice.source {
        case let .rule(index, pattern): .rule(number: index + 1, pattern: pattern, title: title)
        case .defaultTemplate: .noRuleMatches(title: title)
        }
    }
}

/// The small line under the template picker of the start dialog and the
/// Record Meeting window, in the accepted mockup's wording. Carries the
/// meeting title, so it is shown only in windows off every RPC allowlist.
enum TemplateChoiceLine: Equatable {
    case rule(number: Int, pattern: String, title: String)
    case noRuleMatches(title: String)
    /// The start dialog before a source is selected.
    case defaultUntilSourceChosen
    case chosenByHand

    var text: String {
        switch self {
        case let .rule(number, pattern, title):
            "From rule \(number) (\(pattern)), matching the title “\(title)”."

        case let .noRuleMatches(title):
            "Default template: no rule matches the title “\(title)”."

        case .defaultUntilSourceChosen:
            "Default template until you choose what to record."

        case .chosenByHand:
            "Chosen by you. This recording uses it, whatever the rules say."
        }
    }
}

/// Where background info goes with the transcript, from the protocol provider
/// the settings name. A user-supplied command counts as remote, because the
/// app cannot tell where it sends the text (spec A9).
enum ProtocolDestination: Equatable {
    /// Protocol generation is off.
    case off
    /// An OpenAI-compatible endpoint on this Mac.
    case local(host: String)
    /// Anything else, named for the notice.
    case remote(name: String)

    static func resolve(provider: ProtocolProvider, openAIEndpoint: String) -> Self {
        // No `default`: a provider added later must decide where it sends the text.
        switch provider {
        #if !APPSTORE
            case .claudeCLI: .remote(name: "Anthropic (Claude)")

            case .codexCLI: .remote(name: "OpenAI (Codex)")

            case .customCommand: .remote(name: "the custom command set in Settings → Output")

            case .localModel: .local(host: "this Mac")
        #endif

        case .openAICompatible: endpoint(openAIEndpoint)

        case .none: .off
        }
    }

    /// The sentence an options window shows.
    var notice: String {
        switch self {
        case let .remote(name):
            "Background info is sent with the transcript to \(name) to write the meeting notes."

        case let .local(host):
            "Background info stays on this Mac: it goes with the transcript to the local model at \(host)."

        case .off:
            "Meeting notes generation is off (Settings → Output), so the template and background info are not used."
        }
    }

    /// Local only for a loopback host. An endpoint that does not parse is
    /// treated as remote rather than guessed at.
    private static func endpoint(_ endpoint: String) -> Self {
        guard let host = URL(string: endpoint)?.host(percentEncoded: false), !host.isEmpty else {
            return .remote(name: "the configured endpoint")
        }
        return isLoopback(host) ? .local(host: host) : .remote(name: host)
    }

    private static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered == "::1" { return true }
        let octets = lowered.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil } && octets.first == "127"
    }
}

/// Everything an options form shows besides the draft. The default template
/// is not part of it: the form only lists the templates, and each window
/// starts its draft from `ProtocolTemplateChoices.defaultTemplate`.
struct ProtocolOptionsContext: Equatable {
    /// The built-in first, then the folder's templates in Finder's order.
    let templates: [ProtocolTemplateID]
    let destination: ProtocolDestination
    let recordOnly: Bool
}

extension ProtocolOptionsContext {
    init(choices: ProtocolTemplateChoices, use: ProtocolOptionsUse) {
        self.init(
            templates: choices.templates,
            destination: use.destination,
            recordOnly: use.recordOnly,
        )
    }
}

/// What a window reads once, when it opens: the templates its form lists, the
/// default its draft starts from and the template rules. Every opening starts
/// from the effective default, and the folder is not listed again on every
/// redraw.
struct ProtocolTemplateChoices: Equatable {
    let templates: [ProtocolTemplateID]
    /// The effective default, spelt as the folder lists it.
    let defaultTemplate: ProtocolTemplateID
    var rules: [ProtocolTemplateRule] = []

    /// What the rules pick for `title` among the templates listed here.
    func choice(forTitle title: String) -> ProtocolTemplateRules.Choice {
        let names = templates.compactMap { id -> String? in
            if case let .file(name) = id { return name }
            return nil
        }
        return ProtocolTemplateRules.resolve(
            title: title, rules: rules, templateNames: names, defaultTemplate: defaultTemplate,
        )
    }
}

/// The part of the context a window reads on every redraw, so one left open
/// while Settings changes the provider or record-only mode says where the
/// background info goes now, and whether it is used at all. A read of the
/// observable settings during `body` is what makes the window redraw.
struct ProtocolOptionsUse: Equatable {
    let destination: ProtocolDestination
    let recordOnly: Bool
}

extension ProtocolOptionsUse {
    init(settings: AppSettings) {
        destination = .resolve(provider: settings.protocolProvider, openAIEndpoint: settings.openAIEndpoint)
        recordOnly = settings.recordOnly
    }
}

extension ProtocolTemplateChoices {
    init(settings: AppSettings, store: ProtocolTemplateStore) {
        let names = store.names()
        templates = [.builtIn] + names.map { .file(name: $0) }
        defaultTemplate = Self.listed(store.effectiveDefault(settings.defaultProtocolTemplate), in: names)
        rules = settings.protocolTemplateRules
    }

    /// `id` spelt as the folder lists it. After a Finder rename that changed
    /// only the case, the stored name still resolves on a case-insensitive
    /// volume but matches no listed name, which would blank the picker.
    private static func listed(_ id: ProtocolTemplateID, in names: [String]) -> ProtocolTemplateID {
        guard case let .file(name) = id, !names.contains(name),
              let listedName = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return id }
        return .file(name: listedName)
    }
}
