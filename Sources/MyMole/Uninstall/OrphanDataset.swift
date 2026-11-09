import Foundation
import StorageKit

/// Immutable list data. Indexing and totals are prepared once with the result,
/// rather than walking the entire list for each footer or button redraw.
struct OrphanDataset: Sendable {
    let items: [Orphan]
    let index: [String: Int]
    let totalBytes: Int64

    init(_ items: [Orphan] = []) {
        self.items = items
        index = Dictionary(items.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { a, _ in a })
        totalBytes = items.reduce(0) { $0 + $1.bytes }
    }

    func selected(_ paths: Set<String>) -> [Orphan] {
        paths.compactMap { index[$0] }.sorted().map { items[$0] }
    }

    func bytes(in paths: Set<String>) -> Int64 {
        paths.reduce(0) { total, path in total + (index[path].map { items[$0].bytes } ?? 0) }
    }
}
