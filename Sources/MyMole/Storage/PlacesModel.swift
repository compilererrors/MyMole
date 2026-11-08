import Foundation
import Observation
import StorageKit

/// Volume metadata can wait on an external disk or a network server. One
/// reader handles mount changes, coalescing requests and publishing only a
/// reading that includes the latest change.
@MainActor @Observable
final class PlacesModel {
    private let read: @Sendable () -> [Volumes.Volume]
    private var generation = 0
    private(set) var volumes: [Volumes.Volume] = []
    private(set) var job: Task<Void, Never>?

    init(read: @escaping @Sendable () -> [Volumes.Volume] = { Volumes.mounted() }) {
        self.read = read
    }

    func refresh() {
        generation += 1
        guard job == nil else { return }
        job = Task { [self] in
            while true {
                let run = generation
                let read = read
                let found = await Task.detached(priority: .utility) { read() }.value
                guard run == generation else { continue }
                volumes = found
                job = nil
                return
            }
        }
    }
}
