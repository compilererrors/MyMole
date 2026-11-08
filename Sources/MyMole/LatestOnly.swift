import Foundation
import Synchronization

/// Hands values sent from any thread to the main actor, at most one
/// delivery per `interval`, always the latest: a scan reporting from many
/// threads redraws the pane a few times a second, never once per folder.
final class LatestOnly<Value: Sendable>: Sendable {
    private struct State {
        var latest: Value?
        var pending = false
    }

    private let state = Mutex(State())
    private let interval: Duration
    private let deliver: @MainActor @Sendable (Value) -> Void

    init(interval: Duration = .milliseconds(120), deliver: @escaping @MainActor @Sendable (Value) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    func send(_ value: Value) {
        let schedule = state.withLock { s -> Bool in
            s.latest = value
            guard !s.pending else { return false }
            s.pending = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor [self] in
            try? await Task.sleep(for: interval)
            let v = state.withLock { s -> Value? in
                s.pending = false
                defer { s.latest = nil }
                return s.latest
            }
            if let v { deliver(v) }
        }
    }
}
