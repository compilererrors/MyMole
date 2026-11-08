import Foundation
import StorageKit
import Testing

@testable import MyMole

/// The Duplicates pane on folders of the test's own.
@MainActor
@Suite struct DuplicatesModelTests {
    final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "duplicates-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }
        var log: URL { root.appending(path: "history.json") }

        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ rel: String, fill: UInt8, bytes: Int = 40_000) throws {
            let url = URL(fileURLWithPath: home + "/" + rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: fill, count: bytes).write(to: url)
        }

        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: home + "/" + rel) }

        @MainActor func model() -> DuplicatesModel {
            let m = DuplicatesModel(home: home, roots: [home + "/Documents", home + "/Downloads"], minimum: 10_000, logURL: log, trash: testBin(root))
            m.jobs = TrashJobs()
            m.protections = UserProtections(root: root.appending(path: "lists"))
            return m
        }
    }

    private func searched(_ box: Box) async throws -> DuplicatesModel {
        try box.file("Documents/report.bin", fill: 1)
        try box.file("Downloads/report.bin", fill: 1)
        try box.file("Downloads/report copy.bin", fill: 1)
        try box.file("Documents/other.bin", fill: 2)
        let model = box.model()
        model.scan()
        await model.scanJob?.value
        return model
    }

    @Test func oneCopyOfEveryGroupAlwaysStays() async throws {
        let box = Box()
        let model = try await searched(box)
        let group = try #require(model.groups.first)
        #expect(model.groups.count == 1 && group.files.count == 3 && model.spareBytes == 2 * group.bytes)
        #expect(model.selection == [group.id])

        // Two of three can be ticked; the third is refused, and says why.
        let paths = group.files.map(\.path)
        model.toggle(paths[0])
        model.toggle(paths[1])
        model.toggle(paths[2])
        #expect(model.chosen == [paths[0], paths[1]] && model.notice != nil)

        // Choosing all but one in one go keeps exactly one.
        model.chooseAll(keeping: .newest)
        #expect(model.chosen.count == 2 && !model.chosen.contains(group.files.last!.path))
        model.chooseAll(keeping: .oldest)
        #expect(model.chosen.count == 2 && !model.chosen.contains(group.files.first!.path))
    }

    @Test func theChosenCopiesGoToTheTrashAndUndoPutsThemBack() async throws {
        let box = Box()
        let model = try await searched(box)
        let group = try #require(model.groups.first)
        model.chooseAll(keeping: .oldest)
        let going = model.chosen

        model.trashChosen()
        await model.trashJob?.value
        #expect(going.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        #expect(FileManager.default.fileExists(atPath: group.files[0].path) && box.exists("Documents/other.bin"))
        // With one copy left it isn't a duplicate any more.
        #expect(model.groups.isEmpty && model.chosen.isEmpty && model.canUndo)
        let record = try #require(CleanupLog.load(from: box.log).first)
        #expect(record.source == DuplicatesModel.source && record.items == 2 && record.bytes == 2 * group.bytes)

        model.undoTrash(run: record.id)
        await model.trashJob?.value
        await model.scanJob?.value
        #expect(going.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(model.groups.count == 1 && model.groups[0].files.count == 3 && !model.canUndo)
        #expect(CleanupLog.load(from: box.log).first?.restored == 2)
    }

    @Test func aCopyIsLeftWhenTheOneThatWasToStayChanged() async throws {
        let box = Box()
        let model = try await searched(box)
        let group = try #require(model.groups.first)
        model.chooseAll(keeping: .oldest)
        // The copy that stays is rewritten after the search: the others aren't spare any more.
        try Data(repeating: 9, count: 40_000).write(to: URL(fileURLWithPath: group.files[0].path))

        model.trashChosen()
        await model.trashJob?.value
        #expect(group.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(!model.canUndo && model.notice?.text.hasPrefix("Nothing was moved") == true)
    }

    @Test func theCopyInAChosenFolderStays() async throws {
        let box = Box()
        let model = try await searched(box)
        model.chooseAll(keeping: .inFolder(box.home + "/Documents"))
        #expect(model.chosen == [box.home + "/Downloads/report.bin", box.home + "/Downloads/report copy.bin"])
        // A folder with no copy of the file chooses nothing of it.
        model.chosen = []
        model.chooseAll(keeping: .inFolder(box.home + "/Elsewhere"))
        #expect(model.chosen.isEmpty && model.notice != nil)
    }

    @Test func aKeepSavedElsewhereIsMarkedHereAtOnce() async throws {
        let box = Box()
        let model = try await searched(box)
        let copy = box.home + "/Downloads/report.bin"
        model.choose([copy])
        #expect(model.chosen.contains(copy))
        // Another pane keeps it: no new search is needed for it to stay.
        _ = try CleanKeepList.update(at: model.protections.keepList) { $0.paths.insert(copy) }
        for _ in 0..<200 where model.chosen.contains(copy) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.chosen.contains(copy) && model.keep.protects(copy))
    }
}
