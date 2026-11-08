import Foundation
import StorageKit
import Synchronization
import Testing

@testable import MyMole

/// A move and a scan of the same pane at once, on synthetic files of the
/// test's own. The scan is held by the test, so it never walks a real folder.
@MainActor
@Suite struct ProjectsMoveAndScanTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "move-scan-\(UUID().uuidString)")
        var store: URL { root.appending(path: "store") }
        var project: String { root.appending(path: "App").path }
        var build: String { project + "/.build" }

        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ rel: String) throws {
            let u = root.appending(path: rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 5, count: 2_000).write(to: u)
        }

        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.path + "/" + rel) }

        private func item(_ name: String, _ category: FootprintCategory) -> FootprintItem {
            FootprintItem(
                id: "inside:" + name, category: category, title: name, location: project, attribution: .inside,
                entries: [FootprintEntry(path: project + "/" + name, bytes: 2_000, modified: .distantPast)])
        }

        @MainActor func model() -> ProjectsModel {
            let footprint = ProjectFootprint(
                project: DevProject(path: project, markers: ["package.json"]),
                items: [item(".build", .build), item("node_modules", .dependencies)])
            let m = ProjectsModel(
                footprints: [footprint], base: store, defaults: testDefaults(in: store), logURL: root.appending(path: "history.json"))
            m.trashBackend = testBin(root)
            m.jobs = TrashJobs()
            return m
        }
    }

    private func hasBuild(_ m: ProjectsModel) -> Bool {
        m.footprints.first?.items.contains { $0.title == ".build" } ?? false
    }

    @Test func nothingMovesWhileAScanRuns() async throws {
        let box = Box()
        try box.file("App/.build/out")
        let m = box.model()
        let gate = DispatchSemaphore(value: 0)
        let listing = ProjectListing(footprints: m.footprints)
        m.listProjects = { _, _, _, _, _, _ in
            gate.wait()
            return listing
        }
        m.chosen = [box.build]
        m.scan()
        #expect(m.trashBlocker == "Wait for the scan to finish.")
        m.trashChosen()
        #expect(!m.trashing)
        #expect(m.notice?.text == "Nothing was moved: a scan is running. Try again when it's done.")
        gate.signal()
        await m.scanJob?.value
        for _ in 0..<400 where m.scanning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(box.exists("App/.build/out"))

        // The scan over, the same choice goes.
        #expect(m.trashBlocker == nil)
        m.trashChosen()
        while m.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!box.exists("App/.build") && !hasBuild(m))
    }

    @Test func aProjectBeingMeasuredWhenItsEntryGoesIsMeasuredAgain() async throws {
        let box = Box()
        try box.file("App/.build/out")
        let m = box.model()
        let before = try #require(m.footprints.first)
        var after = before
        after.remove(paths: [box.build])
        let fresh = after
        let gate = DispatchSemaphore(value: 0)
        let runs = Mutex(0)
        let finished = Mutex(0)
        m.measureProject = { _, _, _ in
            let n = runs.withLock { r in defer { r += 1 }; return r }
            defer { finished.withLock { $0 += 1 } }
            // The first measure began before the move, and still has what went.
            if n == 0 {
                gate.wait()
                return before
            }
            return fresh
        }
        m.rescan(box.project)
        while runs.withLock({ $0 }) < 1 { try await Task.sleep(for: .milliseconds(5)) }
        m.chosen = [box.build]
        m.trashChosen()
        while m.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!box.exists("App/.build"))
        for _ in 0..<400 where runs.withLock({ $0 }) < 2 || !m.rescanning.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(runs.withLock { $0 } == 2)
        // The older measure ends last and doesn't bring the entry back.
        gate.signal()
        for _ in 0..<400 where finished.withLock({ $0 }) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!hasBuild(m) && m.rescanning.isEmpty)
    }

    @Test func anUndoDuringAScanStartsTheScanOver() async throws {
        let box = Box()
        try box.file("App/.build/out")
        let m = box.model()
        let whole = try #require(m.footprints.first)
        m.chosen = [box.build]
        m.trashChosen()
        while m.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!box.exists("App/.build") && !hasBuild(m))

        // A scan walks the project while its folder is in the Trash, and
        // is still under way when Undo puts the folder back.
        var without = whole
        without.remove(paths: [box.build])
        let early = ProjectListing(footprints: [without])
        let late = ProjectListing(footprints: [whole])
        let gate = DispatchSemaphore(value: 0)
        let runs = Mutex(0)
        m.listProjects = { _, _, _, _, _, _ in
            let n = runs.withLock { r in defer { r += 1 }; return r }
            if n == 0 {
                gate.wait()
                return early
            }
            return late
        }
        m.scan()
        while runs.withLock({ $0 }) < 1 { try await Task.sleep(for: .milliseconds(5)) }
        m.undoTrash()
        while m.trashing { try await Task.sleep(for: .milliseconds(10)) }
        gate.signal()
        for _ in 0..<400 where m.scanning || runs.withLock({ $0 }) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(runs.withLock { $0 } == 2)
        #expect(box.exists("App/.build/out") && hasBuild(m))
    }
}

/// The disk map writes its moves to the history it was given.
@MainActor
@Suite struct DiskMapHistoryTests {
    @Test func aMoveAndItsUndoAreWrittenToTheGivenHistory() async throws {
        let box = FileManager.default.temporaryDirectory.appending(path: "diskmap-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: box) }
        let folder = box.appending(path: "home/old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2_000).write(to: folder.appending(path: "data"))
        let log = box.appending(path: "history.json")

        let model = StorageModel()
        model.trashBackend = testBin(box)
        model.jobs = TrashJobs()
        model.protections = UserProtections(root: box.appending(path: "support"))
        model.logURL = log
        model.marked[folder.path] = Marked(path: folder.path, name: "old", size: 2_000, isFolder: true)
        model.trashMarked()
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let moved = try #require(CleanupLog.load(from: log).first)
        #expect(moved.source == "Disk Map" && moved.items == 1 && moved.bytes == 2_000 && moved.restored == 0)

        model.undoTrash()
        while model.trashing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: folder.path + "/data"))
        let undone = try #require(CleanupLog.load(from: log).first)
        #expect(undone.id == moved.id && undone.restored == 1)
    }
}
