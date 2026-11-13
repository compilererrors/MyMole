import AppKit
import SwiftUI

/// One control in a pane's toolbar. Panes describe their tools with these;
/// `MainToolbar` draws them with AppKit's own toolbar items. SwiftUI toolbar
/// items are measured again and attached to the window again on every
/// layout of the toolbar, which is every frame of a window or divider
/// resize; AppKit items only move.
struct PaneTool {
    enum Kind {
        case button(() -> Void)
        case toggle(isOn: Bool, set: (Bool) -> Void)
        /// A segmented choice, centred over the pane.
        case choice(titles: [String], selected: Int, set: (Int) -> Void)
        /// A pull-down menu of SwiftUI menu content; with a primary action,
        /// a click runs it and the arrow beside it opens the menu.
        case menu(primary: (() -> Void)?, content: () -> AnyView)
    }

    let id: String
    let title: String
    let symbol: String
    let help: String
    var enabled = true
    let kind: Kind

    var isChoice: Bool { if case .choice = kind { true } else { false } }

    static func button(_ id: String, _ title: LocalizedStringResource, symbol: String, help: LocalizedStringResource,
                       enabled: Bool = true, action: @escaping () -> Void) -> PaneTool {
        PaneTool(id: id, title: String(localized: title), symbol: symbol, help: String(localized: help), enabled: enabled, kind: .button(action))
    }

    static func toggle(_ id: String, _ title: LocalizedStringResource, symbol: String, help: LocalizedStringResource,
                       isOn: Binding<Bool>) -> PaneTool {
        PaneTool(id: id, title: String(localized: title), symbol: symbol, help: String(localized: help),
                 kind: .toggle(isOn: isOn.wrappedValue, set: { isOn.wrappedValue = $0 }))
    }

    static func choice<Value: Hashable>(_ id: String, _ title: LocalizedStringResource, selection: Binding<Value>,
                                        options: [(Value, String)]) -> PaneTool {
        let values = options.map(\.0)
        return PaneTool(id: id, title: String(localized: title), symbol: "", help: String(localized: title),
                        kind: .choice(titles: options.map(\.1), selected: values.firstIndex(of: selection.wrappedValue) ?? -1,
                                      set: { i in if values.indices.contains(i) { selection.wrappedValue = values[i] } }))
    }

    static func menu<Content: View>(_ id: String, _ title: LocalizedStringResource, symbol: String, help: LocalizedStringResource,
                                    enabled: Bool = true, primary: (() -> Void)? = nil,
                                    @ViewBuilder content: @escaping () -> Content) -> PaneTool {
        PaneTool(id: id, title: String(localized: title), symbol: symbol, help: String(localized: help), enabled: enabled,
                 kind: .menu(primary: primary, content: { AnyView(content()) }))
    }
}

@resultBuilder
enum PaneToolsBuilder {
    static func buildExpression(_ tool: PaneTool) -> [PaneTool] { [tool] }
    static func buildExpression(_ tools: [PaneTool]) -> [PaneTool] { tools }
    static func buildBlock(_ parts: [PaneTool]...) -> [PaneTool] { parts.flatMap(\.self) }
    static func buildOptional(_ part: [PaneTool]?) -> [PaneTool] { part ?? [] }
    static func buildEither(first part: [PaneTool]) -> [PaneTool] { part }
    static func buildEither(second part: [PaneTool]) -> [PaneTool] { part }
    static func buildArray(_ parts: [[PaneTool]]) -> [PaneTool] { parts.flatMap(\.self) }
}

/// What the window's toolbar shows for the pane on screen.
struct PaneChrome {
    let title: String
    let subtitle: String
    let tools: [PaneTool]
}

extension View {
    /// Puts Back and Forward, then the pane's title and subtitle, at the
    /// leading edge of the window toolbar and its tools at the trailing
    /// edge, the same on every pane.
    func paneToolbar(_ title: LocalizedStringResource, subtitle: LocalizedStringResource,
                     @PaneToolsBuilder tools: () -> [PaneTool] = { [] }) -> some View {
        let chrome = PaneChrome(title: String(localized: title), subtitle: String(localized: subtitle), tools: tools())
        return background(PaneChromeSink(chrome: chrome)).navigationTitle(Text(title))
    }
}

/// Hands the pane's chrome to the window's toolbar each time the pane is
/// drawn anew; it takes no room and draws nothing. Only the pane that came
/// into the window last is heard: one being taken away may still be drawn
/// once more, and its tools would come back.
private struct PaneChromeSink: NSViewRepresentable {
    let chrome: PaneChrome

