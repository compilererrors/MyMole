import Synchronization

/// Separates an uncancellable filesystem read from cooperative processing of
/// the published tree. Retirement prevents a late reader from starting that
/// processing; an already admitted metadata reader must finish before pruning.
final class DiskScanSession: Sendable {
    private struct State { var retired = false; var finalizing = false }
    private let state = Mutex(State())

    func beginFinalization() -> Bool {
        state.withLock {
            guard !$0.retired else { return false }
            $0.finalizing = true
            return true
        }
    }

    /// Whether a cooperative metadata reader already holds the published tree.
    @discardableResult
    func retire() -> Bool {
        state.withLock { $0.retired = true; return $0.finalizing }
    }

    func finish() { state.withLock { $0.finalizing = false } }
}
