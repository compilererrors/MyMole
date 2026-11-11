import Testing

@testable import MyMole
@testable import StorageKit

@Suite struct DuplicateScanUpdatesTests {
    @Test func concurrentProducersAndDrainingPreserveEveryGroupExactlyOnce() async {
        let updates = DuplicateScanUpdates()
        let producers = 8
        let perProducer = 100
        var received: [String] = []
        await withTaskGroup(of: [String].self) { tasks in
            tasks.addTask {
                var received: [String] = []
                for _ in 0..<200 {
                    received += updates.take().groups.map(\.id)
                    await Task.yield()
                }
                return received
            }
            for producer in 0..<producers {
                tasks.addTask {
                    for item in 0..<perProducer {
                        updates.update(DuplicateStep(phase: .comparing, done: item, total: perProducer))
                        updates.append(DuplicateGroup(length: 1_024, bytes: 1_024,
                                                      digest: "synthetic-\(producer)-\(item)", files: []))
                        await Task.yield()
                    }
                    return []
                }
            }
            for await batch in tasks { received += batch }
        }
        let remaining = updates.take()
        received += remaining.groups.map(\.id)
        #expect(received.count == producers * perProducer)
        #expect(Set(received).count == received.count)
        #expect(remaining.step != nil)
        #expect(updates.take().groups.isEmpty)
    }
}
