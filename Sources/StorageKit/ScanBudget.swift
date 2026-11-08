import Foundation
import Synchronization

/// How many disk walks run at once, whichever pane started them. Smart
/// Scan, a launch's prefetch and a pane's own Rescan can each start
/// several; past `slots` the rest wait their turn, a foreground scan before
/// any background one, so the disk and the cores aren't split so finely
/// that nothing finishes. A scan stopped while it waits leaves the queue.
public final class ScanBudget: Sendable {
    public static let shared = ScanBudget(slots: 3)

    private final class Request: Sendable {
        let cancelled = Atomic<Bool>(false)
    }

    private struct Waiter {
        let request: Request
        let background: Bool
        let resume: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var running = 0
        var waiting: [Waiter] = []
    }

    private let state = Mutex(State())
    public let slots: Int

    public init(slots: Int) { self.slots = max(1, slots) }

    /// Scans running now, and waiting.
    public var running: Int { state.withLock { $0.running } }
    public var waiting: Int { state.withLock { $0.waiting.count } }

    /// Runs `work` once a slot is free. A foreground request goes ahead of
    /// every background one already waiting.
    /// A stopped request leaves the queue immediately, without starting `work`
    /// or borrowing a slot from a scan that is still running.
    public func run<T: Sendable>(background: Bool, progress: ScanProgress? = nil, _ work: () async -> T) async -> T? {
        let request = Request()
        let observer = progress?.onCancel { [self] in cancel(request) }
        defer { progress?.removeCancellationObserver(observer) }
        return await withTaskCancellationHandler {
            guard await enter(background: background, request: request) else { return nil }
            defer { leave() }
            guard !Task.isCancelled, progress?.isCancelled != true else { return nil }
            return await work()
        } onCancel: {
            progress?.cancel()
            self.cancel(request)
        }
    }

    private func enter(background: Bool, request: Request) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let go = state.withLock { s -> Bool? in
                guard !request.cancelled.load(ordering: .relaxed) else { return false }
                if s.running < slots {
                    s.running += 1
                    return true
                }
                let w = Waiter(request: request, background: background, resume: c)
                if background {
                    s.waiting.append(w)
                } else {
                    // After the foreground ones already waiting, before any background one.
                    let at = s.waiting.firstIndex { $0.background } ?? s.waiting.count
                    s.waiting.insert(w, at: at)
                }
                return nil
            }
            if let go { c.resume(returning: go) }
        }
    }

    private func cancel(_ request: Request) {
        let waiter = state.withLock { s -> Waiter? in
            request.cancelled.store(true, ordering: .relaxed)
            guard let index = s.waiting.firstIndex(where: { $0.request === request }) else { return nil }
            return s.waiting.remove(at: index)
        }
        waiter?.resume.resume(returning: false)
    }

    private func leave() {
        let next = state.withLock { s -> Waiter? in
            guard !s.waiting.isEmpty else {
                s.running -= 1
                return nil
            }
            // The slot passes straight to the next in line.
            return s.waiting.removeFirst()
        }
        next?.resume.resume(returning: true)
    }
}
