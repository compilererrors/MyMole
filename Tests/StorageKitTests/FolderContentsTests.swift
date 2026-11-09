import Foundation
import Testing

@testable import StorageKit

@Suite struct FolderContentsTests {
    @Test func evidenceRejectsReplacedLeafAndReplacedParentEvenWithTheSameChild() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "folder-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appending(path: "parent")
        let item = parent.appending(path: "chosen.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data([1]).write(to: item)
        let evidence = try #require(FolderContents.capture(item.path))
        #expect(evidence.isCurrent)
        let oldParent = root.appending(path: "old-parent")
        try FileManager.default.moveItem(at: parent, to: oldParent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldParent.appending(path: "chosen.txt"), to: item)
        #expect(!evidence.isCurrent)
        let fresh = try #require(FolderContents.capture(item.path))
        try FileManager.default.moveItem(at: item, to: root.appending(path: "original.txt"))
        try Data([2]).write(to: item)
        #expect(!fresh.isCurrent)
    }

    @Test func includesHiddenSmallAndEmptyItemsWithoutFollowingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "folder-contents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "folder")
        try FileManager.default.createDirectory(at: folder.appending(path: "empty"), withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appending(path: "small.txt"))
        try Data([2]).write(to: folder.appending(path: ".hidden"))
        try Data([3]).write(to: root.appending(path: "outside.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link"), withDestinationURL: root)
        let items = try #require(FolderContents.read(folder.path))
        #expect(Set(items.map { ($0.path as NSString).lastPathComponent }) == ["empty", "small.txt", ".hidden", "link"])
        #expect(items.first(where: { $0.path.hasSuffix("/empty") })?.isFolder == true)
        #expect(items.first(where: { $0.path.hasSuffix("/link") })?.isFolder == false)
        #expect(FolderContents.read(folder.path, limit: 2) == nil)
        let progress = ScanProgress()
        progress.cancel()
        #expect(FolderContents.read(folder.path, progress: progress) == nil)
        #expect(FolderContents.read(folder.appending(path: "missing").path) == nil)
    }
}
