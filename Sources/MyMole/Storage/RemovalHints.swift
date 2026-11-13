import Foundation
import StorageKit

/// Advisory details prepared while choosing. They never authorize a move.
@MainActor final class RemovalHints {
    struct Key: Hashable, Sendable {
        let selection: UInt64
        let scope: Int
        let protections: UInt64
        let busy: Bool
    }
    struct Input: Sendable {
        let key: Key
        let items: [Marked]
        let protections: UserProtections
        let inspectOpenFiles: Bool
        /// What the scanned tree says the items free; the rest is read here.
        var known: [String: Reclaim] = [:]
    }
    struct Value: Sendable {
        let key: Key
        var kept = Set<String>()
        var keepsUnreadable = false
        var links: [String: Int] = [:]
        var openIn: [String: [String]] = [:]
        /// What moving the outermost items frees, together and one by one.
        var frees: Int64?
        var itemFrees: [String: Int64] = [:]
        var readAt = Date()
    }
    let prepared = OffMain<Value?>(nil)
    private let read: @Sendable (Input, ScanProgress) -> Value

    init(read: @escaping @Sendable (Input, ScanProgress) -> Value = RemovalHints.read) { self.read = read }

    func value(for key: Key) -> Value? {
        prepared.value.flatMap { $0.key == key ? $0 : nil }
    }

    func update(_ input: Input) async {
        if let value = value(for: input.key), Date().timeIntervalSince(value.readAt) < 2 { return }
        let progress = ScanProgress()
        let read = read
        await withTaskCancellationHandler {
            await prepared.update(count: max(1, input.items.count), inlineLimit: 0, step: .removalPreparation) {
                read(input, progress)
            }
        } onCancel: { progress.cancel() }
    }

    nonisolated static func read(_ input: Input, _ progress: ScanProgress) -> Value {
        var value = Value(key: input.key)
        do {
            let keeps = try input.protections.read()
            for item in input.items {
                guard !progress.isCancelled else { return value }
                if keeps(item.path) { value.kept.insert(item.path) }
            }
        } catch { value.keepsUnreadable = true }
        let files = input.items.filter { !$0.isFolder }
        value.links = HardLinks.otherNames(of: files.map(\.path), stop: { progress.isCancelled })
        let reclaims = StorageModel.reclaims(of: input.items, known: input.known, stop: { progress.isCancelled })
        guard !progress.isCancelled else { return value }
        value.itemFrees = reclaims.mapValues(\.bytes)
        value.frees = reclaims.values.reduce(Reclaim(), +).bytes
        if input.inspectOpenFiles {
            let biggest = files.filter { $0.size >= 100_000_000 }.sorted { $0.size > $1.size }.prefix(4)
            for file in biggest {
                guard !progress.isCancelled else { return value }
                if let names = OpenFiles.users(of: file.path), !names.isEmpty { value.openIn[file.path] = names }
            }
        }
        return value
    }
}
