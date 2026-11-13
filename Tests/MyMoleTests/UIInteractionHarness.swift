import AppKit
import Observation
import SwiftUI
import Testing

@testable import MyMole

/// Windows belong to this test process. No global event injection, Accessibility
/// permission, System Events, live sampler, process reader or production stores.
@MainActor final class UIInteractionWindow {
    let window: NSWindow
    let host: NSView

    static func prepareApplication() {
        _ = NSApplication.shared
        NSApp.delegate = UIInteractionAppDelegate.shared
        NSApp.finishLaunching()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    init<V: View>(_ view: V, width: CGFloat = 1_100, height: CGFloat = 800) {
        Self.prepareApplication()
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        host = hosting
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Synthetic UI verification"
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
        settleTracking()
    }

    func settle() async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func settleTracking() {
        // SwiftPM's async-main drain must not be resumed from a nested AppKit
        // tracking loop. Finish this input turn synchronously before yielding.
        let deadline = Date(timeIntervalSinceNow: 0.03)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: deadline) }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func element(_ id: String) throws -> UIAccessibleNode {
        return try #require(elements().first { $0.accessibilityIdentifier() == id }, "Missing accessible control: \(id)")
    }

    func views<T: NSView>(_ type: T.Type) -> [T] {
        func visit(_ view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap(visit) }
        return visit(host)
    }

    func elements() -> [UIAccessibleNode] {
        var seen = Set<ObjectIdentifier>()
        func visit(_ node: Any, depth: Int) -> [UIAccessibleNode] {
            guard depth < 40, let object = node as? NSObject,
                  seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = ((object as AnyObject).accessibilityChildren?() ?? [])
                + ((object as AnyObject).accessibilityRows?() ?? [])
            let subviews: [Any] = (object as? NSView)?.subviews ?? []
            return [UIAccessibleNode(object: object)] + (children + subviews).flatMap { visit($0, depth: depth + 1) }
        }
        return ([host] + window.sheets.compactMap(\.contentView)).flatMap { visit($0, depth: 0) }
    }

    func point(_ id: String) throws -> NSPoint {
        let frame = try element(id).accessibilityFrame()
        try #require(frame.width > 0 && frame.height > 0, "Control must have real hit bounds")
        return window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
    }

    func event(_ type: NSEvent.EventType, at point: NSPoint, number: Int = 1, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       eventNumber: number, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
    }

    func click(_ id: String) throws {
        let p = try point(id)
        let target = try hitView(at: p)
        let local = target.convert(p, from: nil)
        try trackMouse(in: target, from: local, through: [local])
        settleTracking()
    }

    func drag(_ id: String, by delta: NSSize, cancel: Bool = false) throws {
        try reveal(id)
        let p = try point(id)
        let target = try hitView(at: p)
        try #require(target is HorizontalDragHandleView)
        try trackMouse(in: target, from: target.convert(p, from: nil), through: (1...8).map {
            target.convert(NSPoint(x: p.x + delta.width * CGFloat($0) / 8, y: p.y + delta.height * CGFloat($0) / 8), from: nil)
        }, cancel: cancel)
        settleTracking()
    }

    func reveal(_ id: String) throws {
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
        }
        guard let scroll = scrolls(host).first, let document = scroll.documentView else { return }
        let rect = window.convertFromScreen(try element(id).accessibilityFrame())
        document.scrollToVisible(document.convert(rect, from: nil))
        settleTracking()
    }

    private func hitView(at point: NSPoint) throws -> NSView {
        let content = try #require(window.contentView)
        let parentPoint = content.superview?.convert(point, from: nil) ?? point
        return try #require(content.hitTest(parentPoint), "Control must hit a real view in our window")
    }

    func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 characters: characters, charactersIgnoringModifiers: characters,
                                                 isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    /// NSSplitView and NSTableHeaderView run a native event-tracking loop.
    /// Queue only events for our window, with a bounded emergency release.
    func trackMouse(in view: NSView, from: NSPoint, through points: [NSPoint], clicks: Int = 1, cancel: Bool = false) throws {
        let end = try #require(points.last)
        let down = try event(.leftMouseDown, at: view.convert(from, to: nil), clicks: clicks)
        var sequence = try points.map { try event(.leftMouseDragged, at: view.convert($0, to: nil)) }
        if cancel {
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            sequence.append(escape)
        }
        let up = try event(.leftMouseUp, at: view.convert(end, to: nil))
        sequence.append(up)
        let pending = UIPendingMouseEvents(sequence)
        // Deliver after native tracking starts, with chronological timestamps.
        // Preloading up/drag before down can stop SwiftPM's outer async run loop
        // and is also rejected by some native gesture recognizers.
        let delivery = Timer(timeInterval: 0.001, repeats: false) { _ in
            MainActor.assumeIsolated { pending.post() }
        }
        RunLoop.main.add(delivery, forMode: .eventTracking)
        let final = up.locationInWindow
        let number = window.windowNumber
        let timeout = UITrackingTimeout()
        let fallback = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                timeout.fired = true
                if let release = NSEvent.mouseEvent(with: .leftMouseUp, location: final, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number,
                                                    context: nil, eventNumber: 100, clickCount: 1, pressure: 0) {
                    NSApp.postEvent(release, atStart: false)
                }
            }
        }
        RunLoop.main.add(fallback, forMode: .eventTracking)
        defer { fallback.invalidate(); delivery.invalidate() }
        view.mouseDown(with: down)
        try #require(pending.posted, "The native control must enter its actual input-tracking loop")
        try #require(!timeout.fired, "Native input tracking must finish from the supplied events")
        if cancel {
            let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true)
            try #require(release?.windowNumber == window.windowNumber)
        }
    }
}

