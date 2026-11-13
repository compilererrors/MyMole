import Darwin
import Foundation
import Testing

@testable import MyMole
@testable import StorageKit

/// Disk Map, Projects and Trash count what a removal frees where APFS
/// clones share blocks, with real clones in a test's own folder.
@MainActor @Suite struct ClonedRemovalTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "cloned-removal-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }
        let log: URL

        init() throws {
            log = root.appending(path: "history.json")
            try FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ rel: String, bytes: Int) throws {
            let url = root.appending(path: "home/" + rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data(count: bytes)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
            try data.write(to: url)
        }

        func clone(_ from: String, to: String) throws {
            let target = root.appending(path: "home/" + to)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(clonefile(home + "/" + from, target.path, 0) == 0)
        }

        func allocated(_ rel: String) -> Int64 {
            var st = stat()
            lstat(home + "/" + rel, &st)
            return Int64(st.st_blocks) * 512
        }

        @MainActor func model() -> StorageModel {
            let model = StorageModel()
            model.snapshotBase = root.appending(path: "snapshots")
            model.protections = UserProtections(root: root.appending(path: "support"))
            model.logURL = log
            model.trashBackend = testBin(root)
            model.jobs = TrashJobs()
            model.scanBudget = ScanBudget(slots: 1)
            return model
        }
    }

    private func wait(_ check: @MainActor () -> Bool) async throws {
        for _ in 0..<1_000 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "SyntheticCloneTimeout", code: 1)
    }

    private func marked(_ model: StorageModel, _ path: String) throws -> Marked {
        let folder = try #require(model.root?.find(path: path))
        return Marked(path: folder.path, name: folder.name, size: folder.size, isFolder: true)
    }

    @Test func clonesOfAFileThatStaysFreeAboutNothingAndAreRecordedSo() async throws {
        let box = try Box()
        try box.file("runtime/base.bin", bytes: 2_000_000)
        try box.clone("runtime/base.bin", to: "devices/one/base.bin")
        try box.clone("runtime/base.bin", to: "devices/two/base.bin")
        let copy = box.allocated("runtime/base.bin")
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value

        let devices = try marked(model, box.home + "/devices")
        model.mark([devices])
        await model.warmRemovalHints()
        #expect(model.markedBytes == 2 * copy && model.markedFrees == 0)
        #expect(model.currentRemovalHints?.itemFrees[devices.path] == 0)
        #expect(Freeing.phrase(model.markedBytes, frees: model.markedFrees).contains("frees about"))

        model.trashMarked()
        try await wait { !model.trashing }
        CleanupLog.flush()
        let record = try #require(CleanupLog.load(from: box.log).first)
        #expect(record.items == 1 && record.bytes == 0)
        #expect(model.notice?.text.contains("frees about") == true)

        model.undoTrash()
        try await wait { !model.trashing && !model.canUndo }
        CleanupLog.flush()
        #expect(CleanupLog.load(from: box.log).first?.restoredBytes == 0)
        #expect(FileManager.default.fileExists(atPath: box.home + "/devices/one/base.bin"))
    }

    @Test func anOriginalAndItsCloneChosenTogetherFreeOneCopy() async throws {
        let box = try Box()
        try box.file("project/a/model.bin", bytes: 1_500_000)
        try box.clone("project/a/model.bin", to: "project/b/model.bin")
        let copy = box.allocated("project/a/model.bin")
        let model = box.model()
        model.scan(path: box.home)
        await model.scanJob?.value

        let a = try marked(model, box.home + "/project/a"), b = try marked(model, box.home + "/project/b")
        model.mark([a])
        await model.warmRemovalHints()
        #expect(model.markedFrees == 0)
        // A file chosen on its own is read as it is now.
        model.mark([Marked(path: b.path + "/model.bin", name: "model.bin", size: copy, isFolder: false)])
        await model.warmRemovalHints()
        #expect(model.markedFrees == copy)
        model.unmark([b.path + "/model.bin"])
        model.mark([b])
        await model.warmRemovalHints()
        #expect(model.markedBytes == 2 * copy && model.markedFrees == copy)

        model.trashMarked()
        try await wait { !model.trashing }
        CleanupLog.flush()
        #expect(CleanupLog.load(from: box.log).first?.bytes == copy)
    }

    @Test func projectChoicesFreeOneCopyOfClonesChosenTogether() throws {
        let copy: Int64 = 1_000_000
        let sharing = FileSpace.Sharing(cloneID: 3, cloneCount: 2, privateBytes: 0, sharesAllBlocks: true)
        let member = Reclaim.file(allocated: copy, device: 1, sharing: sharing)
        let item = FootprintItem(id: "inside:node_modules", category: .dependencies, title: "node_modules", location: "/synthetic/app",
                                 attribution: .inside, entries: [])
        func chosen(_ path: String) -> ProjectsModel.Chosen {
            ProjectsModel.Chosen(project: "/synthetic/app", item: item,
                                 entry: FootprintEntry(path: path, bytes: copy, modified: .distantPast, reclaim: member))
        }
        #expect(ProjectsModel.frees([chosen("/synthetic/app/a")]) == 0)
        #expect(ProjectsModel.frees([chosen("/synthetic/app/a"), chosen("/synthetic/app/b")]) == copy)
        // An entry read before frees were kept counts its size.
        let plain = ProjectsModel.Chosen(project: "/synthetic/app", item: item,
                                         entry: FootprintEntry(path: "/synthetic/app/c", bytes: 500, modified: .distantPast))
        #expect(ProjectsModel.frees([plain]) == 500)
    }

    @Test func freeingIsNamedOnlyWhenItDiffersNoticeably() {
        let gb: Int64 = 1_000_000_000
        #expect(Freeing.phrase(4 * gb, frees: nil) == ByteSize.format(4 * gb))
        #expect(Freeing.phrase(4 * gb, frees: 4 * gb) == ByteSize.format(4 * gb))
        #expect(Freeing.phrase(4 * gb, frees: 4 * gb - 500_000) == ByteSize.format(4 * gb))
        #expect(Freeing.phrase(4 * gb, frees: gb) == "\(ByteSize.format(4 * gb)), frees about \(ByteSize.format(gb))")
        #expect(Freeing.phrase(3_000_000, frees: 0).hasSuffix("frees about \(ByteSize.format(0))"))
        #expect(TrashModel.report(TrashEmptier.Outcome(removed: 1, bytes: 4 * gb, frees: gb)).contains("frees about"))
    }
}
