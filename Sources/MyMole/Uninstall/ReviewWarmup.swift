import Foundation
import StorageKit

/// One bounded preparation started on mouse-down and joined by the review.
/// Only cheap hints are reused; this cache never contains removal approval.
@MainActor final class ReviewWarmup {
    struct Key: Equatable {
        let app: AppBundle
        let revision: UInt64
    }
    struct Value: Sendable {
        var uninstaller: String?
        var mentions: [AppMention]
        nonisolated init(uninstaller: String? = nil, mentions: [AppMention] = []) {
            self.uninstaller = uninstaller
            self.mentions = mentions
        }
    }
    private var key: Key?
    private var started = ContinuousClock.now
    private var job: Task<Value, Never>?
    private let read: @MainActor (AppBundle) async -> Value

    init(read: @escaping @MainActor (AppBundle) async -> Value) { self.read = read }

    func prepare(_ key: Key) {
        if self.key == key, job != nil, ContinuousClock.now - started < .seconds(5) { return }
        let previous = job
        previous?.cancel()
        self.key = key
        started = .now
        let read = read
        job = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return Value() }
            let value = await read(key.app)
            return Task.isCancelled ? Value() : value
        }
    }

    func value(for key: Key) async -> Value {
        prepare(key)
        return await job?.value ?? Value()
    }

    func cancel(_ key: Key) {
        guard self.key == key else { return }
        job?.cancel()
        self.key = nil
    }
}