    final class Sink: NSView {
        var chrome: PaneChrome?
        var environment = EnvironmentValues()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                MainToolbar.shared.leave(self)
            } else {
                MainToolbar.shared.enter(self)
                if let chrome { MainToolbar.shared.show(chrome, environment: environment, from: self) }
            }
        }
    }

    func makeNSView(context: Context) -> Sink {
        let view = Sink()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Sink, context: Context) {
        view.chrome = chrome
        view.environment = context.environment
        MainToolbar.shared.show(chrome, environment: context.environment, from: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Sink, context: Context) -> CGSize? { .zero }
}

/// The main window, made by AppKit rather than by a SwiftUI scene: a scene's
/// window controller takes the window's toolbar back on every layout, and
/// this window's toolbar is AppKit's own (`MainToolbar`). SwiftUI draws the
/// whole content and bridges nothing: `MainToolbar` sets the window's
/// title from the pane's. The content is sized by the
/// window and never measured for it, so a resize lays the panes out once;
/// the window keeps its minimum size itself.
@MainActor
final class MainWindow {
    static var shared: MainWindow?
    let window: NSWindow

    init(app: AppModel) {
        let host = NSHostingController(rootView: AnyView(RootView(app: app).task { app.prefetchScans() }))
        host.sceneBridgingOptions = []
        host.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_240, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "MyMole"
        // The hosting view sits in a plain container: as the window's own
        // content view, it would set the window's frame again after every
        // layout of it, which laid the window out twice on each frame of a
        // resize.
        let container = NSViewController()
        container.view = NSView(frame: NSRect(x: 0, y: 0, width: 1_240, height: 800))
        container.addChild(host)
        host.view.frame = container.view.bounds
        host.view.autoresizingMask = [.width, .height]
        container.view.addSubview(host.view)
        window.contentViewController = container
        window.setContentSize(NSSize(width: 1_240, height: 800))
        MainToolbar.shared.attach(to: window)
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        // Saved when a resize or move ends, not with every frame of it: each
        // write to the defaults wakes every `@AppStorage` in the app, and the
        // window's root view and pane are drawn anew for it.
        let center = NotificationCenter.default
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveFrame() }
            })
        }
        // A move is reported while it goes on: saved once it has rested.
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pendingSave?.cancel()
                self?.pendingSave = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    if !Task.isCancelled { self?.saveFrame() }
                }
            }
        })
    }

    static let frameName = "MyMole.main"
    private var observers: [NSObjectProtocol] = []
    private var pendingSave: Task<Void, Never>?

    private func saveFrame() {
        guard !window.inLiveResize else { return }
        window.saveFrame(usingName: Self.frameName)
    }

    func show() { window.makeKeyAndOrderFront(nil) }
}

/// Puts `MainToolbar` on the window this view is in, with Back and Forward
/// as the model has them.
struct MainToolbarHost: NSViewRepresentable {
    let app: AppModel
    let back: AppCommand
    let forward: AppCommand
    /// Hides or shows the sidebar.
    let toggleSidebar: () -> Void

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainToolbar.shared.attach(to: window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        MainToolbar.shared.history(back: back, forward: forward)
        MainToolbar.shared.toggleSidebar = toggleSidebar
        if let window = view.window { MainToolbar.shared.attach(to: window) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Probe, context: Context) -> CGSize? { .zero }
}

/// The main window's toolbar, built from AppKit items: the sidebar button,
/// Back and Forward, the pane's title, its centred choices and its tools.
/// A pane's chrome arriving again changes only what it shows differently.
@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate, NSMenuDelegate {
    static let shared = MainToolbar()

    private static let sidebar = NSToolbarItem.Identifier("pane.sidebar")
    private static let history = NSToolbarItem.Identifier("pane.history")
    private static let title = NSToolbarItem.Identifier("pane.title")
    private static let tracking = NSToolbarItem.Identifier.sidebarTrackingSeparator

    /// Its own identifier: toolbars that share one keep their items in step.
    let toolbar = NSToolbar(identifier: "MyMole.main.\(UUID().uuidString)")
    private weak var window: NSWindow?
    private var chrome = PaneChrome(title: "", subtitle: "", tools: [])
    private var environment = EnvironmentValues()
    private var tools: [NSToolbarItem.Identifier: PaneTool] = [:]
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var shown: [NSToolbarItem.Identifier: Shown] = [:]
    private var commands: (back: AppCommand, forward: AppCommand)?
    private var menuOwners: [ObjectIdentifier: NSToolbarItem.Identifier] = [:]
    private weak var activeSink: NSView?
    var toggleSidebar: () -> Void = {}

    /// What an item last showed, so an unchanged chrome changes nothing.
    private struct Shown: Equatable {
        var title: String
        var symbol: String
        var help: String
        var enabled: Bool
        var state: Int
        var titles: [String]
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private lazy var titleView: NSView = {
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.maximumNumberOfLines = 1
        }
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        return stack
    }()

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }

