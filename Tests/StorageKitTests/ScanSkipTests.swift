import Foundation
import Testing

@testable import StorageKit

@Suite struct ScanSkipTests {
    @Test func aSkippedFolderIsNeitherWalkedNorCountedNorCompared() throws {
        let box = try Sandbox()
        try box.file("Big/data.bin", bytes: 60 * 1_048_576)
        try box.file("Kept/notes.bin", bytes: 2_000_000)
        let full = StorageScanner.scan(path: box.path, workers: 2).root
        let skipped = StorageScanner.scan(path: box.path, workers: 2, skip: [box.path + "/Big"]).root
        #expect(full.find(path: box.path + "/Big") != nil)
        #expect(skipped.find(path: box.path + "/Big") == nil)
        #expect(skipped.size < full.size)

        // Skipping it from now on doesn't make it look deleted.
        let before = Snapshot(of: full)
        let after = Snapshot(of: skipped, excluded: ["Big"])
        #expect(before.changes(to: after, threshold: 1).isEmpty)
        // Without the skip noted, it would.
        #expect(!before.changes(to: Snapshot(of: skipped), threshold: 1).isEmpty)
    }

    @Test func aSnapshotWithoutSkipsStillReads() throws {
        let json = #"{"rootPath":"/synthetic","date":0,"sizes":{"":1},"files":{},"folderDepth":6,"tracksFiles":true,"incomplete":false}"#
        let s = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(s.excluded.isEmpty)
    }
}

@Suite struct SavedResultsBudgetTests {
    @Test func savedScansStayWithinTheBudgetAndEachFolderKeepsItsNewest() throws {
        let box = try Sandbox()
        let base = box.url.appending(path: "snapshots")
        let big = Dictionary(uniqueKeysWithValues: (0..<2_000).map { ("folder\($0)/with/a/long/name", Int64($0)) })
        for (i, root) in ["/synthetic/a", "/synthetic/b"].enumerated() {
            for d in 0..<3 {
                _ = SnapshotStore.save(Snapshot(rootPath: root, date: Date(timeIntervalSince1970: Double(1_000 * i + d)), sizes: big), base: base)
            }
        }
        SnapshotStore.keepWithin(1, base: base)
        #expect(SnapshotStore.history(for: "/synthetic/a", base: base).count == 1)
        #expect(SnapshotStore.history(for: "/synthetic/b", base: base).count == 1)
    }

    @Test func eachKindOfSavedResultIsMeasuredAndClearedOnItsOwn() throws {
        let box = try Sandbox()
        try box.file("clean/last.json", bytes: 5_000)
        try box.file("installers/last.json", bytes: 3_000)
        let parts = SavedResults.parts(
            deepClean: box.url.appending(path: "clean"), installers: box.url.appending(path: "installers"),
            apps: box.url.appending(path: "apps"), projects: box.url.appending(path: "projects"),
            snapshots: box.url.appending(path: "snapshots"), fingerprints: box.url.appending(path: "prints.json"))
        let clean = try #require(parts.first { $0.id == "deepClean" })
        #expect(clean.bytes > 0 && parts.first { $0.id == "apps" }?.bytes == 0)
        #expect(SavedResults.clear(clean).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: box.path + "/clean/last.json"))
        #expect(FileManager.default.fileExists(atPath: box.path + "/installers/last.json"))
    }
}
