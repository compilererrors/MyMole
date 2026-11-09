import Foundation
import Observation

/// Activation, folder grants and the visible permission step share one probe.
/// A changed bookmark scope invalidates the old result before another starts.
@MainActor @Observable
final class DiskAccessMonitor {
    private(set) var state: FullDiskAccess.State = .unknown
    private(set) var hasResult = false
    private(set) var checking = false
    @ObservationIgnored var didChange: (() -> Void)?
    @ObservationIgnored private(set) var job: Task<Void, Never>?
    private let probe: @Sendable () -> FullDiskAccess.State
    private var scope: Int?
    private var generation: UInt64 = 0

    init(probe: @escaping @Sendable () -> FullDiskAccess.State = { FullDiskAccess.state() }) {
        self.probe = probe
    }

    @discardableResult
    func request(scope: Int?) -> Task<Void, Never>? {
        if self.scope != scope {
            self.scope = scope
            generation &+= 1
            hasResult = false
            state = .unknown
        }
        guard scope != nil else { checking = false; return job }
        checking = true
        if let job { return job }
        let probe = probe
        let worker = Task { [weak self] in
            while let self, let startedScope = self.scope {
                let run = generation
                let result = await Task.detached(priority: .userInitiated) { probe() }.value
                guard run == generation, self.scope == startedScope else { continue }
                let changed = !hasResult || state != result
                state = result
                hasResult = true
                checking = false
                if changed { didChange?() }
                break
            }
            self?.checking = false
            self?.job = nil
        }
        job = worker
        return worker
    }
}
