import Foundation

/// One worker for open project branches. Only immutable row keys leave the
/// presentation actor; native nodes and Folder objects never cross threads.
@MainActor final class FootprintSorting {
    typealias Node = FootprintOutline.Node
    private struct Request {
        let token: UUID
        let owner: Node
        let nodes: [Node]
        let column: FileColumn
        let ascending: Bool
        let sort: @Sendable ([FileRow], FileColumn, Bool) -> [FileRow]
        let apply: (Node, [String]) -> Void
    }

    private var pending: [Request] = []
    private var stopped = false
    private(set) var job: Task<Void, Never>?

    func enqueue(_ nodes: [Node], owner: Node, column: FileColumn, ascending: Bool,
                 sort: @escaping @Sendable ([FileRow], FileColumn, Bool) -> [FileRow],
                 apply: @escaping (Node, [String]) -> Void) {
        guard !stopped else { return }
        cancel(owner)
        let token = UUID()
        owner.sortToken = token
        pending.append(Request(token: token, owner: owner, nodes: nodes, column: column,
                               ascending: ascending, sort: sort, apply: apply))
        guard job == nil else { return }
        job = Task { [weak self] in
            guard let self else { return }
            defer { job = nil }
            while !pending.isEmpty, !stopped, !Task.isCancelled {
                let request = pending.removeFirst()
                var rows: [FileRow] = []
                rows.reserveCapacity(request.nodes.count)
                for (index, node) in request.nodes.enumerated() {
                    guard !stopped, request.owner.sortToken == request.token, !Task.isCancelled else { break }
                    if let row = Self.row(node) { rows.append(row) }
                    if index % 256 == 255 { await Task.yield() }
                }
                guard !stopped, request.owner.sortToken == request.token, !Task.isCancelled else { continue }
                let column = request.column, ascending = request.ascending, sort = request.sort
                let input = rows
                let ordered = await Task.detached(priority: .userInitiated) {
                    Timings.measure(.sort, rows: input.count) { sort(input, column, ascending).map(\.id) }
                }.value
                guard !stopped, request.owner.sortToken == request.token, !Task.isCancelled else { continue }
                request.apply(request.owner, ordered)
                if request.owner.sortToken == request.token { request.owner.sortToken = nil }
            }
        }
    }

    func cancel(_ node: Node) {
        node.sortToken = nil
        pending.removeAll { $0.owner === node }
    }

    func stop() {
        stopped = true
        pending = []
        job?.cancel()
    }

    static func row(_ node: Node) -> FileRow? {
        let name: String, bytes: Int64, date: Date
        switch node.kind {
        case .item(let item): (name, bytes, date) = (item.title, item.bytes, item.latest)
        case .entry(_, let entry): (name, bytes, date) = ((entry.path as NSString).lastPathComponent, entry.bytes, entry.modified)
        case .folder(_, let folder): (name, bytes, date) = (folder.name, folder.size, folder.latestChange)
        case .file(_, let path, let size, let modified): (name, bytes, date) = ((path as NSString).lastPathComponent, size, modified)
        case .section, .smallFiles, .loading: return nil
        }
        return FileRow(id: node.key, name: name, size: bytes, modified: date)
    }

    static func isSortable(_ node: Node) -> Bool {
        switch node.kind {
        case .section, .smallFiles, .loading: false
        default: true
        }
    }
}