@MainActor private final class UITrackingTimeout { var fired = false }

@MainActor private final class UIPendingMouseEvents {
    let events: [NSEvent]
    var posted = false
    init(_ events: [NSEvent]) { self.events = events }
    func post() {
        for event in events.reversed() { NSApp.postEvent(event, atStart: true) }
        posted = true
    }
}

@MainActor private final class UIInteractionAppDelegate: NSObject, NSApplicationDelegate {
    static let shared = UIInteractionAppDelegate()
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Issue.record("A component UI test unexpectedly requested application termination")
        return .terminateCancel
    }
}

/// SwiftUI virtual nodes expose selectors without declaring the complete
/// NSAccessibility protocol. Dynamic dispatch stays inside this test process.
@MainActor struct UIAccessibleNode {
    let object: NSObject
    func accessibilityIdentifier() -> String? { (object as AnyObject).accessibilityIdentifier?() }
    func accessibilityFrame() -> NSRect {
        (object as AnyObject).accessibilityFrame?() ?? .zero
    }
    func accessibilityPerformPress() -> Bool {
        if let cell = object as? NSCell, let button = cell.controlView as? NSButton {
            guard button.isEnabled else { return false }
            if let handle = button as? HorizontalDragHandleView { return handle.accessibilityPerformPress() }
            button.performClick(nil)
            return true
        }
        return (object as AnyObject).accessibilityPerformPress?() ?? false
    }

    func adjust(_ direction: Int) {
        let target: AnyObject = (object as? NSCell)?.controlView ?? object
        if direction > 0 { _ = target.accessibilityPerformIncrement?() }
        else { _ = target.accessibilityPerformDecrement?() }
    }
}

@MainActor @Observable final class UIStatusPreferences {
    var layout: StatusLayout {
        didSet { defaults.set(layout.saved, forKey: StatusLayout.key) }
    }
    var editing = true
    var reading = 0
    let session = UUID()
    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        layout = StatusLayout.read(defaults.string(forKey: StatusLayout.key) ?? "")
    }

    var binding: Binding<StatusLayout> { Binding(get: { self.layout }, set: { self.layout = $0 }) }

    func accept(_ items: [StatusCardDrag], before target: StatusCardID?) -> Bool {
        guard editing, let changed = StatusCardDrag.applying(items, to: layout, session: session, before: target) else { return false }
        layout = changed
        return true
    }
}

/// Real production grid, gestures, transfer type and editor; only telemetry and
/// storage are substituted. No AppModel task can start a live system reader.
struct UIStatusFixtureView: View {
    @Bindable var preferences: UIStatusPreferences
    var editor = false
    @State private var width: CGFloat = 900

    var body: some View {
        if editor {
            StatusLayoutEditor(layout: preferences.binding)
        } else {
            ScrollView {
                StatusGridView(cards: preferences.layout.visible, compactDensity: Density.current == .compact,
                               editing: preferences.editing, spacing: DS.Space.md) { card in
                    StatusCard(card: card.id, editing: preferences.editing, size: card.size,
                               canResize: StatusGrid.columnCount(width: width, spacing: 15) > 1,
                               drag: StatusCardDrag(card: card.id, session: preferences.session),
                               onResize: { preferences.layout.setSize($0, for: card.id) },
                               onMove: { preferences.layout.move(card.id, by: $0, visibleOnly: true) }) {
                        StatusTelemetry(card: card.id, snapshot: SyntheticStatusReadings.snapshot(reading: preferences.reading),
                                        history: SyntheticStatusReadings.history, trashBytes: 0, order: .constant(.cpu))
                    } actions: {
                        ForEach(StatusCardSize.allCases) { size in
                            Button(size.title) { preferences.layout.setSize(size, for: card.id) }
                        }
                    }
                    .modifier(StatusCardDropTarget(enabled: preferences.editing, accept: { items in
                        preferences.accept(items, before: card.id)
                    }, targeted: { _ in }))
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            }
        }
    }
}

@MainActor @Observable final class UISplitPreferences {
    var width: Double = 440
}

struct UIDiskSplitFixtureView: View {
    @Bindable var preferences: UISplitPreferences
    var body: some View {
        ListSplit(width: $preferences.width) {
            Text("Synthetic chart").frame(maxWidth: .infinity, maxHeight: .infinity)
        } list: {
            Text("Synthetic list").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
