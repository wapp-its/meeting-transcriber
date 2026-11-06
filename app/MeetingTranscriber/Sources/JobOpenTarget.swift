import Foundation

/// Where a finished job's Open action should go, as
/// `resolve(forEntry:preferNotion:)` decides it.
///
/// A Notion export leaves the local protocol file absent when the user chose
/// "skip local markdown on success", so the page URL is the only usable target
/// for those jobs. The preference is explicit rather than inferred from the URL
/// alone: turning Notion export off should go back to opening the local file.
enum JobOpenTarget: Equatable {
    case notion(URL)
    case file(URL)

    var url: URL {
        switch self {
        case let .notion(url), let .file(url): url
        }
    }

    /// The per-job menu row stays short; the Notion case says where it goes.
    var jobActionLabel: String {
        switch self {
        case .notion: "Open in Notion"
        case .file: "Open"
        }
    }

    var lastNotesLabel: String {
        switch self {
        case .notion: "Open Last Notes in Notion"
        case .file: "Open Last Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .notion: "arrow.up.right.square"
        case .file: "doc.text"
        }
    }
}
