import Foundation
import Testing

@testable import MyMole

@Suite struct DashboardTests {
    @Test func tilesFillEveryRowAsEvenlyAsCanBe() {
        func rows(_ count: Int, _ width: CGFloat) -> [Int] { DSTiles.rows(count: count, width: width, minimum: 230, spacing: 15) }
        // Four fit in 1200: seven are four and three, six are three and three.
        #expect(rows(7, 1200) == [4, 3])
        #expect(rows(6, 1200) == [3, 3])
        // Three fit in 800, two in 696.
        #expect(rows(8, 800) == [3, 3, 2])
        #expect(rows(7, 696) == [2, 2, 2, 1])
        // Narrower than one tile: still one per row. Wider than all: one row.
        #expect(rows(3, 100) == [1, 1, 1])
        #expect(rows(2, 5000) == [2])
        #expect(rows(0, 1200).isEmpty)
        // Whatever the width, every tile is placed and no two rows differ by more than one.
        for count in 1...12 {
            for width in stride(from: CGFloat(100), through: 1400, by: 50) {
                let r = rows(count, width)
                #expect(r.reduce(0, +) == count && (r.max() ?? 0) - (r.min() ?? 0) <= 1 && r == r.sorted(by: >))
            }
        }
    }

    @Test func theBiggestFindsListAPathOnceWhereItIsBigger() {
        let finds = [
            Find(pane: .clean, path: "/a", name: "a", bytes: 5),
            Find(pane: .projects, path: "/a", name: "a", bytes: 9),
            Find(pane: .installer, path: "/b", name: "b", bytes: 7),
            Find(pane: .clean, path: "/c", name: "c", bytes: 0),
            Find(pane: .clean, path: "/d", name: "d", bytes: 1),
        ]
        #expect(Find.biggest(finds, limit: 2).map(\.id) == ["projects:/a", "installer:/b"])
        // Nothing of no size, and nothing twice.
        #expect(Find.biggest(finds, limit: 10).map(\.path) == ["/a", "/b", "/d"])
    }

    @Test func aFindInsideAnotherIsTheSameSpace() {
        let finds = [
            Find(pane: .projects, path: "/synthetic/App", name: "App", bytes: 9),
            Find(pane: .clean, path: "/synthetic/App/.cache", name: ".cache", bytes: 4),
            Find(pane: .clean, path: "/synthetic/AppOther", name: "AppOther", bytes: 3),
        ]
        #expect(Find.biggest(finds, limit: 10).map(\.path) == ["/synthetic/App", "/synthetic/AppOther"])
    }
}