    // MARK: Window

    /// The sidebar at its narrowest beside the narrowest pane.
    static let minimumSize = NSSize(width: 980, height: 620)

    func attach(to window: NSWindow) {
        guard self.window !== window || window.toolbar !== toolbar else { return }
        self.window = window
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.contentMinSize = Self.minimumSize
        window.toolbar = toolbar
    }

    // MARK: Chrome

    func history(back: AppCommand, forward: AppCommand) {
        commands = (back, forward)
        guard let group = items[Self.history] as? NSToolbarItemGroup, group.subitems.count == 2 else { return }
        for (item, c) in zip(group.subitems, [back, forward]) {
            let tip = c.blocker ?? [c.title, c.shortcutText.map { "(\($0))" }].compactMap(\.self).joined(separator: " ")
            if item.isEnabled != (c.blocker == nil) { item.isEnabled = c.blocker == nil }
            if item.toolTip != tip { item.toolTip = tip }
        }
    }

    /// A pane's chrome sink has come into a window: its chrome is the one shown.
    func enter(_ sink: NSView) { activeSink = sink }

    func leave(_ sink: NSView) { if activeSink === sink { activeSink = nil } }

    /// The chrome from a pane's sink, if that pane is the one shown.
    func show(_ chrome: PaneChrome, environment: EnvironmentValues, from sink: NSView) {
        guard activeSink === sink else { return }
        show(chrome, environment: environment)
    }

