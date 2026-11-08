import Foundation
import StorageKit
import Testing

@testable import MyMole

/// Scanning a folder of the test's own again: the earlier map stays on
/// screen until the new one is in, and stays when the new scan is stopped.
@MainActor
@Suite(.serialized) struct DiskMapRescanTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "rescan-\(UUID().uuidString)")
        var mapped: String { root.appending(path: "home").path }

        init() throws {
            for rel in ["home/Projects/App/a.bin", "home/Projects/App/b.bin", "home/Music/c.bin"] {
                let u = root.appending(path: rel)
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 2_000_000).write(to: u)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @MainActor func model() -> StorageModel {
            let m = StorageModel()
            m.snapshotBase = root.appending(path: "snapshots")
            m.protections = UserProtections(root: root.appending(path: "support"))
            return m
        }
    }

    private func settle(_ m: StorageModel) async throws {
        await m.scanJob?.value
        for _ in 0..<400 where m.scanning { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aRescanKeepsTheMapTheFolderAndTheSelection() async throws {
        let box = try Box()
        let m = box.model()
        m.scan(path: box.mapped)
        try await settle(m)
        let app = try #require(m.root?.find(path: box.mapped + "/Projects/App"))
        m.selection = [app.path]
        #expect(m.isHighlighted(.folder(app)))
        m.open(app)
        m.selection = [box.mapped + "/Projects/App/a.bin"]
        let before = try #require(m.root)

        m.rescan()
        // Straight away, and for as long as it runs, the earlier map stays.
        #expect(m.scanning && m.refreshing && !m.showingLive)
        #expect(m.root === before && m.current?.path == box.mapped + "/Projects/App")
        try await settle(m)
        #expect(!m.refreshing && m.root !== before)
        #expect(m.current?.path == box.mapped + "/Projects/App")
        #expect(m.selection == [box.mapped + "/Projects/App/a.bin"])
    }

    @Test func aStoppedRescanLeavesTheEarlierMap() async throws {
        let box = try Box()
        let m = box.model()
        m.scan(path: box.mapped)
        try await settle(m)
        let before = try #require(m.root)
        m.rescan()
        m.cancelScan()
        try await settle(m)
        #expect(m.root === before && !m.refreshing)
    }

    @Test func anotherFolderStartsAFreshMap() async throws {
        let box = try Box()
        let m = box.model()
        m.scan(path: box.mapped)
        try await settle(m)
        m.scan(path: box.mapped + "/Music")
        #expect(!m.refreshing && m.showingLive)
        try await settle(m)
        #expect(m.root?.path == box.mapped + "/Music")
    }
}

@MainActor
@Suite struct DiskMapOpenedScanTests {
    @Test func aSavedScanIsOnlyLookedAt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "opened-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let u = root.appending(path: "home/Movies/film.mov")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: u)
        let tree = StorageScanner.scan(path: root.appending(path: "home").path, workers: 2).root
        let file = root.appending(path: "saved.mymolescan")
        try ScanExport(of: tree).data().write(to: file)

        let m = StorageModel()
        m.snapshotBase = root.appending(path: "snapshots")
        await m.open(exported: file)
        #expect(m.opened?.file == "saved.mymolescan" && m.root?.size == tree.size)
        // Nothing can be chosen, so nothing can be moved.
        m.mark([Marked(path: u.path, name: "film.mov", size: 2_000_000, isFolder: false)])
        #expect(m.marked.isEmpty && !m.canTrash)
        m.trashMarked()
        #expect(FileManager.default.fileExists(atPath: u.path))
    }
}
