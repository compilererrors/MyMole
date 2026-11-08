import Foundation
import Testing

@testable import StorageKit

/// What the user keeps by path, read together for the panes that move what
/// another pane's list protects.
@Suite struct UserProtectionsTests {
    @Test func aPathKeptInEitherPaneIsKeptWithWhatHoldsItAndWhatItHolds() throws {
        let box = try Sandbox()
        let p = UserProtections(root: box.url.appending(path: "support"))
        // No lists yet: nothing is kept.
        #expect(try !p.read()("/synthetic/Library/Caches/com.vendor.Editor"))

        try CleanKeepList(paths: ["/synthetic/Library/Caches/com.vendor.Editor"]).save(to: p.keepList)
        var rules = ProjectRules()
        rules.keepPaths = ["/synthetic/Workspace/app/node_modules/local-only"]
        rules.keepNames = ["notes"]
        try ProjectStore.saveRules(rules, base: p.projectBase)
        let keeps = try p.read()
        #expect(keeps("/synthetic/Library/Caches/com.vendor.Editor"))
        #expect(keeps("/synthetic/Library/Caches/com.vendor.Editor/blob") && keeps("/synthetic/Library/Caches"))
        #expect(keeps("/synthetic/Workspace/app/node_modules") && keeps("/synthetic/Workspace/app"))
        #expect(!keeps("/synthetic/Library/Caches/com.vendor.Player"))
        // A rule by name is Projects' own.
        #expect(!keeps("/synthetic/Downloads/notes"))
    }

    @Test func systemCleansListIsReadApart() throws {
        let box = try Sandbox()
        let p = UserProtections(root: box.url.appending(path: "support"))
        #expect(try !p.readSystem()("/Library/Caches/com.vendor.Editor"))
        try CleanKeepList(paths: ["/Library/Caches/com.vendor.Editor"]).save(to: p.systemKeepList)
        #expect(try p.readSystem()("/Library/Caches/com.vendor.Editor"))
        #expect(try !p.read()("/Library/Caches/com.vendor.Editor"))
    }

    @Test func aListThatCantBeReadThrows() throws {
        let box = try Sandbox()
        let p = UserProtections(root: box.url.appending(path: "support"))
        try FileManager.default.createDirectory(at: p.keepList.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: p.keepList)
        #expect(throws: (any Error).self) { _ = try p.read() }
        // Deep Clean's list reads again, the project rules don't.
        try CleanKeepList().save(to: p.keepList)
        try FileManager.default.createDirectory(at: p.projectBase, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: p.projectBase.appending(path: "rules.json"))
        #expect(throws: (any Error).self) { _ = try p.read() }
        try FileManager.default.createDirectory(at: p.systemKeepList.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: p.systemKeepList)
        #expect(throws: (any Error).self) { _ = try p.readSystem() }
    }
}
