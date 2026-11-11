import StorageKit
import Synchronization

/// One search's updates, shared by its workers and its main-actor publisher.
/// The reference owns the lock; no task captures a local noncopyable mutex.
final class DuplicateScanUpdates: Sendable {
    struct Batch: Sendable {
        let step: DuplicateStep?
        let groups: [DuplicateGroup]
    }

    private struct State {
        var step: DuplicateStep?
        var groups: [DuplicateGroup] = []
    }

    private let state = Mutex(State())

    func update(_ step: DuplicateStep) { state.withLock { $0.step = step } }
    func append(_ group: DuplicateGroup) { state.withLock { $0.groups.append(group) } }

    func take() -> Batch {
        state.withLock { state in
            let batch = Batch(step: state.step, groups: state.groups)
            state.groups = []
            return batch
        }
    }
}
