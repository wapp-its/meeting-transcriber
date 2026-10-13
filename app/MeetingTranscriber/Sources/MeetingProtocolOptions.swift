import Foundation
import Observation

/// The template and background info one recording's protocol is made with, as
/// chosen in an options window. Nil wherever a recording starts without that
/// window: its job then gets the default template, stamped when it is queued,
/// and no background.
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
    var template: ProtocolTemplateID
    /// As typed; `options` normalises it.
    var background: String

    init(template: ProtocolTemplateID = .builtIn, background: String = "") {
        self.template = template
        self.background = background
    }

    var options: MeetingProtocolOptions {
        MeetingProtocolOptions(template: template, rawBackground: background)
    }

    /// How every opening of a window starts: the default template, no background.
    func reset(to template: ProtocolTemplateID) {
        self.template = template
        background = ""
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
        #endif

        case .openAICompatible: endpoint(openAIEndpoint)

        case .none: .off
        }
    }

    /// The sentence an options window shows.
    var notice: String {
        switch self {
        case let .remote(name):
            "Background info is sent with the transcript to \(name) to write the protocol."

        case let .local(host):
            "Background info stays on this Mac: it goes with the transcript to the local model at \(host)."

        case .off:
            "Protocol generation is off (Settings → Output), so the template and background info are not used."
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

/// Everything an options form shows besides the draft, read in one go from the
/// settings and the templates folder.
struct ProtocolOptionsContext: Equatable {
    /// The built-in first, then the folder's templates in Finder's order.
    let templates: [ProtocolTemplateID]
    /// The effective default, spelt as the folder lists it.
    let defaultTemplate: ProtocolTemplateID
    let destination: ProtocolDestination
    let recordOnly: Bool
}

extension ProtocolOptionsContext {
    init(settings: AppSettings, store: ProtocolTemplateStore) {
        let names = store.names()
        templates = [.builtIn] + names.map { .file(name: $0) }
        defaultTemplate = Self.listed(store.effectiveDefault(settings.defaultProtocolTemplate), in: names)
        destination = .resolve(provider: settings.protocolProvider, openAIEndpoint: settings.openAIEndpoint)
        recordOnly = settings.recordOnly
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
