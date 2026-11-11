import Foundation
import Testing

@testable import StorageKit

@Suite struct FolderRefreshTests {
    private func child(_ name: String, parent: Folder, bytes: Int64, date: TimeInterval) -> Folder {
        let folder = Folder(name: name, parent: parent)
        folder.ownBytes[folder.inheritedKind ?? .other] = bytes
        folder.smallFileBytes = bytes
        folder.smallFileCount = 1
        folder.ownLatestChange = Date(timeIntervalSince1970: date)
        folder.latestChange = folder.ownLatestChange
        parent.subfolders.append(folder)
        return folder
    }

    @Test func replacingABranchRecomputesAncestorsAndSharesNoMutableNodes() throws {
        let root = Folder(name: "Map", parent: nil, rootPath: "/synthetic/map")
        let scope = child("Current", parent: root, bytes: 100, date: 300)
        let sibling = child("Other", parent: root, bytes: 20, date: 200)
        root.finish()
        let replacement = Folder(name: "Current", parent: nil, rootPath: scope.path)
        replacement.ownBytes[.other] = 30
        replacement.smallFileBytes = 30
        replacement.smallFileCount = 1
        replacement.ownLatestChange = Date(timeIntervalSince1970: 100)
        replacement.latestChange = replacement.ownLatestChange
        replacement.finish()
        let updated = try #require(root.replacingSubtree(at: scope.path, with: replacement))
        #expect(updated.size == 50 && updated.fileCount == 2)
        #expect(updated.latestChange == sibling.latestChange)
        #expect(updated.find(path: sibling.path) !== sibling)
        #expect(updated.find(path: scope.path) !== scope && updated.find(path: scope.path) !== replacement)
        #expect(updated.find(path: scope.path)?.parent === updated)
        root.remove(sibling)
        #expect(updated.size == 50 && updated.find(path: sibling.path) != nil)
    }

    @Test func replacingABranchRetainsInheritedClassificationAndSupportsCancellation() throws {
        let root = Folder(name: "Map", parent: nil, rootPath: "/synthetic/map")
        let cache = child("Caches", parent: root, bytes: 100, date: 1)
        _ = child("Sample", parent: cache, bytes: 20, date: 1)
        root.finish()
        let replacement = Folder(name: "Caches", parent: nil, rootPath: cache.path)
        _ = child("Sample", parent: replacement, bytes: 40, date: 2)
        replacement.finish()
        let updated = try #require(root.replacingSubtree(at: cache.path, with: replacement))
        #expect(updated.find(path: cache.path + "/Sample")?.inheritedKind == .caches)
        #expect(updated.totalBytes[.caches] == 40)
        #expect(root.replacingSubtree(at: cache.path, with: replacement, stop: { true }) == nil)
        #expect(root.size == 120)
    }
}
