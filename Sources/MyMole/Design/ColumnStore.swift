import AppKit
import ObjectiveC

/// A list's columns kept between launches: their order, widths and which
/// are shown, saved shortly after the user changes them. AppKit's own
/// column autosave also wrote every width the list set itself, such as the
/// name column filling the pane on every frame of a resize; each write to
/// the defaults wakes every `@AppStorage` in the app and drew the whole
/// window anew. Widths the list fits itself are not saved here.
@MainActor
final class ColumnStore {
    static let prefix = "table.columns.v1."

    private weak var table: NSTableView?
    private let key: String
    private let defaults: UserDefaults
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?

    struct Saved: Equatable {
        let id: String
        let width: Double
        let hidden: Bool
    }

    init(table: NSTableView, name: String, defaults: UserDefaults) {
        self.table = table
        key = Self.prefix + name
        self.defaults = defaults
        let center = NotificationCenter.default
        for note in [NSTableView.columnDidResizeNotification, NSTableView.columnDidMoveNotification] {
            observers.append(center.addObserver(forName: note, object: table, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The saved columns, in their order.
    var saved: [Saved]? {
        (defaults.array(forKey: key) as? [[String: Any]])?.compactMap { entry in
            guard let id = entry["id"] as? String, let width = entry["width"] as? Double else { return nil }
            return Saved(id: id, width: width, hidden: entry["hidden"] as? Bool ?? false)
        }
    }

    /// Puts the saved columns back; false when none were saved.
    @discardableResult
    func restore() -> Bool {
        guard let table, let saved, !saved.isEmpty else { return false }
        var position = 0
        for entry in saved {
            guard let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == entry.id }) else { continue }
            let column = table.tableColumns[index]
            if entry.width.isFinite, entry.width > 0 { column.width = CGFloat(entry.width) }
            column.isHidden = entry.hidden && entry.id != FileColumn.name.rawValue
            if index != position { table.moveColumn(index, toColumn: position) }
            position += 1
        }
        return true
    }

    /// A change the user made: saved once they have stopped making it.
    func changed() {
        guard let table, (table as? any UserColumnTable)?.columnViewport?.isFitting != true else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            // Still dragging a divider or a heading: saved once it's let go.
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard let table else { return }
        let entries: [[String: Any]] = table.tableColumns.map {
            ["id": $0.identifier.rawValue, "width": Double($0.width), "hidden": $0.isHidden]
        }
        defaults.set(entries, forKey: key)
    }
}

private nonisolated(unsafe) var columnStoreKey: UInt8 = 0

extension NSTableView {
    /// Keeps the columns between launches under `name`, which also names
    /// the list (`autosaveName`). The first time, the columns AppKit kept
    /// for that name are taken over.
    func persistColumns(as name: String, defaults: UserDefaults = .standard) {
        autosaveName = name
        let store = ColumnStore(table: self, name: name, defaults: defaults)
        objc_setAssociatedObject(self, &columnStoreKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if !store.restore() {
            // AppKit puts back what it kept when its autosave is turned on.
            autosaveTableColumns = true
            autosaveTableColumns = false
        }
    }

    var columnStore: ColumnStore? { objc_getAssociatedObject(self, &columnStoreKey) as? ColumnStore }

    /// After a menu shows, hides or sizes columns.
    func columnsChanged() { columnStore?.save() }
}
