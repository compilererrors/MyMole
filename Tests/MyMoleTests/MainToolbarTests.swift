import AppKit
import SwiftUI
import Testing

@testable import MyMole

/// The main window's AppKit toolbar: a pane's tools become native items,
/// clicks reach the pane, and a chrome that comes again unchanged leaves
/// every item as it was.
@MainActor @Suite(.serialized)
struct MainToolbarTests {
    private final class Box {
        var ran: [String] = []
        var isOn = false
        var tab = 0
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: window.contentView!.bounds)
        split.isVertical = true
        split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 700)))
        split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 870, height: 700)))
        window.contentView = split
        return window
    }

    private func chrome(_ box: Box, subtitle: String = "Synthetic") -> PaneChrome {
        let isOn = Binding(get: { box.isOn }, set: { box.isOn = $0 })
        let tab = Binding(get: { box.tab }, set: { box.tab = $0 })
        return PaneChrome(title: "Pane", subtitle: subtitle, tools: [
            .choice("test.tab", "Section", selection: tab, options: [(0, "One"), (1, "Two")]),
            .button("test.run", "Run", symbol: "arrow.clockwise", help: "Run it") { box.ran.append("run") },
            .toggle("test.flag", "Flag", symbol: "flag", help: "Flag it", isOn: isOn),
            .menu("test.menu", "More", symbol: "ellipsis.circle", help: "More", primary: { box.ran.append("primary") }) {
                Button("Item") { box.ran.append("item") }
            },
        ])
    }

    @Test func aPanesToolsBecomeNativeItemsThatReachThePane() throws {
        let toolbar = MainToolbar()
        let window = window()
        defer { window.close() }
        let box = Box()
        toolbar.attach(to: window)
        toolbar.show(chrome(box), environment: EnvironmentValues())
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        #expect(window.toolbar === toolbar.toolbar)
        let ids = toolbar.toolbar.items.map(\.itemIdentifier.rawValue)
        #expect(ids.contains("pane.title") && ids.contains("pane.history"))
        #expect(ids.filter { $0.hasPrefix("tool.") } == ["tool.test.tab", "tool.test.run", "tool.test.flag", "tool.test.menu"])
        #expect(toolbar.toolbar.centeredItemIdentifiers == [.init("tool.test.tab")])
        let run = try #require(toolbar.toolbar.items.first { $0.itemIdentifier.rawValue == "tool.test.run" })
        _ = run.target?.perform(run.action, with: run)
        let menu = try #require(toolbar.toolbar.items.first { $0.itemIdentifier.rawValue == "tool.test.menu" } as? NSMenuToolbarItem)
        _ = menu.target?.perform(menu.action, with: menu)
        #expect(box.ran == ["run", "primary"])
        let tab = try #require(toolbar.toolbar.items.first { $0.itemIdentifier.rawValue == "tool.test.tab" } as? NSToolbarItemGroup)
        tab.selectedIndex = 1
        _ = tab.target?.perform(tab.action, with: tab)
        #expect(box.tab == 1)
    }

    /// A pane being taken away may be drawn once more after the next one
    /// came in; its tools must not come back.
    @Test func onlyThePaneShownLastSetsTheToolbar() throws {
        let toolbar = MainToolbar()
        let window = window()
        defer { window.close() }
        toolbar.attach(to: window)
        let leaving = NSView(), shown = NSView()
        toolbar.enter(leaving)
        toolbar.enter(shown)
        toolbar.show(PaneChrome(title: "Shown", subtitle: "", tools: [
            .button("shown.run", "Run", symbol: "play", help: "Run") {},
        ]), environment: EnvironmentValues(), from: shown)
        toolbar.show(PaneChrome(title: "Leaving", subtitle: "", tools: [
            .button("leaving.run", "Run", symbol: "play", help: "Run") {},
        ]), environment: EnvironmentValues(), from: leaving)
        toolbar.leave(leaving)
        let ids = toolbar.toolbar.items.map(\.itemIdentifier.rawValue)
        #expect(ids.contains("tool.shown.run") && !ids.contains("tool.leaving.run"))
        #expect(window.title == "Shown")
    }

    @Test func theSidebarButtonHidesAndShowsTheSidebar() throws {
        let toolbar = MainToolbar()
        let window = window()
        defer { window.close() }
        var toggled = 0
        toolbar.toggleSidebar = { toggled += 1 }
        toolbar.attach(to: window)
        let button = try #require(toolbar.toolbar.items.first { $0.itemIdentifier.rawValue == "pane.sidebar" })
        _ = button.target?.perform(button.action, with: button)
        #expect(toggled == 1)
    }

    @Test func theSameChromeAgainChangesNoItem() throws {
        let toolbar = MainToolbar()
        let window = window()
        defer { window.close() }
        let box = Box()
        toolbar.attach(to: window)
        toolbar.show(chrome(box), environment: EnvironmentValues())
        let before = toolbar.toolbar.items.map(ObjectIdentifier.init)
        toolbar.show(chrome(box, subtitle: "Synthetic, later"), environment: EnvironmentValues())
        #expect(toolbar.toolbar.items.map(ObjectIdentifier.init) == before)
        box.isOn = true
        toolbar.show(chrome(box), environment: EnvironmentValues())
        let flag = try #require(toolbar.toolbar.items.first { $0.itemIdentifier.rawValue == "tool.test.flag" } as? NSToolbarItemGroup)
        #expect(flag.isSelected(at: 0))
        #expect(toolbar.toolbar.items.map(ObjectIdentifier.init) == before)
    }
}
