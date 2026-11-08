import Foundation
import Synchronization
import Testing

@testable import MyMole
@testable import StorageKit

@MainActor @Suite struct PlacesModelTests {
    @Test func aSlowDiskNeverBlocksTheActorAndMountChangesAreCoalesced() async throws {
        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        defer { first.signal(); second.signal() }
        let reads = Atomic<Int>(0)
        let model = PlacesModel {
            let n = reads.add(1, ordering: .relaxed).newValue
            _ = (n == 1 ? first : second).wait(timeout: .now() + 5)
            return [Volumes.Volume(path: "/synthetic/disk-\(n)", name: "Disk \(n)", available: nil, isRemovable: true)]
        }
        model.refresh()
        try #require(await waitUntil { reads.load(ordering: .relaxed) == 1 })
        // The main actor is still usable while the reader is held. Repeated
        // mount events must not spawn repeated blocked metadata readers.
        for _ in 0..<50 { model.refresh() }
        #expect(reads.load(ordering: .relaxed) == 1 && model.volumes.isEmpty)
        first.signal()
        try #require(await waitUntil { reads.load(ordering: .relaxed) == 2 })
        #expect(model.volumes.isEmpty)
        second.signal()
        await model.job?.value
        #expect(model.volumes.map(\.name) == ["Disk 2"])
        #expect(reads.load(ordering: .relaxed) == 2 && model.job == nil)
    }

    private func waitUntil(_ ready: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if ready() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ready()
    }
}
