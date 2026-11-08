import Foundation
import StorageKit
import Testing

@testable import MyMole

/// The checks a move from the disk map passes, on synthetic files of the
/// test's own: what another pane keeps stays.
@Suite struct DiskMapGateTests {
    private final class Box {
        let url = FileManager.default.temporaryDirectory.appending(path: "diskmap-gate-\(UUID().uuidString)")
        var protections: UserProtections { UserProtections(root: url.appending(path: "support")) }

        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult func file(_ rel: String) throws -> String {
            let u = url.appending(path: rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 2_000).write(to: u)
            return u.path
        }

        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url.path + "/" + rel) }
    }

    @Test func whatAnotherPaneKeepsStaysAndTheRestGoes() throws {
        let box = Box()
        try box.file("home/Library/Caches/com.vendor.Editor/blob")
        try box.file("home/old/data")
        try box.file("home/app/node_modules/local-only/x")
        let home = box.url.path + "/home"
        let (cache, old, app) = (home + "/Library/Caches/com.vendor.Editor", home + "/old", home + "/app")
        try CleanKeepList(paths: [cache]).save(to: box.protections.keepList)
        var rules = ProjectRules()
        rules.keepPaths = [app + "/node_modules/local-only"]
        try ProjectStore.saveRules(rules, base: box.protections.projectBase)

        let gate = StorageModel.gate(folders: [cache, old, app], protections: box.protections)
        let out = Trasher.moveToTrash([cache, old, app], through: gate, backend: testBin(box.url))
        #expect(out.moved.map(\.original.path) == [old])
        // Kept itself, and a folder holding something kept.
        #expect(Set(out.failed.map(\.path)) == [cache, app] && out.failed.allSatisfy { $0.reason == "Kept" })
        #expect(box.exists("home/Library/Caches/com.vendor.Editor/blob") && box.exists("home/app/node_modules/local-only/x"))
        #expect(!box.exists("home/old"))
    }

    @Test func aKeepListThatCantBeReadStopsTheMove() throws {
        let box = Box()
        try box.file("home/old/data")
        let list = box.protections.keepList
        try FileManager.default.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: list)
        let old = box.url.path + "/home/old"
        let out = Trasher.moveToTrash([old], through: StorageModel.gate(folders: [old], protections: box.protections), backend: testBin(box.url))
        #expect(out.moved.isEmpty && out.failed.first?.reason == Trasher.protectionsUnreadable)
        #expect(box.exists("home/old/data"))
    }

    @Test func anItemThatChangedKindSinceItWasMarkedStays() throws {
        let box = Box()
        let file = try box.file("home/thing")
        // Marked as a folder, now a file.
        let out = Trasher.moveToTrash([file], through: StorageModel.gate(folders: [file], protections: box.protections), backend: testBin(box.url))
        #expect(out.moved.isEmpty && box.exists("home/thing"))
    }
}
