import Foundation

/// One reading shared by every place that asks for it: a request while a
/// reading runs waits for that one, and one within `maxAge` of the last
/// reading gets it, so the readings don't multiply with the views showing
/// them.
@MainActor
final class SharedReading<Value: Sendable> {
    private(set) var last: (value: Value, at: Date)?
    private var running: Task<Value, Never>?
    /// Readings taken.
    private(set) var count = 0
    private let read: @Sendable () -> Value
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }, read: @escaping @Sendable () -> Value) {
        self.read = read
        self.now = now
    }

    func value(maxAge: TimeInterval) async -> Value {
        if let last, now().timeIntervalSince(last.at) < maxAge { return last.value }
        if let running { return await running.value }
        let read = read
        let job = Task.detached(priority: .utility) { read() }
        running = job
        let v = await job.value
        running = nil
        count += 1
        last = (v, now())
        return v
    }
}
