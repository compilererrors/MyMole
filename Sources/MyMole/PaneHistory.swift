import SwiftUI

/// The panes visited, for Back and Forward as in a browser: leaving a pane
/// puts it on the back list, and a visit made from somewhere earlier in the
/// list drops what lay ahead of it.
struct PaneHistory: Equatable {
    /// Far enough back for any session; older visits fall off the end.
    static let limit = 50

    private(set) var back: [Pane] = []
    private(set) var forward: [Pane] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// A new visit away from `from`.
    mutating func left(_ from: Pane) {
        if back.last != from { back.append(from) }
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
    }

    /// The pane before `current`, which then lies ahead.
    mutating func goBack(from current: Pane) -> Pane? {
        guard let pane = back.popLast() else { return nil }
        forward.append(current)
        return pane
    }

    /// The pane `current` was left for by going back.
    mutating func goForward(from current: Pane) -> Pane? {
        guard let pane = forward.popLast() else { return nil }
        back.append(current)
        return pane
    }
}

/// Back and Forward at the leading edge of the window toolbar, before the
/// pane's title, on every pane.
struct PaneHistoryButtons: View {
    let app: AppModel

    var body: some View {
        ControlGroup {
            button(.back, symbol: "chevron.left")
            button(.forward, symbol: "chevron.right")
        }
        .controlGroupStyle(.navigation)
    }

    private func button(_ id: AppCommand.ID, symbol: String) -> some View {
        let c = app.command(id)
        let tip = c.blocker ?? [c.title, c.shortcutText.map { "(\($0))" }].compactMap(\.self).joined(separator: " ")
        return Button(action: c.perform) {
            Label(c.title, systemImage: symbol)
        }
        .help(tip)
        .disabled(c.blocker != nil)
    }
}

/// `PaneHistoryButtons` for the window's model, found in the environment
/// the main window sets; nothing outside it.
struct PaneHistoryControls: View {
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        if let app { PaneHistoryButtons(app: app) }
    }
}
