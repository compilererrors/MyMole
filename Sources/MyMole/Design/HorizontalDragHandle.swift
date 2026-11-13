import AppKit
import SwiftUI

/// Native tracking coalesces drawing while dragging. It never replaces the
/// containing SwiftUI card or forces a layout pass for each pointer event.
struct HorizontalDragHandle: NSViewRepresentable {
    let label: String
    let identifier: String
    var value = ""
    var enabled = true
    var separator = false
    var onChange: (CGSize) -> Void
    var onEnd: (CGSize) -> Void
    var onPress: () -> Void = {}
    var onCancel: () -> Void = {}
    var onAdjust: (Int) -> Void
    @Environment(\.palette) private var palette

    func makeNSView(context: Context) -> HorizontalDragHandleView {
        let view = HorizontalDragHandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: HorizontalDragHandleView, context: Context) {
        if view.configuredLabel != label { view.setAccessibilityLabel(label); view.configuredLabel = label }
        if view.configuredIdentifier != identifier { view.setAccessibilityIdentifier(identifier); view.configuredIdentifier = identifier }
        if view.configuredValue != value { view.setAccessibilityValue(value); view.configuredValue = value }
        let active = enabled && context.environment.isEnabled
        if view.isEnabled != active || view.separator != separator {
            view.isEnabled = active
            view.separator = separator
            view.setAccessibilityRole(separator ? .splitter : .button)
            view.window?.invalidateCursorRects(for: view)
            view.needsDisplay = true
        }
        if view.contentTintColor != palette.accentText.ns { view.contentTintColor = palette.accentText.ns }
        if view.separatorColor != palette.separator.ns { view.separatorColor = palette.separator.ns; view.needsDisplay = true }
        view.onChange = onChange
        view.onEnd = onEnd
        view.onPress = onPress
        view.onCancel = onCancel
        view.onAdjust = onAdjust
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HorizontalDragHandleView, context: Context) -> CGSize? {
        func bounded(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite else { return fallback }
            return max(0, value)
        }
        return CGSize(width: bounded(proposal.width, fallback: 26), height: bounded(proposal.height, fallback: 22))
    }
}

final class HorizontalDragHandleView: NSButton {
    var configuredLabel: String?
    var configuredIdentifier: String?
    var configuredValue: String?
    var separator = false
    var separatorColor = NSColor.separatorColor
    var onChange: (CGSize) -> Void = { _ in }
    var onEnd: (CGSize) -> Void = { _ in }
    var onPress: () -> Void = {}
    var onCancel: () -> Void = {}
    var onAdjust: (Int) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: nil)
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .resizeLeftRight) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if separator {
            separatorColor.setFill()
            NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
        } else {
            super.draw(dirtyRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        window.makeFirstResponder(self)
        let start = event.locationInWindow
        var dragged = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], timeout: .greatestFiniteMagnitude,
                           mode: .eventTracking) { [self] next, stop in
            guard let next, isEnabled, self.window === window else { onCancel(); stop.pointee = true; return }
            if next.type == .keyDown {
                if next.keyCode == 53 { onCancel(); stop.pointee = true }
                return
            }
            let translation = CGSize(width: next.locationInWindow.x - start.x, height: next.locationInWindow.y - start.y)
            dragged = dragged || abs(translation.width) >= 6 || abs(translation.height) >= 6
            if next.type == .leftMouseUp {
                stop.pointee = true
                if !dragged { onPress() }
                onEnd(translation)
            } else { onChange(translation) }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 123: onAdjust(-1)
        case 124: onAdjust(1)
        case 36, 49: onPress()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !separator else { return false }
        onPress(); return true
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        onAdjust(1); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        onAdjust(-1); return true
    }
}
