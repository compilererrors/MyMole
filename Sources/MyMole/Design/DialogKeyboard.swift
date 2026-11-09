import AppKit
import SwiftUI

private struct DialogCloseKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

extension EnvironmentValues {
    var closeDialog: (@MainActor @Sendable () -> Void)? {
        get { self[DialogCloseKey.self] }
        set { self[DialogCloseKey.self] = newValue }
    }
}

/// Route app-local Command-W to the active presentation. Native menus and
/// unregistered windows retain their own responder chain.
@MainActor final class DialogKeyboardRegistry {
    static let shared = DialogKeyboardRegistry()
    private struct Entry {
        weak var window: NSWindow?
        let canClose: Bool
        let confirmation: Bool
        let close: () -> Void
    }
    private var entries: [UUID: Entry] = [:]
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                guard Self.isClose(event), RunLoop.current.currentMode != .eventTracking,
                      let window = NSApp.keyWindow ?? event.window else { return false }
                return self.close(in: window)
            }
            return handled ? nil : event
        }
    }

    static func isClose(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "w"
    }

    func register(_ id: UUID, window: NSWindow?, canClose: Bool, confirmation: Bool = false, close: @escaping () -> Void) {
        entries[id] = window.map { Entry(window: $0, canClose: canClose, confirmation: confirmation, close: close) }
    }

    func remove(_ id: UUID) { entries[id] = nil }

    /// Consume a blocked close too, so it cannot close the parent window.
    @discardableResult func close(in window: NSWindow) -> Bool {
        var front = window
        var owner = window.sheetParent
        while true {
            if let sheet = front.attachedSheet { owner = front; front = sheet }
            else if let popover = front.childWindows?.reversed().first(where: { child in
                child.isVisible && entries.values.contains { !$0.confirmation && $0.window === child }
            }) { owner = nil; front = popover }
            else { break }
        }
        if let panel = front as? NSSavePanel { panel.cancel(nil); return true }
        // A native alert has its own window. Match only its immediate owner,
        // so cancelling it can never dismiss the registered review below it.
        guard let entry = entries.values.first(where: { !$0.confirmation && $0.window === front })
                ?? entries.values.first(where: { $0.confirmation && owner != nil && $0.window === owner }) else { return false }
        if entry.canClose { entry.close() }
        return true
    }
}

struct DialogWindowReader: NSViewRepresentable {
    let canClose: Bool
    let close: () -> Void
    var active = true
    var confirmation = false

    final class Reader: NSView {
        let token = UUID()
        var registry = DialogKeyboardRegistry.shared
        private weak var attachedWindow: NSWindow?
        var canClose = true
        var close: () -> Void = {}
        var active = true
        var confirmation = false
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            attachedWindow = newWindow
            update()
        }
        func update() {
            // SwiftUI can update a departing popover while NSView.window still
            // points at its deallocating window. Use the zeroing reference
            // captured during attachment, never form a new weak reference to it.
            registry.register(token, window: active ? attachedWindow : nil, canClose: canClose, confirmation: confirmation, close: close)
        }
    }

    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) {
        view.canClose = canClose
        view.close = close
        view.active = active
        view.confirmation = confirmation
        view.update()
    }
    static func dismantleNSView(_ view: Reader, coordinator: ()) {
        view.registry.remove(view.token)
    }
}

private struct DialogKeyboard: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let canClose: Bool

    private func close() { if canClose { dismiss() } }

    func body(content: Content) -> some View {
        content
            .environment(\.closeDialog, close)
            .focusSection()
            .onExitCommand(perform: close)
            .interactiveDismissDisabled(!canClose)
            .background { DialogWindowReader(canClose: canClose, close: close).frame(width: 0, height: 0).accessibilityHidden(true) }
    }
}

extension View {
    func dialogKeyboard(canClose: Bool = true) -> some View { modifier(DialogKeyboard(canClose: canClose)) }

    /// Keep the native Cancel button's Escape equivalent. Register only
    /// while presented, and only for a confirmation attached to this window.
    func confirmationKeyboard(isPresented: Binding<Bool>) -> some View {
        background {
            DialogWindowReader(canClose: true, close: { isPresented.wrappedValue = false },
                               active: isPresented.wrappedValue, confirmation: true)
                .frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }
}
