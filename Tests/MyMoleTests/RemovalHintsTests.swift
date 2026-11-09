import Foundation
import StorageKit
import Synchronization
import Testing

@testable import MyMole

@MainActor @Suite struct RemovalHintsTests {
    private func wait(_ check: () -> Bool) async throws {
        for _ in 0..<400 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "SyntheticHintsTimeout", code: 1)
    }

    @Test func blockedAdvisoryWorkCannotBlockConfirmationAndOnlyLatestSelectionPublishes() async throws {
        let held = DispatchSemaphore(value: 0)
        let starts = Mutex<[UInt64]>([])
        let onMain = Mutex(false)
        let hints = RemovalHints { input, _ in
            onMain.withLock { $0 = $0 || Thread.isMainThread }
            starts.withLock { $0.append(input.key.selection) }
            if input.key.selection == 1 { _ = held.wait(timeout: .now() + 5) }
            return RemovalHints.Value(key: input.key)
        }
        defer { held.signal() }
        let root = FileManager.default.temporaryDirectory.appending(path: "hints-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func input(_ revision: UInt64) -> RemovalHints.Input {
            .init(key: .init(selection: revision, scope: 0, protections: 0, busy: false), items: [],
                  protections: UserProtections(root: root), inspectOpenFiles: false)
        }
        let first = Task { await hints.update(input(1)) }
        try await wait { starts.withLock { !$0.isEmpty } }
        var queued = false
        let replaced = Task { queued = true; await hints.update(input(2)) }
        try await wait { queued }
        queued = false
        let latest = Task { queued = true; await hints.update(input(3)) }
        try await wait { queued }
        let model = StorageModel()
        model.protections = UserProtections(root: root)
        model.mark([Marked(path: root.appending(path: "chosen").path, name: "chosen", size: 1, isFolder: true)])
        model.beginTrashReview()
        #expect(model.showReview && model.canTrash)
        #expect(hints.value(for: input(3).key) == nil)
        held.signal()
        await first.value
        await replaced.value
        await latest.value
        #expect(starts.withLock { $0 } == [1, 3])
        #expect(!onMain.withLock { $0 })
        #expect(hints.value(for: input(1).key) == nil)
        #expect(hints.value(for: input(3).key) != nil)
    }

    @Test func cancellationDoesNotPublishPartialHints() async throws {
        let started = Mutex(false)
        let hints = RemovalHints { input, progress in
            started.withLock { $0 = true }
            while !progress.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
            return RemovalHints.Value(key: input.key)
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "cancel-hints-\(UUID().uuidString)")
        let input = RemovalHints.Input(key: .init(selection: 0, scope: 0, protections: 0, busy: false),
                                       items: [], protections: UserProtections(root: root), inspectOpenFiles: false)
        let task = Task { await hints.update(input) }
        try await wait { started.withLock { $0 } }
        task.cancel()
        await task.value
        #expect(hints.value(for: input.key) == nil && !hints.prepared.working)
    }
}
