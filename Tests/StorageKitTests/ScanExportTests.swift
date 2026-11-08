import Foundation
import Testing

@testable import StorageKit

@Suite struct ScanExportTests {
    @Test func aSavedScanOpensToTheSameTotals() throws {
        let box = try Sandbox()
        try box.file("Movies/film.mov", bytes: 3_000_000)
        try box.file("Movies/notes.txt", bytes: 500)
        try box.file("Code/a/b/c.bin", bytes: 1_200_000)
        let root = StorageScanner.scan(path: box.path, workers: 2).root
        let opened = try ScanExport.read(ScanExport(of: root).data()).tree()
        #expect(opened.path == root.path && opened.size == root.size && opened.fileCount == root.fileCount)
        #expect(opened.find(path: box.path + "/Movies")?.listedFiles.map(\.name) == ["film.mov"])
        #expect(opened.find(path: box.path + "/Code/a/b")?.size == root.find(path: box.path + "/Code/a/b")?.size)
    }

    @Test func anythingElseIsRefused() throws {
        #expect(throws: ScanExport.Failure.notAScan) { try ScanExport.read(Data("{}".utf8)) }
        #expect(throws: ScanExport.Failure.notAScan) { try ScanExport.read(Data("not json".utf8)) }
        let newer = #"{"format":"mymole-scan","version":99,"rootPath":"/synthetic","date":"2026-11-07T00:00:00Z","truncated":false,"items":[{"n":"synthetic","p":-1,"s":1,"m":0,"k":7,"c":0,"b":0}]}"#
        #expect(throws: ScanExport.Failure.newerVersion) { try ScanExport.read(Data(newer.utf8)) }
        // An item that names a later or missing folder, or a path in its name.
        let loop = #"{"format":"mymole-scan","version":1,"rootPath":"/synthetic","date":"2026-11-07T00:00:00Z","truncated":false,"items":[{"n":"synthetic","p":-1,"s":1,"m":0,"k":7,"c":0,"b":0},{"n":"x","p":5,"s":1,"m":0,"k":7}]}"#
        #expect(throws: ScanExport.Failure.damaged) { try ScanExport.read(Data(loop.utf8)) }
        let slash = #"{"format":"mymole-scan","version":1,"rootPath":"/synthetic","date":"2026-11-07T00:00:00Z","truncated":false,"items":[{"n":"synthetic","p":-1,"s":1,"m":0,"k":7,"c":0,"b":0},{"n":"../etc","p":0,"s":1,"m":0,"k":7}]}"#
        #expect(throws: ScanExport.Failure.damaged) { try ScanExport.read(Data(slash.utf8)) }
    }
}
