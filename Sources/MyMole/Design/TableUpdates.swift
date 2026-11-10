import AppKit

/// Linear, bounded work for the usual insert/remove update. Reordering uses
/// a reload; it never attempts a quadratic diff of a large directory.
struct TableRowChanges: Sendable {
    let removed: IndexSet
    let inserted: IndexSet

    nonisolated static func between(_ old: [String], _ new: [String]) -> Self? {
        // Large replacements are cheaper as one virtualized reload. Native
        // row insertions otherwise allocate bookkeeping for every new row.
        guard abs(old.count - new.count) <= 256 else { return nil }
        let positions = Dictionary(old.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        guard positions.count == old.count else { return nil }
        var seen = Set<String>()
        var last = -1
        var inserted = IndexSet()
        for (index, key) in new.enumerated() {
            guard seen.insert(key).inserted else { return nil }
            if let position = positions[key] {
                guard position > last else { return nil }
                last = position
            } else { inserted.insert(index) }
        }
        let removed = IndexSet(old.indices.filter { !seen.contains(old[$0]) })
        guard removed.count + inserted.count <= 256 else { return nil }
        return Self(removed: removed, inserted: inserted)
    }
}

/// Keep the first surviving visible row at the same pixel, even when a row
/// above it disappears or changes order. Only the viewport is sampled.
@MainActor struct TableScrollAnchor {
    private let origin: NSPoint
    private let rows: [(String, CGFloat)]

    init(_ table: NSTableView, key: (Int) -> String?) {
        let origin = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
        self.origin = origin
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { rows = []; return }
        let end = min(table.numberOfRows, visible.location + min(visible.length, 256))
        rows = (visible.location..<max(visible.location, end)).compactMap { row in
            key(row).map { ($0, table.rect(ofRow: row).minY - origin.y) }
        }
    }

    func restore(in table: NSTableView, row: (String) -> Int?) {
        guard let scroll = table.enclosingScrollView else { return }
        table.layoutSubtreeIfNeeded()
        var target = origin
        for (key, offset) in rows {
            if let index = row(key), index >= 0, index < table.numberOfRows {
                target.y = table.rect(ofRow: index).minY - offset
                break
            }
        }
        let clip = scroll.contentView
        // Native headers and inset styles can require a negative top origin.
        // Clamping to zero slides the first row underneath the header.
        target = clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin
        clip.scroll(to: target)
        scroll.reflectScrolledClipView(clip)
    }
}

extension NSTableView {
    func withoutRowAnimation(_ update: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            update()
        }
    }
}
