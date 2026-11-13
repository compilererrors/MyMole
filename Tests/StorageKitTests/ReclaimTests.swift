import Darwin
import Foundation
import Testing

@testable import StorageKit

/// What removal frees where APFS clones share blocks, with real clones in a
/// test's own folder and synthetic families.
@Suite struct ReclaimTests {
    private func clone(_ box: Sandbox, _ from: String, to: String) throws {
        let target = box.url.appending(path: to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(clonefile(box.url.appending(path: from).path, target.path, 0) == 0)
    }

    private func copy(_ box: Sandbox, _ from: String, to: String) throws {
        let target = box.url.appending(path: to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: box.url.appending(path: from)).write(to: target)
    }

    @Test func aFolderOfClonesOfAFileOutsideItFreesAboutNothing() throws {
        let box = try Box()
        try box.sandbox.file("runtime/base.bin", bytes: 2_000_000)
        try clone(box.sandbox, "runtime/base.bin", to: "devices/one/base.bin")
        try clone(box.sandbox, "runtime/base.bin", to: "devices/two/base.bin")
        let copy = box.sandbox.allocated("runtime/base.bin")

        let whole = StorageScanner.scan(path: box.path, workers: 2).root
        let devices = try #require(whole.find(path: box.path + "/devices"))
        // It occupies two copies, as du counts, and frees nothing while the runtime stays.
        #expect(devices.size == 2 * copy && devices.sharedBytes == 2 * copy)
        #expect(devices.reclaim.bytes == 0)
        // The runtime goes too: the family is complete and one copy is freed.
        #expect(whole.reclaim.bytes == copy && whole.size == 3 * copy)

        // Scanned alone, the clones still know their family isn't all there.
        let alone = StorageScanner.scan(path: box.path + "/devices", workers: 2).root
        #expect(alone.size == 2 * copy && alone.reclaim.bytes == 0)
        let file = try #require(alone.subfolders.first?.listedFiles.first)
        #expect(file.size == copy && file.shared == copy && file.reclaim.bytes == 0)
    }

    @Test func aFolderHoldingAnOriginalAndItsCloneFreesOneCopy() throws {
        let box = try Box()
        try box.sandbox.file("project/a/model.bin", bytes: 1_500_000)
        try clone(box.sandbox, "project/a/model.bin", to: "project/b/model.bin")
        try box.sandbox.file("project/b/notes.bin", bytes: 40_000)
        let copy = box.sandbox.allocated("project/a/model.bin"), notes = box.sandbox.allocated("project/b/notes.bin")

        let root = StorageScanner.scan(path: box.path, workers: 2).root
        let project = try #require(root.find(path: box.path + "/project"))
        let a = try #require(project.find(path: project.path + "/a")), b = try #require(project.find(path: project.path + "/b"))
        #expect(project.size == 2 * copy + notes)
        #expect(project.reclaim.bytes == copy + notes)
        // Either half alone leaves the blocks with the other.
        #expect(a.reclaim.bytes == 0 && b.reclaim.bytes == notes)
        // Chosen together, in either order, they free the copy once.
        #expect((a.reclaim + b.reclaim).bytes == copy + notes)
        #expect((b.reclaim + a.reclaim).bytes == copy + notes)
    }

    @Test func anIndependentCopyAndARewrittenCloneFreeWhatTheyHoldAlone() throws {
        let box = try Box()
        try box.sandbox.file("a.bin", bytes: 1_048_576)
        try copy(box.sandbox, "a.bin", to: "copies/full.bin")
        try clone(box.sandbox, "a.bin", to: "copies/partly.bin")
        // The same bytes written over part of the clone make those blocks its own.
        let path = box.path + "/copies/partly.bin"
        let region = try Data(contentsOf: box.sandbox.url.appending(path: "a.bin"))[0..<131_072]
        let fd = open(path, O_WRONLY)
        #expect(fd >= 0)
        let written = region.withUnsafeBytes { pwrite(fd, $0.baseAddress, region.count, 0) }
        #expect(fsync(fd) == 0 && close(fd) == 0 && written == region.count)

        let copies = try #require(StorageScanner.scan(path: box.path, workers: 1).root.find(path: box.path + "/copies"))
        let own = try #require(FileSpace.sharing(path)?.privateBytes)
        #expect(own >= 131_072 && own < 1_048_576 / 2)
        #expect(copies.reclaim.bytes == box.sandbox.allocated("copies/full.bin") + own)
    }

    @Test func pruningAClonedFolderLeavesItsFamilyOpen() throws {
        let box = try Box()
        try box.sandbox.file("project/a/model.bin", bytes: 1_500_000)
        try clone(box.sandbox, "project/a/model.bin", to: "project/b/model.bin")
        let copy = box.sandbox.allocated("project/a/model.bin")
        let root = StorageScanner.scan(path: box.path, workers: 1).root
        let project = try #require(root.find(path: box.path + "/project"))
        let a = try #require(project.find(path: project.path + "/a")), b = try #require(project.find(path: project.path + "/b"))
        #expect(project.reclaim.bytes == copy)

        // In the Trash its clone still holds the blocks: what stays frees nothing.
        project.remove(a)
        #expect(project.size == copy && project.reclaim.bytes == 0 && root.reclaim.bytes == 0)
        #expect(project.reclaim.open.values.map(\.count) == [1])
        project.restore(a)
        #expect(project.size == 2 * copy && project.reclaim.bytes == copy && root.reclaim.bytes == copy)

        let file = try #require(b.listedFiles.first)
        b.removeFile(named: file.name)
        #expect(project.reclaim.bytes == 0)
        b.restoreFile(file)
        #expect(project.reclaim.bytes == copy && b.reclaim.bytes == 0)
    }

    @Test func emptyingTheTrashCountsWhatClonesElsewhereKeep() throws {
        let box = try Box()
        try box.sandbox.file("Documents/film.mov", bytes: 1_200_000)
        try clone(box.sandbox, "Documents/film.mov", to: "Trash/film copy.mov")
        try clone(box.sandbox, "Documents/film.mov", to: "Trash/folder/film again.mov")
        try box.sandbox.file("Trash/folder/own.bin", bytes: 300_000)
        let copy = box.sandbox.allocated("Documents/film.mov"), own = box.sandbox.allocated("Trash/folder/own.bin")
        let listing = try #require(TrashEmptier.list(box.path + "/Trash"))
        #expect(listing.bytes >= 2 * copy + own)
        #expect(listing.frees >= own && listing.frees < own + copy / 2)
        #expect(listing.entries.first { $0.name == "film copy.mov" }?.reclaim.bytes == 0)
    }

    @Test func projectEntriesFreeWhatTheirFoldersFree() throws {
        let box = try Box()
        try box.sandbox.file("store/package.bin", bytes: 1_100_000)
        try clone(box.sandbox, "store/package.bin", to: "app/node_modules/package.bin")
        let copy = box.sandbox.allocated("store/package.bin")
        let measured = try #require(ProjectAttribution.measure(box.path + "/app/node_modules"))
        #expect(measured.bytes == copy && measured.frees == 0)
        let file = try #require(ProjectAttribution.measure(box.path + "/app/node_modules/package.bin"))
        #expect(file.bytes == copy && file.frees == 0)
        // Read before reclaim was kept, an entry frees its size.
        let old = try JSONDecoder().decode(FootprintEntry.self, from: Data(#"{"path":"/synthetic/a","bytes":5,"modified":0}"#.utf8))
        #expect(old.reclaim == nil && old.frees == 5)
    }

    @Test func familiesCompleteInAnyOrderAndOnlyOnce() {
        let family = FileSpace.Sharing(cloneID: 7, cloneCount: 3, privateBytes: 0, sharesAllBlocks: true)
        let member = Reclaim.file(allocated: 1_000, device: 1, sharing: family)
        let elsewhere = Reclaim.file(allocated: 1_000, device: 2, sharing: family)
        #expect(member.bytes == 0 && (member + member).bytes == 0)
        #expect((member + member + member).bytes == 1_000)
        #expect(((member + member) + (member + elsewhere)).bytes == 1_000)
        // The same clone ID on another volume is another family.
        #expect((member + member + elsewhere).bytes == 0)
    }

    @Test func onlyAFileFlaggedAsSharingCountsItsPrivateSize() {
        // A compressed file reports no private size and no flag: it frees what it takes.
        let compressed = FileSpace.Sharing(cloneID: 9, cloneCount: 0, privateBytes: nil)
        #expect(Reclaim.file(allocated: 4_096, device: 1, sharing: compressed).bytes == 4_096)
        #expect(Reclaim.file(allocated: 4_096, device: 1, sharing: nil).bytes == 4_096)
        // The last of a family holds every block alone.
        let last = FileSpace.Sharing(cloneID: 9, cloneCount: 1, privateBytes: 0, sharesAllBlocks: true)
        #expect(Reclaim.file(allocated: 4_096, device: 1, sharing: last).bytes == 4_096)
        // A partly shared clone counts what it holds alone and joins no family.
        let partly = FileSpace.Sharing(cloneID: 9, cloneCount: 1, privateBytes: 512, sharesAllBlocks: false)
        let reclaim = Reclaim.file(allocated: 4_096, device: 1, sharing: partly)
        #expect(reclaim.bytes == 512 && reclaim.open.isEmpty)
    }

    @Test func manyOpenFamiliesOnlyLowerTheEstimate() {
        var sum = Reclaim()
        for id in 0..<UInt64(Reclaim.openLimit + 10) {
            let sharing = FileSpace.Sharing(cloneID: id, cloneCount: 2, privateBytes: 0, sharesAllBlocks: true)
            sum.add(.file(allocated: 100 + Int64(id), device: 1, sharing: sharing))
        }
        #expect(sum.open.count == Reclaim.openLimit && sum.bytes == 0)
        #expect(sum.open.keys.contains { $0.id == UInt64(Reclaim.openLimit + 9) })
    }

    /// A sandbox whose real path is used throughout, so scanned paths match.
    private struct Box {
        let sandbox: Sandbox
        let path: String
        init() throws {
            sandbox = try Sandbox()
            path = URL(fileURLWithPath: sandbox.path).resolvingSymlinksInPath().path
        }
    }
}
