// Which app a meeting-notes template opens in, the Open With list, and the words
// the templates section and the New Template window use for both. Pure values,
// so the choices are tested without an app, a window or a file.

import Foundation

/// The app Edit and a newly created template open in: the one last chosen under
/// Open With or Other…, else the Mac's default app for Markdown files.
enum TemplateEditor: Equatable {
    case app(TemplateEditorApp)
    /// The remembered app is no longer installed: the file is shown in Finder
    /// and the app is forgotten.
    case missing(bundleIdentifier: String)
    /// Nothing is remembered and no app opens Markdown files: the file is shown
    /// in Finder.
    case noApp

    /// The remembered app is looked up by its bundle identifier alone, never in
    /// the Markdown list, so an app picked under Other… that macOS does not
    /// offer for Markdown files stays the editor.
    static func resolve(
        remembered: String?,
        installedApp: (String) -> TemplateEditorApp?,
        defaultApp: () -> TemplateEditorApp?,
    ) -> Self {
        if let remembered {
            return installedApp(remembered).map { .app($0) } ?? .missing(bundleIdentifier: remembered)
        }
        return defaultApp().map { .app($0) } ?? .noApp
    }

    /// The name the menu, the help text and the window's note give the editor;
    /// nil when templates are shown in Finder. A missing app has no name left
    /// to ask for, so its bundle identifier stands in, as in
    /// `MicInputDetector.appDisplayName`.
    var appName: String? {
        switch self {
        case let .app(app): app.name
        case let .missing(bundleIdentifier): bundleIdentifier
        case .noApp: nil
        }
    }

    /// The help text under the templates section.
    var helpText: String {
        let opening = if let appName {
            "Edit opens one in \(appName). To use another app, click the arrow beside Edit and choose Open With; "
                + "the app remembers your choice."
        } else {
            "Edit shows one in Finder, as no app is set to open Markdown files. To use an app, click the arrow "
                + "beside Edit and choose Open With; the app remembers your choice."
        }
        return "Templates are Markdown files in the templates folder. \(opening) {LANGUAGE}, {MEETING_DATE} and "
            + "{MEETING_TIME} are filled in for every template. Background info entered for a meeting is added to "
            + "the prompt automatically."
    }

    /// The New Template window's note for the name typed so far.
    func newTemplateNote(name typed: String) -> String {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = name.isEmpty ? "a Markdown file" : "“\(name).md”"
        let created = "Creates \(file) in the templates folder from the built-in template"
        guard let appName else {
            return "\(created) and shows it in Finder, as no app is set to open Markdown files. To use an app, "
                + "click the arrow beside Edit and choose Open With."
        }
        return "\(created) and opens it in \(appName), where you change and save it. To use another app, click "
            + "the arrow beside Edit and choose Open With."
    }
}

/// One line of a template's Open With submenu.
enum TemplateOpenWithEntry: Hashable {
    case app(TemplateEditorApp, title: String)
    case separator
    case other

    static let otherTitle = "Other…"

    /// The default app first, marked "(default)", then the other apps macOS
    /// offers by name, each app once, then "Other…".
    static func entries(defaultApp: TemplateEditorApp?, offered: [TemplateEditorApp]) -> [Self] {
        var apps: [Self] = []
        var listed: Set<String> = []
        if let defaultApp {
            apps.append(.app(defaultApp, title: "\(defaultApp.name) (default)"))
            listed.insert(defaultApp.bundleIdentifier)
        }
        var others: [TemplateEditorApp] = []
        for app in offered where listed.insert(app.bundleIdentifier).inserted {
            others.append(app)
        }
        others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        apps += others.map { .app($0, title: $0.name) }
        return apps.isEmpty ? [.other] : apps + [.separator, .other]
    }
}

/// Why a template was shown in Finder instead of opened, and the orange line
/// under New Template… that says so.
enum TemplateOpenFailure: Equatable {
    case couldNotOpen(app: String)
    case notFound(app: String)
    case noApp

    /// The line once Finder shows `file` (a file name, extension included).
    func shownInFinder(file: String) -> String {
        switch self {
        case let .couldNotOpen(app):
            "\(app) could not open “\(file)”, so it is shown in Finder. "
                + "Open it from there with any app, or choose another app under Open With."

        case let .notFound(app):
            "\(app) was not found, so “\(file)” is shown in Finder. "
                + "Open it from there with any app, or choose another app under Open With."

        case .noApp:
            "No app is set to open Markdown files, so “\(file)” is shown in Finder. "
                + "Open it from there with any app, or choose an app under Open With."
        }
    }

    /// The line when Finder could not show `file` either, naming Finder's error.
    func notShown(file: String, error: String) -> String {
        switch self {
        case let .couldNotOpen(app):
            "\(app) could not open “\(file)”, and Finder could not show it either: \(error)"

        case let .notFound(app):
            "\(app) was not found, and Finder could not show “\(file)” either: \(error)"

        case .noApp:
            "No app is set to open Markdown files, and Finder could not show “\(file)” either: \(error)"
        }
    }
}
