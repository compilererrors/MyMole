import Darwin
import Foundation
import Testing

@testable import StorageKit

/// A search that couldn't read a folder never passes for a complete one.
@Suite struct ProjectListingTests {
    private func sealed(_ path: String) throws -> () -> Void {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        return { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
    }

    @Test func anUnreadableSearchFolderIsReportedAndKeepsTheSavedResult() throws {
        let box = try Sandbox()
        let root = box.path + "/roots"
        try box.file("roots/web/package.json", bytes: 32)
        try box.file("roots/web/node_modules/left-pad/index.js", bytes: 4096)
        let home = box.path + "/home"
        let store = box.url.appending(path: "store")
        let complete = ProjectScanner.list(roots: [root], home: home, workers: 1)
        #expect(complete.isComplete && complete.footprints.count == 1)
        ProjectStore.save(complete, roots: [root], base: store)
        #expect(ProjectStore.loadLast(roots: [root], base: store)?.footprints.count == 1)

        let open = try sealed(root)
        defer { open() }
        let search = ProjectFinder.search(roots: [root])
        #expect(search.projects.isEmpty && search.unreadable == [root])
        let partial = ProjectScanner.list(roots: [root], home: home, workers: 1)
        #expect(partial.footprints.isEmpty && !partial.isComplete && partial.unreadable == [root])
        // Nothing found isn't "no projects": the last complete result stays.
        ProjectStore.save(partial, roots: [root], base: store)
        #expect(ProjectStore.loadLast(roots: [root], base: store)?.footprints.count == 1)
    }

    @Test func anUnreadableFolderInsideARootMarksTheListingButKeepsWhatWasFound() throws {
        let box = try Sandbox()
        let root = box.path + "/roots"
        try box.file("roots/web/package.json", bytes: 32)
        try box.file("roots/closed/app/Package.swift", bytes: 32)
        let open = try sealed(root + "/closed")
        defer { open() }
        let listing = ProjectScanner.list(roots: [root], home: box.path + "/home", workers: 1)
        #expect(listing.footprints.map(\.project.name) == ["web"])
        #expect(listing.unreadable == [root + "/closed"] && !listing.isComplete)
        // The project that was found is measured whole: its sizes aren't a lower bound.
        #expect(listing.footprints.allSatisfy { !$0.incomplete })
    }

    @Test func aRootThatIsntThereIsSimplyEmpty() throws {
        let box = try Sandbox()
        let listing = ProjectScanner.list(roots: [box.path + "/missing"], home: box.path + "/home", workers: 1)
        #expect(listing.footprints.isEmpty && listing.isComplete)
    }
}
