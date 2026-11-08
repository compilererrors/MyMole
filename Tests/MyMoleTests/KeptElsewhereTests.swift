import Foundation
import StorageKit
import Testing

@testable import MyMole

/// What's kept in Deep Clean or Projects stays in Installers, Duplicates and
/// Startup Items too, and a keep list that can't be read stops their moves.
/// Every folder, list and Trash is the test's own.
@MainActor
@Suite struct KeptElsewhereTests {
    final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "kept-elsewhere-\(UUID().uuidString)")
        var home: String { root.appending(path: "home").path }
        var log: URL { root.appending(path: "history.json") }
        var protections: UserProtections { UserProtections(root: root.appending(path: "lists")) }

        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ rel: String, fill: UInt8 = 1, bytes: Int = 40_000) throws -> String {
            let url = URL(fileURLWithPath: home + "/" + rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: fill, count: bytes).write(to: url)
            return url.path
        }

        func keep(_ paths: String...) throws {
            _ = try CleanKeepList.update(at: protections.keepList) { $0.paths.formUnion(paths) }
        }

        /// A keep list that's there but isn't one.
        func breakKeepList() throws {
            try FileManager.default.createDirectory(at: protections.keepList.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not a keep list".utf8).write(to: protections.keepList)
        }

        func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
    }

    // MARK: Installers

    private func installers(_ box: Box) -> InstallersModel {
        let m = InstallersModel(
            locations: [InstallerLocation(path: box.home + "/Downloads", depth: 1)], base: box.root.appending(path: "store"),
            logURL: box.log, trash: testBin(box.root))
        m.jobs = TrashJobs()
        m.protections = box.protections
        return m
    }

    @Test func installersLeaveWhatIsKeptAndCanKeepItThemselves() async throws {
        let box = Box()
        let kept = try box.file("Downloads/Kept.dmg")
        let later = try box.file("Downloads/Later.pkg")
        let go = try box.file("Downloads/Go.pkg")
        try box.keep(kept)
        let model = installers(box)
        model.scan()
        await model.scanJob?.value

        // What's kept can't be chosen.
        model.chooseAll()
        #expect(model.chosen == [later, go])
        model.toggle(kept)
        #expect(!model.chosen.contains(kept))

        // Kept from here after it was chosen: it stays chosen no longer, and stays on disk.
        model.keepAlways([later])
        #expect(model.chosen == [go] && model.keep.isOnOwnList(later))
        model.chosen.insert(later)
        model.trashChosen()
        await model.trashJob?.value
        #expect(box.exists(kept) && box.exists(later) && !box.exists(go))
        #expect(try CleanKeepList.load(from: box.protections.keepList).paths == [kept, later])

        model.undoTrash()
        await model.trashJob?.value
    }

    @Test func installersMoveNothingWhileTheKeepListCantBeRead() async throws {
        let box = Box()
        let go = try box.file("Downloads/Go.pkg")
        let model = installers(box)
        model.scan()
        await model.scanJob?.value
        model.chosen = [go]
        try box.breakKeepList()
        model.trashChosen()
        await model.trashJob?.value
        #expect(box.exists(go) && model.trashBlocker != nil && model.notice != nil)
    }

    // MARK: Duplicates

    private func duplicates(_ box: Box) -> DuplicatesModel {
        let m = DuplicatesModel(home: box.home, roots: [box.home + "/Documents"], minimum: 10_000, logURL: box.log, trash: testBin(box.root))
        m.jobs = TrashJobs()
        m.protections = box.protections
        return m
    }

    @Test func aKeptCopyIsNeverChosenAndStaysWhenItsListChangesMidway() async throws {
        let box = Box()
        let a = try box.file("Documents/a.bin")
        let b = try box.file("Documents/b.bin")
        let c = try box.file("Documents/c.bin")
        try box.keep(a)
        let model = duplicates(box)
        model.scan()
        await model.scanJob?.value
        #expect(model.groups.first?.files.count == 3)

        model.toggle(a)
        #expect(model.chosen.isEmpty && model.notice != nil)
        model.chooseAll(keeping: .newest)
        #expect(!model.chosen.contains(a))

        // Kept in Deep Clean after it was chosen here: the move reads the list again.
        model.chosen = [b, c]
        try box.keep(b)
        model.trashChosen()
        await model.trashJob?.value
        #expect(box.exists(a) && box.exists(b) && !box.exists(c))

        model.undoTrash()
        await model.trashJob?.value
    }

    // MARK: Startup Items

    @Test func aKeptLoginAgentCantBeChosenOrMoved() async throws {
        let box = Box()
        let path = box.home + "/Library/LaunchAgents/com.vendor.gone.plist"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.vendor.gone", "Program": "/opt/vendor/gone"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path))
        try box.keep(path)
        let model = StartupModel(home: box.home, root: box.root.appending(path: "system").path, logURL: box.log, trash: testBin(box.root))
        model.readLive = { nil }
        model.jobs = TrashJobs()
        model.protections = box.protections
        model.load()
        await model.job?.value

        model.chooseLeftovers()
        model.toggle(path)
        #expect(model.chosen.isEmpty)
        model.chosen = [path]
        model.trashChosen()
        await model.job?.value
        #expect(box.exists(path))
    }
}
