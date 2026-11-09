import Darwin
import Foundation
import Testing

@testable import StorageKit

@Suite struct LeftoverSearchSafetyTests {
    private let app = AppBundle(path: "/synthetic/Editor.app", name: "Editor", bundleID: "com.example.Editor", version: nil, bytes: 0, fromAppStore: false)

    @Test func partialMeasurementsAndLinkedRootsAreVisibleAndNotRemovalCandidates() throws {
        let box = try Sandbox()
        let protected = "Library/Application Support/com.example.Editor/private"
        try box.file(protected + "/notes", bytes: 100)
        try box.file("outside/com.example.Editor/cache", bytes: 100)
        try FileManager.default.createSymbolicLink(atPath: box.path + "/Library/Caches", withDestinationPath: box.path + "/outside")
        #expect(chmod(box.path + "/" + protected, 0) == 0)
        defer { _ = chmod(box.path + "/" + protected, 0o755) }
        let found = AppLeftovers.list(for: app, home: box.path, installed: [app])
        #expect(found.items.isEmpty)
        #expect(found.unreadable.contains(box.path + "/" + protected))
        #expect(found.unreadable.contains(box.path + "/Library/Caches"))
        #expect(!found.cancelled && !found.limited)
    }

    @Test func entryAndTimeBudgetsCannotMasqueradeAsACompleteSearch() throws {
        let box = try Sandbox()
        for index in 0..<20 { try box.file("Library/Caches/com.example.Other\(index)/cache", bytes: 100) }
        let limited = AppLeftovers.list(for: app, home: box.path, installed: [app], deep: true, limits: .init(entries: 2, seconds: 10))
        #expect(limited.limited && !limited.cancelled)
        let expired = AppLeftovers.list(for: app, home: box.path, installed: [app], limits: .init(seconds: 0))
        #expect(expired.limited && expired.items.isEmpty)
        let stopped = ScanProgress()
        stopped.cancel()
        let cancelled = AppLeftovers.list(for: app, home: box.path, installed: [app], progress: stopped)
        #expect(cancelled.cancelled && cancelled.items.isEmpty)
    }

    @Test func runtimeSearchRequiresDeepModeExactIdentityAndAnUnlinkedRoot() throws {
        let box = try Sandbox()
        try box.file("Runtime/Temp/com.example.Editor/draft", bytes: 100)
        try box.file("Runtime/Temp/com.example.EditorExtra/data", bytes: 100)
        let root = RuntimeLeftovers.Root(path: box.path + "/Runtime/Temp", kind: .temporary)
        #expect(AppLeftovers.find(for: app, home: box.path, installed: [app], runtimeRoots: [root]).isEmpty)
        let found = AppLeftovers.find(for: app, home: box.path, installed: [app], deep: true, runtimeRoots: [root])
        let item = try #require(found.first)
        #expect(found.count == 1 && item.evidence == .runtimeID && item.kind == .data && !item.chosenByDefault)
        #expect(AppLeftovers.isStillLeftover(item.path, of: app, home: box.path, installed: [app], runtimeRoots: [root]))
        #expect(!AppLeftovers.isStillLeftover(item.path + "Extra", of: app, home: box.path, installed: [app], runtimeRoots: [root]))
        try FileManager.default.createSymbolicLink(atPath: box.path + "/Runtime/Alias", withDestinationPath: root.path)
        let alias = RuntimeLeftovers.Root(path: box.path + "/Runtime/Alias", kind: .temporary)
        #expect(!RuntimeLeftovers.isStill(alias.path + "/com.example.Editor", of: app, installed: [app], identity: .init(), roots: [alias]))
        let copy = AppBundle(path: "/synthetic/Elsewhere/Editor.app", name: "Editor", bundleID: "COM.EXAMPLE.EDITOR", version: nil, bytes: 0, fromAppStore: false)
        #expect(!AppLeftovers.isStillLeftover(item.path, of: app, home: box.path, installed: [app, copy], runtimeRoots: [root]))
    }

    @Test func aPossibleGroupIsVisibleButNeverAuthorizedByItsName() throws {
        let box = try Sandbox()
        let group = "ABCDE12345.com.example.editor"
        try box.file("Library/Group Containers/" + group + "/database", bytes: 100)
        let report = AppLeftovers.list(for: app, home: box.path, installed: [app], deep: true)
        let item = try #require(report.items.first)
        #expect(item.name == group && !item.canRemove && !item.chosenByDefault)
        #expect(!AppLeftovers.isStillLeftover(item.path, of: app, home: box.path, installed: [app], deep: true))
        let owned = AppLeftovers.list(for: app, home: box.path, installed: [app], identity: AppIdentity(groups: [group]), deep: true)
        #expect(owned.items.count == 1 && owned.items.first?.evidence == .group)
    }
}