    func show(_ chrome: PaneChrome, environment: EnvironmentValues) {
        self.chrome = chrome
        self.environment = environment
        if titleLabel.stringValue != chrome.title { titleLabel.stringValue = chrome.title }
        // The window's own title, for the Window menu and Mission Control.
        if let window, !chrome.title.isEmpty, window.title != chrome.title { window.title = chrome.title }
        if subtitleLabel.stringValue != chrome.subtitle {
            subtitleLabel.stringValue = chrome.subtitle
            subtitleLabel.toolTip = chrome.subtitle
        }
        tools = Dictionary(chrome.tools.map { (Self.identifier($0), $0) }, uniquingKeysWith: { first, _ in first })
        let wanted = chrome.tools.map(Self.identifier)
        let centred = Set(chrome.tools.filter(\.isChoice).map(Self.identifier))
        if toolbar.centeredItemIdentifiers != centred { toolbar.centeredItemIdentifiers = centred }
        let current = toolbar.items.map(\.itemIdentifier).filter { $0.rawValue.hasPrefix("tool.") }
        if current != wanted {
            for index in toolbar.items.indices.reversed() where toolbar.items[index].itemIdentifier.rawValue.hasPrefix("tool.") {
                toolbar.removeItem(at: index)
            }
            for id in items.keys where id.rawValue.hasPrefix("tool.") && !wanted.contains(id) {
                items[id] = nil
                shown[id] = nil
            }
            for id in wanted where !toolbar.items.contains(where: { $0.itemIdentifier == id }) {
                toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count)
            }
        }
        for tool in chrome.tools { update(Self.identifier(tool), with: tool) }
    }

    private static func identifier(_ tool: PaneTool) -> NSToolbarItem.Identifier { .init("tool.\(tool.id)") }

    private static func image(_ symbol: String, _ title: String) -> NSImage? {
        symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }

    private func update(_ id: NSToolbarItem.Identifier, with tool: PaneTool) {
        guard let item = items[id] else { return }
        var state = 0, titles: [String] = []
        switch tool.kind {
        case .toggle(let isOn, _): state = isOn ? 1 : 0
        case .choice(let t, let selected, _): state = selected; titles = t
        case .menu, .button: break
        }
        let now = Shown(title: tool.title, symbol: tool.symbol, help: tool.help, enabled: tool.enabled, state: state, titles: titles)
        guard shown[id] != now else { return }
        let before = shown[id]
        shown[id] = now
        item.label = tool.title
        item.paletteLabel = tool.title
        item.toolTip = tool.help
        item.isEnabled = tool.enabled
        if before?.symbol != tool.symbol || before?.title != tool.title { item.image = Self.image(tool.symbol, tool.title) }
        if let group = item as? NSToolbarItemGroup {
            group.subitems.forEach { $0.isEnabled = tool.enabled }
            switch tool.kind {
            case .toggle(let isOn, _):
                group.subitems.first?.image = Self.image(tool.symbol, tool.title)
                group.subitems.first?.label = tool.title
                group.setSelected(isOn, at: 0)
            case .choice(let t, let selected, _):
                if before?.titles != t {
                    // Another set of choices on the same place: a fresh control.
                    items[id] = nil
                    shown[id] = nil
                    if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == id }) {
                        toolbar.removeItem(at: index)
                        toolbar.insertItem(withItemIdentifier: id, at: index)
                        update(id, with: tool)
                    }
                    return
                }
                group.selectedIndex = selected
            default: break
            }
        }
    }

    // MARK: Actions

    @objc private func runTool(_ sender: NSToolbarItem) {
        guard let tool = tools[sender.itemIdentifier] else { return }
        switch tool.kind {
        case .button(let action): action()
        case .menu(let primary?, _): primary()
        case .toggle(_, let set):
            let isOn = (sender as? NSToolbarItemGroup)?.isSelected(at: 0) ?? false
            set(isOn)
        case .choice(_, _, let set):
            set((sender as? NSToolbarItemGroup)?.selectedIndex ?? -1)
        case .menu(nil, _): break
        }
    }

    @objc private func sidebarPressed(_ sender: NSToolbarItem) { toggleSidebar() }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        guard let commands else { return }
        (sender.selectedIndex == 0 ? commands.back : commands.forward).perform()
    }

    /// A menu's content is made as it opens, from the pane's latest
    /// chrome, never while the toolbar is laid out.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let id = menuOwners[ObjectIdentifier(menu)], let tool = tools[id], case .menu(_, let content) = tool.kind,
              let hosting = menu as? NSHostingMenu<AnyView> else { return }
        hosting.rootView = AnyView(content().environment(\.self, environment))
        hosting.update()
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebar, Self.tracking, Self.history, Self.title, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + chrome.tools.map(Self.identifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case Self.sidebar:
            item = NSToolbarItem(itemIdentifier: id)
            item.label = String(localized: "Sidebar")
            item.paletteLabel = item.label
            item.toolTip = String(localized: "Hide or show the sidebar (⌃⌘S)")
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
            item.isBordered = true
            item.target = self
            item.action = #selector(sidebarPressed(_:))
        case Self.history:
            let group = NSToolbarItemGroup(itemIdentifier: id, images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: String(localized: "Back"))!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: String(localized: "Forward"))!,
            ], selectionMode: .momentary, labels: [String(localized: "Back"), String(localized: "Forward")],
               target: self, action: #selector(navigate(_:)))
            group.controlRepresentation = .expanded
            group.autovalidates = false
            item = group
        case Self.title:
            item = NSToolbarItem(itemIdentifier: id)
            item.view = titleView
            item.isBordered = false
            item.visibilityPriority = .high
        case Self.tracking:
            guard let split = window.flatMap({ Self.firstSplit(in: $0.contentView) }) else { return nil }
            item = NSTrackingSeparatorToolbarItem(identifier: id, splitView: split, dividerIndex: 0)
        default:
            guard let tool = tools[id] else { return nil }
            item = makeItem(id, for: tool)
            items[id] = item
            update(id, with: tool)
            return item
        }
        items[id] = item
        if id == Self.history, let commands { history(back: commands.back, forward: commands.forward) }
        return item
    }

    private func makeItem(_ id: NSToolbarItem.Identifier, for tool: PaneTool) -> NSToolbarItem {
        let item: NSToolbarItem
        switch tool.kind {
        case .button:
            item = NSToolbarItem(itemIdentifier: id)
            item.isBordered = true
        case .toggle:
            let group = NSToolbarItemGroup(itemIdentifier: id, images: [Self.image(tool.symbol, tool.title) ?? NSImage()],
                                           selectionMode: .selectAny, labels: [tool.title], target: self, action: #selector(runTool(_:)))
            group.controlRepresentation = .expanded
            item = group
        case .choice(let titles, _, _):
            let group = NSToolbarItemGroup(itemIdentifier: id, titles: titles, selectionMode: .selectOne, labels: titles,
                                           target: self, action: #selector(runTool(_:)))
            group.controlRepresentation = .expanded
            item = group
        case .menu(let primary, _):
            let menuItem = NSMenuToolbarItem(itemIdentifier: id)
            let menu = NSHostingMenu<AnyView>(rootView: AnyView(EmptyView()))
            menu.delegate = self
            menuOwners[ObjectIdentifier(menu)] = id
            menuItem.menu = menu
            menuItem.showsIndicator = true
            if primary == nil { menuItem.action = nil } else { menuItem.target = self; menuItem.action = #selector(runTool(_:)) }
            item = menuItem
        }
        if item.target == nil, item.action == nil, case .button = tool.kind {
            item.target = self
            item.action = #selector(runTool(_:))
        }
        item.autovalidates = false
        return item
    }

    private static func firstSplit(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for child in view.subviews { if let split = firstSplit(in: child) { return split } }
        return nil
    }
}
