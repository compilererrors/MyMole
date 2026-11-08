import Foundation
import Testing

@testable import StorageKit

@Suite struct ScanIndexTests {
    @Test func theWholeScanIsSearchedByNameAndPathBiggestFirst() throws {
        let box = try Sandbox()
        try box.file("Projects/Editor/build/app.dmg", bytes: 3_000_000)
        try box.file("Projects/Viewer/viewer.dmg", bytes: 2_000_000)
        try box.file("Music/song.mp3", bytes: 1_500_000)
        try box.file("Music/small.dmg", bytes: 10)
        let root = StorageScanner.scan(path: box.path, workers: 2).root
        let index = ScanIndex(root)

        let dmgs = index.search("dmg").found.map(index.path)
        #expect(dmgs == [box.path + "/Projects/Editor/build/app.dmg", box.path + "/Projects/Viewer/viewer.dmg"])
        // A word found in the path, another in the name.
        #expect(index.search("editor dmg").found.map(index.path) == [box.path + "/Projects/Editor/build/app.dmg"])
        #expect(index.search("viewer", keep: { $0.isFolder }).found.map(index.path) == [box.path + "/Projects/Viewer"])
        #expect(index.search("mp3", limit: 0).more)
        #expect(!index.truncated)
    }

    @Test func aScanBiggerThanTheLimitIsSaidToBe() throws {
        let box = try Sandbox()
        for i in 0..<5 { try box.file("f\(i)/x.bin", bytes: 1_100_000) }
        let index = ScanIndex(StorageScanner.scan(path: box.path, workers: 2).root, limit: 3)
        #expect(index.truncated && index.entries.count == 3)
    }
}
