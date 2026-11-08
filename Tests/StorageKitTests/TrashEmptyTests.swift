import Foundation
import Testing

@testable import StorageKit

/// Emptying a Trash folder of the test's own: only what was listed goes, and
/// nothing outside it.
@Suite struct TrashEmptyTests {
    final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "trash-empty-\(UUID().uuidString)")
        var trash: String { root.appending(path: "Trash").path }
        var outside: String { root.appending(path: "outside").path }

        init() throws {
            try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        }

        deinit {
            // Folders a test left read-only are opened up so the box can go.
            if let all = FileManager.default.enumerator(atPath: root.path) {
                for case let rel as String in all { chmod(root.path + "/" + rel, 0o700) }
            }
            try? FileManager.default.removeItem(at: root)
        }

        func file(_ path: String, bytes: Int = 4_096) throws {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
        }

        func exists(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0
        }
    }

    @Test func removesWhatWasListedAndMeasuresIt() throws {
        let box = try Box()
        try box.file(box.trash + "/report.pdf", bytes: 20_000)
        try box.file(box.trash + "/old-project/src/main.swift")
        try box.file(box.trash + "/old-project/build/app.bin", bytes: 50_000)
        try box.file(box.trash + "/.DS_Store")

        let listing = try #require(TrashEmptier.list(box.trash))
        #expect(listing.entries.map(\.name) == ["old-project", "report.pdf"])
        #expect(listing.bytes >= 70_000)

        let out = TrashEmptier.empty(listing)
        #expect(out == TrashEmptier.Outcome(removed: 2, bytes: listing.bytes, failed: 0, skipped: 0))
        #expect(!box.exists(box.trash + "/report.pdf") && !box.exists(box.trash + "/old-project"))
        // Finder's record of where things came from stays, and so does the folder.
        #expect(box.exists(box.trash + "/.DS_Store"))
    }

    @Test func aLinkGoesButNotWhatItPointsTo() throws {
        let box = try Box()
        try box.file(box.outside + "/keep/notes.txt")
        try FileManager.default.createSymbolicLink(atPath: box.trash + "/link-to-folder", withDestinationPath: box.outside + "/keep")
        try FileManager.default.createDirectory(atPath: box.trash + "/folder", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: box.trash + "/folder/inner-link", withDestinationPath: box.outside + "/keep")

        let out = TrashEmptier.empty(try #require(TrashEmptier.list(box.trash)))
        #expect(out.removed == 2 && out.failed == 0)
        #expect(!box.exists(box.trash + "/link-to-folder") && !box.exists(box.trash + "/folder"))
        #expect(box.exists(box.outside + "/keep/notes.txt"))
    }

    @Test func whatArrivedOrWasReplacedSinceTheListingStays() throws {
        let box = try Box()
        try box.file(box.trash + "/a.txt")
        try box.file(box.trash + "/b.txt")
        let listing = try #require(TrashEmptier.list(box.trash))

        // b.txt is replaced by another file of the same name, and c.txt arrives.
        try FileManager.default.removeItem(atPath: box.trash + "/b.txt")
        try box.file(box.trash + "/b.txt", bytes: 9_000)
        try box.file(box.trash + "/c.txt")

        let out = TrashEmptier.empty(listing)
        #expect(out.removed == 1 && out.skipped == 1 && out.failed == 0)
        #expect(!box.exists(box.trash + "/a.txt"))
        #expect(box.exists(box.trash + "/b.txt") && box.exists(box.trash + "/c.txt"))
    }

    @Test func aStopLeavesTheRest() throws {
        let box = try Box()
        for name in ["a", "b", "c"] { try box.file(box.trash + "/" + name) }
        let listing = try #require(TrashEmptier.list(box.trash))
        var asked = 0
        let out = TrashEmptier.empty(listing) {
            asked += 1
            return asked > 1
        }
        #expect(out.removed == 1 && out.skipped == 2)
        #expect(!box.exists(box.trash + "/a") && box.exists(box.trash + "/b") && box.exists(box.trash + "/c"))
    }

    @Test func aReadOnlyFolderIsOpenedUpAndRemoved() throws {
        let box = try Box()
        try box.file(box.trash + "/module-cache/pkg/v1/lib.go")
        #expect(chmod(box.trash + "/module-cache/pkg/v1", 0o555) == 0)
        #expect(chmod(box.trash + "/module-cache/pkg", 0o555) == 0)

        let out = TrashEmptier.empty(try #require(TrashEmptier.list(box.trash)))
        #expect(out.removed == 1 && out.failed == 0)
        #expect(!box.exists(box.trash + "/module-cache"))
    }

    @Test func aLockedFileIsReportedAndStays() throws {
        let box = try Box()
        try box.file(box.trash + "/locked.txt")
        try box.file(box.trash + "/plain.txt")
        #expect(chflags(box.trash + "/locked.txt", UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(box.trash + "/locked.txt", 0) }

        let out = TrashEmptier.empty(try #require(TrashEmptier.list(box.trash)))
        #expect(out.removed == 1 && out.failed == 1)
        #expect(box.exists(box.trash + "/locked.txt") && !box.exists(box.trash + "/plain.txt"))
    }

    @Test func aTrashThatIsALinkOrMissingIsNotListed() throws {
        let box = try Box()
        try box.file(box.outside + "/real/file.txt")
        let link = box.root.appending(path: "LinkedTrash").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: box.outside + "/real")
        #expect(TrashEmptier.list(link) == nil)
        #expect(TrashEmptier.list(box.root.appending(path: "nowhere").path) == nil)
        #expect(TrashEmptier.list("relative/path") == nil)

        // A listing whose folder became a link since: nothing goes.
        try box.file(box.trash + "/a.txt")
        let listing = try #require(TrashEmptier.list(box.trash))
        let moved = box.root.appending(path: "TrashMoved").path
        try FileManager.default.moveItem(atPath: box.trash, toPath: moved)
        try FileManager.default.createSymbolicLink(atPath: box.trash, withDestinationPath: box.outside + "/real")
        let out = TrashEmptier.empty(listing)
        #expect(out.removed == 0 && out.failed == 1)
        #expect(box.exists(box.outside + "/real/file.txt") && box.exists(moved + "/a.txt"))
    }

    @Test func aFolderThatCantBeOpenedMakesTheSizeALowerBound() throws {
        let box = try Box()
        try box.file(box.trash + "/whole/a", bytes: 8_000)
        try box.file(box.trash + "/closed/inner/b", bytes: 8_000)
        #expect(chmod(box.trash + "/closed/inner", 0) == 0)
        let listing = try #require(TrashEmptier.list(box.trash))
        #expect(listing.partial)
        #expect(listing.entries.first { $0.name == "closed" }?.partial == true)
        #expect(listing.entries.first { $0.name == "whole" }?.partial == false)
    }

    @Test func aStopInsideABigFolderStartsNothingMore() throws {
        let box = try Box()
        for i in 0..<50 { try box.file(box.trash + "/big/f\(i)") }
        try box.file(box.trash + "/later.bin")
        let listing = try #require(TrashEmptier.list(box.trash))
        var asked = 0
        // Stopped after a few files of the big folder.
        let out = TrashEmptier.empty(listing) {
            asked += 1
            return asked > 5
        }
        #expect(out.partly == 1 && out.removed == 0)
        #expect(box.exists(box.trash + "/big") && box.exists(box.trash + "/later.bin"))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: box.trash + "/big"))?.count ?? 0
        #expect(left > 0 && left < 50)
    }
}

@Suite struct VolumeTrashTests {
    @Test func theUsersTrashOnAnotherDiskIsMeasuredOnly() throws {
        let box = try Sandbox()
        try box.file("Disk/.Trashes/\(getuid())/old.mov", bytes: 5_000)
        try box.folder("Empty/.Trashes/\(getuid())")
        let found = TrashEmptier.otherTrashes(on: [(box.path + "/Disk", "Disk"), (box.path + "/Empty", "Empty"), ("/", "Startup")])
        #expect(found.map(\.name) == ["Disk"] && found.first?.count == 1)
        #expect(FileManager.default.fileExists(atPath: box.path + "/Disk/.Trashes/\(getuid())/old.mov"))
    }
}
