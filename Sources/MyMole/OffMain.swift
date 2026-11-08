import Foundation
import Observation

/// A list worked out off the main thread: filtering or projecting tens of
/// thousands of rows takes long enough to stall typing. Run from
/// `.task(id:)`, so a new request cancels one still running and only the
/// latest lands. Small lists are worked out at once, so they never show
/// an empty moment.
@MainActor
@Observable
final class OffMain<Value: Sendable> {
    private(set) var value: Value
    /// A newer result is being worked out; `value` is the one before.
    private(set) var working = false
    /// Lists up to this many items are worked out on the spot.
    static var inline: Int { 2_000 }

    init(_ initial: Value) { value = initial }

    func update(count: Int, _ work: @escaping @Sendable () -> Value) async {
        guard count > Self.inline else {
            value = Timings.measure(.filter, rows: count, work)
            working = false
            return
        }
        working = true
        let result = await Task.detached(priority: .userInitiated) { Timings.measure(.filter, rows: count, work) }.value
        guard !Task.isCancelled else { return }
        value = result
        working = false
    }
}
