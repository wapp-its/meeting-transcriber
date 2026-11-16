// Shows the open recording questions in the prompt panel below the menu bar
// icon (issue #99): renders `PromptWindowContent`'s decision and answers
// through the calls a notification tap uses.
import AppKit
import SwiftUI

/// The calls the window's answers go through: in the app
/// `AppState.answerConsentQuestion(_:answer:)` and
/// `AppState.answerMeetingEndQuestion(_:answer:)`. Each returns whether its
/// question was still open and took the answer.
@MainActor
struct PromptWindowAnswers {
    var consent: (ConsentQuestion, ConsentAnswer) -> Bool
    var meetingEnd: (MeetingEndQuestion, MeetingEndAnswer) -> Bool
}

/// Owns the one `PromptPanel` and the ids closed with ✕ or answered from the
/// window. `update()` renders the input read at that moment: the panel shows
/// the decision's items below the menu bar icon, placed again whenever it is
/// shown or its size changes, and is ordered out when there is nothing to
/// show. While a countdown shows, a timer renders again every second for the
/// time left, which feeds nothing back into the loop.
@MainActor
final class PromptWindowController {
    private let input: () -> PromptWindowInput
    private let answers: PromptWindowAnswers
    private let now: () -> Date
    /// Where a window of the given size goes; nil keeps it where it is.
    private let origin: @MainActor (CGSize) -> CGPoint?

    /// What the window shows, as last rendered.
    private(set) var items: [PromptWindowItem] = []
    private(set) var panel: PromptPanel?
    /// The size the panel was last placed for. Not the panel's frame: the
    /// hosting view resizes the panel to new content by itself, before the
    /// controller compares.
    private var placedSize: CGSize?
    private var hidden: Set<PromptWindowItem.QuestionID> = []
    private var timer: Timer?

    init(
        input: @escaping () -> PromptWindowInput,
        answers: PromptWindowAnswers,
        now: @escaping () -> Date = { Date() },
        origin: @escaping @MainActor (CGSize) -> CGPoint? = PromptWindowController.originBelowMenuBarIcon,
    ) {
        self.input = input
        self.answers = answers
        self.now = now
        self.origin = origin
    }

    isolated deinit {
        timer?.invalidate()
    }

    /// Whether the time left is refreshed every second.
    var isCountingDown: Bool {
        timer != nil
    }

    /// Render what the window shows now. The input is read here, not handed
    /// in, so a setting switched off before the observer ran never shows the
    /// window. Ids of questions no longer open are forgotten: ids are never
    /// reused.
    func update() {
        let input = input()
        hidden.formIntersection(input.questions.map(\.id))
        items = PromptWindowContent.items(for: input, hiding: hidden)
        if items.isEmpty {
            panel?.orderOut(nil)
        } else {
            show(items)
        }
        let countdownShows = items.contains { item in
            if case .meetingEnd = item { true } else { false }
        }
        setCountingDown(countdownShows)
    }

    /// A click in the window. An answer the app took hides its question at
    /// once, without waiting for the loop's next poll; one it refused (the
    /// question is not open, or not yet) leaves it. ✕ answers nothing.
    private func perform(_ action: PromptWindowAction) {
        switch action {
        case let .answerConsent(question, answer):
            if answers.consent(question, answer) { hidden.insert(.consent(question.id)) }

        case let .answerMeetingEnd(question, answer):
            if answers.meetingEnd(question, answer) { hidden.insert(.meetingEnd(question.id)) }

        case let .hide(id):
            hidden.insert(id)
        }
        update()
    }

    private func show(_ items: [PromptWindowItem]) {
        let panel = panel ?? PromptPanel(size: CGSize(width: PromptWindowView.width, height: 1))
        self.panel = panel
        panel.host.rootView = AnyView(PromptWindowView(items: items, now: now()) { [weak self] action in
            self?.perform(action)
        })
        let size = panel.host.fittingSize
        if !panel.isVisible || size != placedSize {
            panel.setFrame(NSRect(origin: origin(size) ?? panel.frame.origin, size: size), display: true)
            panel.invalidateShadow()
            placedSize = size
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func setCountingDown(_ on: Bool) {
        guard on != isCountingDown else { return }
        guard on else {
            timer?.invalidate()
            timer = nil
            return
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // Common modes, so the time left keeps counting while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Below the menu bar icon, or at the top right below the menu bar when
    /// the icon's frame cannot be read (`PromptWindowPlacement`).
    static func originBelowMenuBarIcon(size: CGSize) -> CGPoint? {
        let menuBarScreen = NSScreen.screens.first
        return PromptWindowPlacement.origin(
            iconFrame: MenuBarIconFrame.frame(in: NSApp, menuBarScreen: menuBarScreen?.frame),
            screens: NSScreen.screens.map(CaptionScreen.init),
            size: size,
            menuBarHeight: menuBarHeight(
                of: menuBarScreen.map(CaptionScreen.init),
                safeAreaTop: menuBarScreen?.safeAreaInsets.top ?? 0,
                statusBarThickness: NSStatusBar.system.thickness,
            ),
        )
    }

    /// The menu bar's height on `screen`: what it covers while it shows, else
    /// at least the notch (`safeAreaTop`) and the status bar's thickness.
    /// `NSStatusBar.system.thickness` alone reads 22 pt where a notched
    /// screen's menu bar is 33, which would put the fallback window into it.
    static func menuBarHeight(of screen: CaptionScreen?, safeAreaTop: CGFloat, statusBarThickness: CGFloat) -> CGFloat {
        let shown = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        return max(shown, safeAreaTop, statusBarThickness)
    }
}
