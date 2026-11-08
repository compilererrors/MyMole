import Foundation
import Testing

@testable import MyMole

@MainActor
@Suite struct OffMainTests {
    @Test func aSmallListIsWorkedOutAtOnce() async {
        let list = OffMain<[Int]>([])
        await list.update(count: 10) { Array(0..<10) }
        #expect(list.value.count == 10 && !list.working)
    }

    @Test func aLargeListIsWorkedOutOffTheMainThread() async {
        let list = OffMain<Bool>(false)
        await list.update(count: OffMain<Bool>.inline + 1) { !Thread.isMainThread }
        #expect(list.value)
    }

    @Test func aRequestReplacedByANewerOneNeverLands() async {
        let list = OffMain<String>("start")
        let older = Task { @MainActor in
            await list.update(count: 50_000) {
                Thread.sleep(forTimeInterval: 0.2)
                return "older"
            }
        }
        older.cancel()
        await list.update(count: 50_000) { "newer" }
        await older.value
        #expect(list.value == "newer")
    }
}
