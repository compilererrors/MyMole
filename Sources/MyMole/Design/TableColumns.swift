import AppKit
import SwiftUI

@MainActor protocol UserColumnTable: AnyObject {
    var defaultHiddenColumns: Set<String> { get set }
    var columnViewport: ColumnViewport? { get set }
}

extension NSTableView {
    func columnVisibilityMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Columns"))
        menu.autoenablesItems = false
        for column in tableColumns {
            let fixed = column.identifier.rawValue == FileColumn.name.rawValue
            let item = ClosureMenuItem(column.title) { [weak self] in
                guard !fixed, let self else { return }
                column.isHidden.toggle()
                fitFlexibleColumn(FileColumn.name.rawValue)
                updateScrollableWidth()
            }
            item.state = column.isHidden ? .off : .on
            item.isEnabled = !fixed
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Show All Columns")) { [weak self] in
            guard let self else { return }
            for column in tableColumns { column.isHidden = false }
            fitFlexibleColumn(FileColumn.name.rawValue)
            updateScrollableWidth()
        })
        if let defaults = (self as? any UserColumnTable)?.defaultHiddenColumns {
            menu.addItem(ClosureMenuItem(String(localized: "Restore Default Columns")) { [weak self] in
                guard let self else { return }
                for column in tableColumns { column.isHidden = defaults.contains(column.identifier.rawValue) && column.identifier.rawValue != "name" }
                fitFlexibleColumn(FileColumn.name.rawValue)
                updateScrollableWidth()
            })
        }
        addColumnWidthActions(to: menu)
        return menu
    }

    func addColumnSubmenu(to menu: NSMenu) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(title: String(localized: "Columns"), action: nil, keyEquivalent: "")
        item.submenu = columnVisibilityMenu()
        menu.addItem(item)
    }

    func populateColumnHeader(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for item in columnVisibilityMenu().items { item.menu?.removeItem(item); menu.addItem(item) }
    }
}

/// A visible alternative to the native header menu, scoped to this list
/// in this window. Only existing table views are inspected, never their data.
struct TableColumnsButton: NSViewRepresentable {
    let scope: String

    func makeCoordinator() -> Coordinator { Coordinator(scope) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .rounded
        button.autoenablesItems = false
        button.altersStateOfSelectedItem = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.toolTip = String(localized: "Show or hide columns. You can also right-click a column heading.")
        button.setAccessibilityLabel(String(localized: "Show or Hide Columns"))
        button.setAccessibilityIdentifier("columns." + scope)
        context.coordinator.button = button
        let menu = NSMenu(title: String(localized: "Columns"))
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        button.menu = menu
        context.coordinator.setTitle(in: menu)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.scope = scope
        button.setAccessibilityIdentifier("columns." + scope)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? { nsView.fittingSize }

    static func table(in view: NSView, scope: String) -> NSTableView? {
        guard !view.isHidden else { return nil }
        if let table = view as? NSTableView, table.autosaveName == scope { return table }
        for child in view.subviews { if let found = table(in: child, scope: scope) { return found } }
        return nil
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var scope: String
        weak var button: NSPopUpButton?
        init(_ scope: String) { self.scope = scope }

        func setTitle(in menu: NSMenu) {
            let item = NSMenuItem(title: String(localized: "Columns"), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
            item.isHidden = true
            menu.addItem(item)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            setTitle(in: menu)
            guard let root = button?.window?.contentView,
                  let table = TableColumnsButton.table(in: root, scope: scope) else { return }
            let options = table.columnVisibilityMenu()
            for item in options.items { options.removeItem(item); menu.addItem(item) }
        }
    }
}
