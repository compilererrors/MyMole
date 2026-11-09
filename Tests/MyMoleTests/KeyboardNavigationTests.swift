import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor @Suite struct KeyboardNavigationTests {
    private final class Window: NSWindow {
        var child: NSWindow?
        var popovers: [NSWindow]?
        var presented = false
        override var attachedSheet: NSWindow? { child }
        override var childWindows: [NSWindow]? { popovers }
        override var isVisible: Bool { presented }
    }

    private func window() -> Window {
        let window = Window(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func key(_ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                        isARepeat: false, keyCode: code)!
    }

    @Test func closingIsScopedToTheInnermostRegisteredDialog() {
        let registry = DialogKeyboardRegistry()
        let parent = window(), child = window()
        defer { parent.child = nil; parent.close(); child.close() }
        parent.child = child
        var outer = 0, inner = 0
        registry.register(UUID(), window: parent, canClose: true) { outer += 1 }
        let token = UUID()
        registry.register(token, window: child, canClose: true) { inner += 1 }
        #expect(registry.close(in: parent))
        #expect(inner == 1 && outer == 0)
        registry.remove(token)
        // A native confirmation above the registered parent must handle its
        // own cancellation; never close the parent through it.
        #expect(!registry.close(in: parent) && outer == 0)
        parent.child = nil
        #expect(registry.close(in: parent) && outer == 1)
    }

    @Test func aBusyDialogConsumesCloseWithoutClosingAnything() {
        let registry = DialogKeyboardRegistry()
        let window = window()
        defer { window.close() }
        let token = UUID()
        var closed = 0
        registry.register(token, window: window, canClose: false) { closed += 1 }
        #expect(registry.close(in: window) && closed == 0)
        registry.register(token, window: window, canClose: true) { closed += 1 }
        #expect(registry.close(in: window) && closed == 1)
        registry.remove(token)
        #expect(!registry.close(in: window))
    }

    @Test func aNativeConfirmationCancelsWithoutClosingItsReview() {
        let registry = DialogKeyboardRegistry()
        let review = window(), alert = window()
        defer { review.child = nil; review.close(); alert.close() }
        review.child = alert
        var closed = 0, cancelled = 0
        registry.register(UUID(), window: review, canClose: true) { closed += 1 }
        let token = UUID()
        registry.register(token, window: review, canClose: true, confirmation: true) { cancelled += 1 }
        #expect(registry.close(in: review) && cancelled == 1 && closed == 0)
        registry.remove(token)
        #expect(!registry.close(in: review) && closed == 0)
    }

    @Test func aVisibleRegisteredPopoverClosesBeforeItsParent() {
        let registry = DialogKeyboardRegistry()
        let parent = window(), popover = window()
        defer { parent.popovers = nil; parent.close(); popover.close() }
        parent.popovers = [popover]
        popover.presented = true
        var outer = 0, inner = 0
        registry.register(UUID(), window: parent, canClose: true) { outer += 1 }
        registry.register(UUID(), window: popover, canClose: true) { inner += 1 }
        #expect(registry.close(in: parent) && inner == 1 && outer == 0)
        popover.presented = false
        #expect(registry.close(in: parent) && inner == 1 && outer == 1)
    }

    @Test func aDetachedReaderCannotReregisterItsDepartingWindow() {
        let registry = DialogKeyboardRegistry()
        let first = window(), second = window()
        defer { first.close(); second.close() }
        let reader = DialogWindowReader.Reader()
        reader.registry = registry
        var closed = 0
        reader.close = { closed += 1 }
        first.contentView?.addSubview(reader)
        #expect(registry.close(in: first) && closed == 1)
        reader.removeFromSuperview()
        reader.update()
        #expect(!registry.close(in: first) && closed == 1)
        second.contentView?.addSubview(reader)
        reader.update()
        #expect(registry.close(in: second) && closed == 2)
        reader.active = false
        reader.update()
        #expect(!registry.close(in: second) && closed == 2)
        reader.removeFromSuperview()
    }

    @Test func shortcutsDoNotConfuseOpenContextMenuAndClose() {
        #expect(DialogKeyboardRegistry.isClose(key(13, "w", flags: .command)))
        #expect(!DialogKeyboardRegistry.isClose(key(13, "w", flags: [.command, .option])))
        #expect(FileKeyboard.action(key(36, "\r", flags: .control)) == .menu)
        #expect(FileKeyboard.action(key(76, "\r", flags: .control)) == .menu)
        #expect(FileKeyboard.action(key(109, "", flags: .shift)) == .menu)
        #expect(FileKeyboard.action(key(8, "c", flags: [.command, .option])) == .copyAbsolutePath)
        #expect(FileKeyboard.action(key(36, "\r")) == nil)
        #expect(FileKeyboard.action(key(36, "\r", flags: .shift)) == nil)
    }

    @Test func keyboardOpenAndMenuUseSelectionInsteadOfThePreviousClick() {
        let rows = (0..<3).map { FileRow(id: "/synthetic/Example\($0)", name: "Example \($0)") }
        var opened: [String] = []
        var menuTargets: [String] = []
        let parent = FileTable(rows: rows, columns: [.name], autosave: "synthetic.keyboard", selection: .constant([]),
                               onOpen: { opened = $0 }, menu: { menuTargets = $0; return [] })
        let coordinator = parent.makeCoordinator()
        let table = FileTableView()
        table.dataSource = coordinator
        coordinator.table = table
        coordinator.load(rows, marks: nil, selection: [])
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.open(clicked: 2)
        #expect(opened == [rows[2].id])
        coordinator.open()
        _ = coordinator.keyboardMenu()
        #expect(opened == [rows[0].id] && menuTargets == [rows[0].id])
    }

    @Test func appGridNavigationStaysInsideTheAvailableCards() {
        #expect(GridKeyboard.next(from: 4, count: 9, columns: 3, direction: .up) == 1)
        #expect(GridKeyboard.next(from: 4, count: 9, columns: 3, direction: .down) == 7)
        #expect(GridKeyboard.next(from: 1, count: 9, columns: 3, direction: .up) == 1)
        #expect(GridKeyboard.next(from: 6, count: 9, columns: 3, direction: .down) == 6)
        #expect(GridKeyboard.next(from: 5, count: 8, columns: 3, direction: .down) == 7)
        #expect(GridKeyboard.next(from: 8, count: 9, columns: 3, direction: .right) == 8)
        #expect(GridKeyboard.next(from: 0, count: 9, columns: 3, direction: .left) == 0)
        #expect(GridKeyboard.next(from: 7, count: 8, columns: 3, direction: .down) == 7)
        #expect(GridKeyboard.next(from: 0, count: 0, columns: 0, direction: .down) == 0)
    }

    @Test func fileShortcutsUseRealPathsInsteadOfGroupOrIntegrationIDs() {
        let rows = [FileRow(id: "group:synthetic", name: "Group"),
                    FileRow(id: "/synthetic/Example.app#service", name: "Integration")]
        let parent = FileTable(rows: rows, columns: [.name], autosave: "synthetic.keyboard.paths", selection: .constant([]),
                               filePaths: { ids in ids.flatMap { $0 == rows[0].id ? ["/synthetic/One", "/synthetic/Two"] : ["/synthetic/Example.app"] } })
        let coordinator = parent.makeCoordinator()
        let table = FileTableView()
        table.dataSource = coordinator
        coordinator.table = table
        coordinator.load(rows, marks: nil, selection: [])
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
        #expect(coordinator.selectedPaths == ["/synthetic/One", "/synthetic/Two", "/synthetic/Example.app"])
        #expect(coordinator.previewURLs.map(\.path) == coordinator.selectedPaths)
    }
}
