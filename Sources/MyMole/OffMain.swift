import Foundation
import Observation
import Synchronization

/// One projection worker, one replaceable pending request. Earlier visible
/// results remain available while the newest input is being prepared.
@MainActor @Observable
final class OffMain<Value: Sendable> {
    private(set) var value: Value
    private(set) var working = false
    static var inline: Int { 2_000 }

    private final class Cancellation: Sendable {
        private let state = Mutex(false)
        func cancel() { state.withLock { $0 = true } }
        var stopped: Bool { state.withLock { $0 } }
    }
    private struct Request: Sendable {
        let id: UInt64
        let count: Int
        let step: Timings.Step
        let cancellation: Cancellation
        let work: @Sendable () -> Value
    }
    @ObservationIgnored private var valueWasLarge = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]

    init(_ initial: Value) { value = initial }

    func update(count: Int, inlineLimit: Int? = nil, step: Timings.Step = .filter, _ work: @escaping @Sendable () -> Value) async {
        guard !Task.isCancelled else { return }
        generation &+= 1
        let id = generation
        if let old = pending {
            pending = nil
            finish(old.id)
            RetiredValue(old).releaseLater()
        }
        guard count > (inlineLimit ?? Self.inline) else {
            publish(Timings.measure(step, rows: count, work), retire: false)
            working = false
            return
        }
        let cancellation = Cancellation()
        working = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !cancellation.stopped else { continuation.resume(); working = false; return }
                waiters[id] = continuation
                pending = Request(id: id, count: count, step: step, cancellation: cancellation, work: work)
                startWorker()
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let request = self?.takeRequest() {
                let result = await Task.detached(priority: .userInitiated) {
                    Timings.measure(request.step, rows: request.count, request.work)
                }.value
                guard let self else { RetiredValue(result).releaseLater(); RetiredValue(request).releaseLater(); return }
                if request.id == generation, !request.cancellation.stopped {
                    publish(result, retire: true)
                    working = false
                } else { RetiredValue(result).releaseLater() }
                finish(request.id)
                RetiredValue(request).releaseLater()
            }
            self?.worker = nil
        }
    }

    private func takeRequest() -> Request? {
        defer { pending = nil }
        return pending
    }

    private func cancel(_ id: UInt64) {
        if let old = pending, old.id == id {
            pending = nil
            RetiredValue(old).releaseLater()
        }
        if generation == id { generation &+= 1; working = false }
        finish(id)
    }

    private func finish(_ id: UInt64) { waiters.removeValue(forKey: id)?.resume() }

    private func publish(_ result: Value, retire: Bool) {
        let previous = retire || valueWasLarge ? RetiredValue(value) : nil
        value = result
        valueWasLarge = retire
        previous?.releaseLater()
    }
}

/// Release the last references to large immutable presentations away from UI
/// callbacks. The box owns the old value before its main-actor slot is replaced.
final class RetiredValue<Value: Sendable>: Sendable {
    private let value: Mutex<Value?>
    init(_ value: Value) { self.value = Mutex(value) }
    @MainActor func releaseLater() {
        DispatchQueue.main.async {
            PresentationRetirement.queue.async { self.value.withLock { $0 = nil } }
        }
    }
}

private enum PresentationRetirement {
    static let queue = DispatchQueue(label: "mymole.presentation-retirement", qos: .utility)
}
